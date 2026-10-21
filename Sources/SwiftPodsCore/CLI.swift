import Darwin
import Foundation
import ProcessSupport

public enum CLI {
    public static let version = "0.1.1"
    public static func run(
        arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment,
        executable: URL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
    ) -> Int32 {
        let redactor = Redactor(environment: environment)
        let machine = arguments.contains("--json")
        let requested = arguments.filter { $0 != "--json" }
        var refreshQuery: String?
        var state: ProjectState?
        var lastHostResult: HostResult?
        do {
            guard sp_cancellation_begin() == 0 else {
                throw Diagnostic("SP-PROCESS-SIGNALS", stage: "cli", "Cannot configure command cancellation")
            }
            defer { sp_cancellation_end() }
            let global = try CommandOptions.parseGlobalOptions(in: arguments)
            var engineArguments = global.arguments
            var command = engineArguments.first ?? "help"
            if ["help", "--help", "-h"].contains(command) {
                print(help)
                return 0
            }
            let context = try CLIContext(
                options: global, environment: environment, executable: executable, redactor: redactor, machine: machine)
            if let status = try context.runCommand() { return status }
            let directory = context.directory
            let environmentName = context.environmentName
            if (command == "graph" || command == "why") && engineArguments.contains("--refresh") {
                if command == "why" {
                    guard engineArguments.count >= 2, !CommandOptions.hasOptionPrefix(engineArguments[1]) else {
                        throw Diagnostic("SP-CLI-ARGUMENT", stage: "cli", "why requires a pod name")
                    }
                    refreshQuery = engineArguments[1]
                } else {
                    refreshQuery = ""
                }
                engineArguments =
                    ["install"] + engineArguments.dropFirst(command == "why" ? 2 : 1).filter { $0 != "--refresh" }
                command = "install"
            }
            var hostEnvironment = environment
            hostEnvironment.removeValue(forKey: "SWIFTPODS_OFFLINE")
            hostEnvironment.removeValue(forKey: "SWIFTPODS_HARDENED_MANIFEST")
            hostEnvironment["SWIFTPODS_PROJECT_ROOT"] = directory.resolvingSymlinksInPath().path
            if engineArguments.contains("--offline") {
                guard ["install", "update"].contains(command), !engineArguments.contains("--repo-update") else {
                    throw Diagnostic(
                        "SP-OFFLINE-OPTION", stage: "cli", "Offline mode supports install/update without --repo-update")
                }
                engineArguments.removeAll { $0 == "--offline" }
                hostEnvironment["SWIFTPODS_OFFLINE"] = "1"
            }
            if engineArguments.contains("--hardened") {
                guard ["install", "update"].contains(command) else {
                    throw Diagnostic("SP-HARDENED-OPTION", stage: "cli", "Hardened mode supports install/update")
                }
                guard environmentName == nil else {
                    throw Diagnostic(
                        "SP-HARDENED-ENVIRONMENT", stage: "policy",
                        "Hardened mode uses the managed baseline only; imported Gemfiles/plugins cannot execute")
                }
                let manifest = directory.appendingPathComponent("Podfile.json")
                _ = try ExecutionPolicy.hardenedManifest(manifest)
                engineArguments.removeAll { $0 == "--hardened" }
                hostEnvironment["SWIFTPODS_HARDENED_MANIFEST"] = manifest.path
            }
            let managed = try context.managedBundle()
            let selected = try environmentName.map {
                try EnvironmentProfile.load(name: $0, project: directory, bundle: managed, environment: environment)
            }
            try managed.verify()
            let useIntegrity = engineArguments.contains("--integrity")
            engineArguments.removeAll { $0 == "--integrity" }
            let integrity = ArtifactIntegrity(project: directory)
            let integrityExists = FileManager.default.fileExists(atPath: integrity.path.path)
            if useIntegrity {
                guard ["install", "update"].contains(command) else {
                    throw Diagnostic("SP-CLI-ARGUMENT", stage: "cli", "--integrity supports install/update")
                }
                if integrityExists { _ = try integrity.verify(allowMissing: true) }
            }
            let mutation = ["init", "install", "update", "deintegrate"].contains(command)
            if mutation {
                guard getuid() != 0 else {
                    throw Diagnostic("SP-CLI-ROOT", stage: "prepare", "Run project mutations as a regular user")
                }
                let project = ProjectState(directory: directory)
                try project.acquire()
                // Verify before recording a running state or touching Ruby.
                try managed.verify()
                try project.begin(
                    command: requested.map(redactor.scrub), profile: managed.manifest["id"] as? String ?? "unknown",
                    operation: command)
                state = project
            }
            let result = NativeEngine(bundle: managed).run(
                arguments: engineArguments, environment: hostEnvironment, machine: machine,
                overrides: selected?.overrides ?? [:],
                project: directory)
            lastHostResult = result
            if useIntegrity && result.status == 0 && integrityExists { _ = try integrity.verify() }
            let projectStatus = try state?.finish(
                result: result, command: requested.map(redactor.scrub),
                profile: managed.manifest["id"] as? String ?? "unknown")
            if useIntegrity && result.status == 0 && !integrityExists {
                _ = try integrity.record(report: ProjectState(directory: directory).graph())
            }
            if let refreshQuery, result.status == 0 {
                let effective = managed.environment(from: environment).merging(selected?.overrides ?? [:]) { _, new in
                    new
                }
                var report = try ProjectState(directory: directory).graph(environment: effective)
                if !refreshQuery.isEmpty { report = try DependencyGraph.why(refreshQuery, report: report) }
                report["refresh"] = ["operation": "install", "executed_project_code": true]
                try output(report, redactor: redactor)
                return 0
            }
            if machine {
                try output(
                    [
                        "schema_version": 1, "producer": "SwiftPods", "command": requested.map(redactor.scrub),
                        "environment": environmentName ?? "baseline",
                        "offline": hostEnvironment["SWIFTPODS_OFFLINE"] == "1",
                        "hardened": hostEnvironment["SWIFTPODS_HARDENED_MANIFEST"] != nil,
                        "exit_status": result.status, "events": result.events,
                        "project_state": projectStatus ?? "untracked",
                    ], redactor: redactor)
            }
            return sp_cancellation_number() == 0 ? result.status : 128 + Int32(sp_cancellation_number())
        } catch {
            if let state {
                _ = try? state.finish(
                    result: HostResult(status: 125, events: lastHostResult?.events ?? []),
                    command: requested.map(redactor.scrub), profile: "interrupted")
            }
            let diagnostic = error as? Diagnostic ?? Diagnostic("SP-INTERNAL", stage: "cli", String(describing: error))
            if machine {
                let data = try? JSONEncoder().encode(diagnostic)
                let object = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? ["code": diagnostic.code]
                try? output(["schema_version": 1, "exit_status": 1, "diagnostic": object], redactor: redactor)
            } else {
                FileHandle.standardError.write(Data(redactor.scrub("\(diagnostic.code): \(diagnostic.message)\n").utf8))
            }
            return 1
        }
    }

    static func output(_ object: [String: Any], redactor: Redactor) throws {
        let text = String(decoding: try jsonData(redactor.scrubObject(object)), as: UTF8.self)
        print(text)
    }

    private static let help = """
        SwiftPods \(version) — Dependency manager for Apple platforms

        swiftpods install [--deployment] [--repo-update] [--offline] [--integrity] [--json]
        swiftpods update [POD ...] [--no-repo-update]
        swiftpods init
        swiftpods outdated [--ignore-prerelease] [--no-repo-update]
        swiftpods deintegrate
        swiftpods repo list | add NAME URL [BRANCH] | add-cdn NAME URL | update [NAME] | remove NAME
        swiftpods repo push NAME [SPEC] [--quick] [--allow-warnings]
        swiftpods spec cat | which NAME [--version VERSION] [--sources URL,...]
        swiftpods spec lint [SPEC ...] [--platforms osx,ios] [--quick] [--allow-warnings]
        swiftpods lib lint [SPEC ...] [--platforms osx,ios] [--quick] [--allow-warnings]
        swiftpods ipc spec | podfile PATH
        swiftpods migrate --check [--json]
        swiftpods doctor --static [--platform ios] [--variant simulator] [--arch arm64] [--app PATH] [--json]
        swiftpods graph [--refresh] [--json]
        swiftpods why POD [--refresh] [--json]
        swiftpods env import --gemfile PATH [--name NAME] [--local]
        swiftpods env list
        swiftpods env shim --directory PATH
        swiftpods integrity record | verify
        swiftpods cache verify
        swiftpods cache list [POD] | clean POD | clean --all
        swiftpods runtime verify
        swiftpods recover [--json]
        swiftpods version [--json]

        Dependency resolution and Xcode integration run in the native Swift engine.
        Installation, update, lint and repository publication may execute arbitrary
        trusted Ruby Podfiles, podspecs, plugins, hooks and external scripts.
        Static inspection and graph viewing do not execute project Ruby.
        graph/why --refresh explicitly run install, including project code.
        --json emits schema_version 1; command output is sent to stderr.
        SWIFTPODS_BUNDLE explicitly selects the SwiftPods distribution.
        SWIFTPODS_RUBY selects an absolute external CRuby executable (>= 2.6).
        --environment NAME explicitly selects an imported frozen gem profile.
        install/update --hardened require Podfile.json and JSON podspecs; Ruby,
        plugins, prepare commands and script phases are rejected before execution.
        --offline prevents network requests by managed loaders; hooks are trusted code.
        """
}
