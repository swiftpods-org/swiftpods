import Foundation
import ProcessSupport

/// Owns output and diagnostics for one CLI execution.
final class NativeCommandSession {
    let bundle: RuntimeBundle
    let environment: [String: String]
    let sdkContext: NativeSDKContext
    let machine: Bool
    let overrides: [String: String]
    let silent: Bool
    let verbose: Bool
    var events: [[String: Any]]

    init(
        bundle: RuntimeBundle, arguments: [String], environment: [String: String], machine: Bool,
        overrides: [String: String]
    ) {
        self.bundle = bundle
        self.environment = environment
        sdkContext = NativeSDKContext(environment: environment.merging(overrides) { _, new in new })
        self.machine = machine
        self.overrides = overrides
        silent = arguments.contains("--silent")
        verbose = arguments.contains("--verbose")
        events = [
            ["kind": "started", "producer": "SwiftPods", "engine": "swift", "command": arguments.first ?? "install"]
        ]
    }

    func recordWrite(_ url: URL) { events.append(["kind": "managed_write", "path": url.path]) }

    func run(arguments: [String], project: URL? = nil) -> HostResult {
        do {
            let request = try NativeCommandRequest(arguments, project: project)
            let action = request.action
            let args = request.arguments
            let project = request.project
            func writeEvent(_ url: URL) { recordWrite(url) }
            if ["lib", "spec"].contains(action), args.first == "lint" {
                let value = try NativeValidation(bundle: bundle, environment: environment, overrides: overrides).run(
                    action: action, arguments: Array(args.dropFirst()), project: project)
                events.append(["kind": "validation", "data": value])
                if value["status"] as? String != "passed" {
                    let errors = value["errors"] as? [[String: Any]] ?? []
                    throw Diagnostic(
                        errors.first?["code"] as? String ?? "SP-LINT-FAILED", stage: "lint",
                        errors.compactMap { $0["message"] as? String }.joined(separator: "\n"),
                        file: errors.first?["file"] as? String)
                }
                if !machine && !silent { print("Validation passed.") }
            } else if action == "repo", args.first == "push" {
                let value = try NativePublication.push(
                    arguments: Array(args.dropFirst()), project: project, bundle: bundle, environment: environment,
                    overrides: overrides)
                events.append(["kind": "publication", "data": value])
                if !machine && !silent { print("Published \(value["name"] ?? "") \(value["version"] ?? "").") }
            } else if ["ipc", "spec"].contains(action) {
                let value = try NativeInspection.run(
                    action: action, arguments: args, project: project, bundle: bundle, environment: environment,
                    overrides: overrides)
                events.append(["kind": "inspection", "data": value])
                if !machine {
                    if let paths = value as? [String] {
                        for path in paths { print(path) }
                    } else {
                        print(String(decoding: try jsonData(value), as: UTF8.self))
                    }
                }
            } else if action == "deintegrate" {
                guard args.isEmpty else {
                    throw Diagnostic("SP-CLI-ARGUMENT", stage: "cli", "Unknown deintegrate option")
                }
                for path in try NativeDeintegrator.run(project) { writeEvent(path) }
                events.append(["kind": "deintegrated"])
            } else if action == "init" {
                guard args.isEmpty else { throw Diagnostic("SP-CLI-ARGUMENT", stage: "cli", "Unknown init option") }
                let podfile = project.appendingPathComponent("Podfile")
                guard NativePodfilePath.find(in: project) == nil else {
                    throw Diagnostic("SP-INIT-EXISTS", stage: "init", "Podfile already exists")
                }
                let projects = try FileManager.default.contentsOfDirectory(at: project, includingPropertiesForKeys: nil)
                    .filter { $0.pathExtension == "xcodeproj" }
                guard projects.count == 1 else {
                    throw Diagnostic("SP-XCODE-AMBIGUOUS", stage: "init", "Exactly one Xcode project is required")
                }
                let pbx = try NativePBX(projects[0].appendingPathComponent("project.pbxproj"), existing: true)
                let targets = pbx.objects.values.filter { $0["isa"] as? String == "PBXNativeTarget" }.compactMap {
                    $0["name"] as? String
                }.sorted()
                let analyzed = try NativeManifest.analyze(
                    ["targets": targets.map { ["name": $0, "project": projects[0].lastPathComponent] }],
                    project: project, integrate: true, sdkContext: sdkContext)
                let content =
                    "project " + NativeRubyString.quote(projects[0].lastPathComponent) + "\n\n"
                    + (analyzed["targets"] as? [[String: Any]] ?? []).map { target in
                        let platform = target["platform"] as! [String: String]
                        return "target " + NativeRubyString.quote(target["name"] as! String) + " do\n  platform :"
                            + platform[
                                "name"]! + ", " + NativeRubyString.quote(platform["deployment_target"]!) + "\nend\n"
                    }.joined(separator: "\n")
                try Data(content.utf8).writeIfChanged(to: podfile, options: .atomic)
                writeEvent(podfile)
            } else if ["install", "update", "outdated"].contains(action) {
                if let result = try install(request) { return result }
            } else {
                throw Diagnostic(
                    "SP-COMMAND-UNSUPPORTED", stage: "cli",
                    "Command \(action) is not implemented by the native Swift engine yet")
            }
            events.append(["kind": "completed", "status": 0])
            if !machine && !silent {
                let redactor = Redactor(environment: environment)
                for event in events where verbose || event["kind"] as? String == "warning" {
                    if let data = try? jsonData(event) { print(redactor.scrub(String(decoding: data, as: UTF8.self))) }
                }
            }
            return HostResult(status: 0, events: events)
        } catch {
            let signal = sp_cancellation_number()
            let diagnostic =
                signal == 0
                ? (error as? Diagnostic ?? Diagnostic("SP-NATIVE-ERROR", stage: "install", String(describing: error)))
                : Diagnostic("SP-CANCELLED", stage: "execute", "Command cancelled by signal \(signal)")
            let status: Int32 = signal == 0 ? 1 : 128 + Int32(signal)
            var event: [String: Any] = [
                "kind": "diagnostic", "code": diagnostic.code, "stage": diagnostic.stage, "message": diagnostic.message,
                "file": diagnostic.file ?? "",
            ]
            if let line = diagnostic.line { event["line"] = line }
            event["backtrace"] = diagnostic.backtrace
            event["dependency_chain"] = diagnostic.dependencyChain
            if let state = diagnostic.state { event["project_state"] = state }
            if ["SP-LOCK-CONFLICT", "SP-XCODE-CONFLICT", "SP-WORKSPACE-CONFLICT"].contains(diagnostic.code),
                let file = diagnostic.file
            {
                events.append(["kind": "external_conflict", "path": file])
            }
            events.append(event)
            events.append(["kind": "completed", "status": status])
            FileHandle.standardError.write(
                Data(Redactor(environment: environment).scrub("[\(diagnostic.code)] \(diagnostic.message)\n").utf8))
            for frame in diagnostic.backtrace {
                FileHandle.standardError.write(Data(Redactor(environment: environment).scrub("  " + frame + "\n").utf8))
            }
            return HostResult(status: status, events: events)
        }
    }
}
