import Foundation
import Darwin
import ProcessSupport

public enum CLI {
    public static let version = "0.1.0-dev"
    public static func run(arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment,
                           executable: URL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])) -> Int32 {
        let redactor = Redactor(environment: environment)
        var args = arguments
        let machine = args.contains("--json")
        args.removeAll { $0 == "--json" }
        let requested = args
        var command = args.first ?? "help"
        var refreshQuery: String?
        var state: ProjectState?
        var lastHostResult: HostResult?
        do {
            guard sp_cancellation_begin() == 0 else { throw Diagnostic("SP-PROCESS-SIGNALS", stage: "cli", "Cannot configure command cancellation") }
            defer { sp_cancellation_end() }
            if ["help", "--help", "-h"].contains(command) {
                print(help)
                return 0
            }
            let bundle = try? RuntimeBundle.locate(environment: environment, executable: executable)
            let directory = try projectDirectory(arguments: args)
            let environmentName = try CommandOptions.take("--environment", from: &args)
            if command == "env" {
                var options = Array(args.dropFirst(2))
                _ = try CommandOptions.take("--project-directory", from: &options)
                let action = args.dropFirst().first ?? "list"
                if action == "shim" {
                    guard let path = try CommandOptions.take("--directory", from: &options), options.isEmpty else {
                        throw Diagnostic("SP-CLI-ARGUMENT", stage: "cli", "Use env shim --directory PATH")
                    }
                    let parent = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
                    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
                    let target = parent.appendingPathComponent("pod")
                    try FileManager.default.createSymbolicLink(at: target, withDestinationURL: executable.resolvingSymlinksInPath())
                    try output(["schema_version": 1, "status": "created", "path": target.path,
                                "target": executable.resolvingSymlinksInPath().path, "path_modified": false], redactor: redactor)
                } else if action == "list" {
                    guard options.isEmpty else { throw Diagnostic("SP-CLI-ARGUMENT", stage: "cli", "Unknown env list option") }
                    let parent = directory.appendingPathComponent(".swiftpods/environments")
                    let paths = (try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
                    let profiles = paths.compactMap { path -> [String: Any]? in
                        guard let profile = try? readObject(path.appendingPathComponent("profile.json")) else { return nil }
                        return ["name": profile["name"] ?? path.lastPathComponent, "gems": profile["gems"] ?? [], "plugins": profile["plugins"] ?? []]
                    }
                    try output(["schema_version": 1, "profiles": profiles.sorted { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }], redactor: redactor)
                } else if action == "import" {
                    let local = options.contains("--local")
                    options.removeAll { $0 == "--local" }
                    let managed = try bundle ?? RuntimeBundle.locate(environment: environment, executable: executable)
                    guard let path = try CommandOptions.take("--gemfile", from: &options) else {
                        throw Diagnostic("SP-CLI-ARGUMENT", stage: "cli", "Use env import --gemfile Gemfile [--name NAME]")
                    }
                    let gemfile = URL(fileURLWithPath: path, relativeTo: directory).standardizedFileURL.resolvingSymlinksInPath()
                    let name = try CommandOptions.take("--name", from: &options) ?? "import-" + String(digest(try Data(contentsOf: gemfile)).prefix(12))
                    guard options.isEmpty else { throw Diagnostic("SP-CLI-ARGUMENT", stage: "cli", "Unknown environment import option") }
                    try output(EnvironmentProfile.importProfile(name: name, gemfile: gemfile, project: directory, bundle: managed, environment: environment, local: local), redactor: redactor)
                } else { throw Diagnostic("SP-CLI-ARGUMENT", stage: "cli", "Use env import, env list or env shim") }
                return 0
            }
            if command == "__archivecheck" {
                guard args.count == 2 else { throw Diagnostic("SP-CLI-ARGUMENT", stage: "cli", "Archive path required") }
                try ExecutionPolicy.validateArchive(args[1])
                try output(["schema_version": 1, "status": "passed"], redactor: redactor)
                return 0
            }
            if command == "runtime" && args == ["runtime", "verify"] {
                let managed = try bundle ?? RuntimeBundle.locate(environment: environment, executable: executable)
                try managed.verify()
                let ruby = try ExternalRuby.locate(manifest: managed.manifest, environment: environment, bundleRoot: managed.root)
                try output(["schema_version": 1, "status": "passed", "profile": managed.manifest["id"] ?? "unknown",
                            "ruby": ruby.metadata, "runtime_mode": "external", "executed_project_code": false], redactor: redactor)
                return 0
            }
            if command == "__cache" {
                guard args.count == 3, let payload = try JSONSerialization.jsonObject(with: FileHandle.standardInput.readDataToEndOfFile()) as? [String: Any],
                      let rawOrigin = payload["origin"] as? [String: Any], let origin = redactor.scrubObject(rawOrigin) as? [String: Any] else {
                    throw Diagnostic("SP-CACHE-ARGUMENT", stage: "cache", "Invalid content-store request")
                }
                let store = try ContentStore(cacheRoot: URL(fileURLWithPath: args[2]))
                if args[1] == "get" { try output(store.get(origin: origin), redactor: redactor) }
                else if args[1] == "put", let path = payload["path"] as? String { try output(store.put(file: URL(fileURLWithPath: path), origin: origin), redactor: redactor) }
                else { throw Diagnostic("SP-CACHE-ARGUMENT", stage: "cache", "Unknown content-store operation") }
                return 0
            }
            if command == "cache" && args.dropFirst().first == "verify" {
                let managed = try bundle ?? RuntimeBundle.locate(environment: environment, executable: executable)
                let root = managed.environment(from: environment)["SWIFTPODS_CACHE_ROOT"]!
                try output(NativeCacheIntegrity.verify(URL(fileURLWithPath: root)), redactor: redactor)
                return 0
            }
            if (command == "repo" && args.dropFirst().first != "push") || command == "cache" {
                let managed = try bundle ?? RuntimeBundle.locate(environment: environment, executable: executable)
                let root = URL(fileURLWithPath: managed.environment(from: environment)["SWIFTPODS_CACHE_ROOT"]!)
                let value = try NativeMaintenance.run(args, cache: root)
                try output(value.merging(["schema_version": 1, "status": "passed"]) { old, _ in old }, redactor: redactor)
                return 0
            }
            if command == "__treecheck" {
                guard args.count == 2 else { throw Diagnostic("SP-CLI-ARGUMENT", stage: "cli", "Tree path required") }
                let value = try FileFingerprint.tree(URL(fileURLWithPath: args[1]), requireContainedLinks: true)
                guard value != "absent" else { throw Diagnostic("SP-ARCHIVE-MISSING", stage: "extract", "Extraction root does not exist") }
                try output(["schema_version": 1, "status": "passed", "sha256": value], redactor: redactor)
                return 0
            }
            if ["version", "--version"].contains(command) {
                if machine {
                    var report = bundle?.manifest ?? ["runtime_status": "missing"]
                    report.removeValue(forKey: "files")
                    report["producer"] = "SwiftPods"; report["swiftpods_version"] = version
                    if let environmentName, let bundle {
                        var profile = try EnvironmentProfile.load(name: environmentName, project: directory, bundle: bundle, environment: environment).metadata
                        profile.removeValue(forKey: "files")
                        report["environment_profile"] = profile
                    }
                    try output(report, redactor: redactor)
                } else {
                    print("SwiftPods \(version) (\(bundle?.manifest["id"] as? String ?? "runtime missing"))")
                }
                return 0
            }
            if command == "migrate" || command == "doctor" {
                var options = Array(args.dropFirst())
                _ = try CommandOptions.take("--project-directory", from: &options)
                let platform = try CommandOptions.take("--platform", from: &options)
                let variant = try CommandOptions.take("--variant", from: &options)
                let architecture = try CommandOptions.take("--arch", from: &options)
                let application = try CommandOptions.take("--app", from: &options)
                let deploymentTarget = try CommandOptions.take("--deployment-target", from: &options)
                guard command != "migrate" || options.contains("--check") else { throw Diagnostic("SP-CLI-ARGUMENT", stage: "cli", "Use migrate --check") }
                guard options.allSatisfy({ ["--check", "--static"].contains($0) }),
                      platform == nil || ["osx", "ios", "tvos", "watchos", "visionos"].contains(platform!),
                      variant == nil || ["device", "simulator", "maccatalyst"].contains(variant!),
                      architecture == nil || ["arm64", "arm64e", "arm64_32", "armv7k", "armv7", "armv7s", "x86_64", "x86_64h", "i386", "arm"].contains(architecture!) else {
                    throw Diagnostic("SP-CLI-ARGUMENT", stage: "cli", "Unknown doctor option or platform/variant/architecture")
                }
                var report = Doctor(directory: directory, platform: platform, variant: variant, architecture: architecture,
                                    application: application.map { URL(fileURLWithPath: $0, relativeTo: directory).standardizedFileURL }, deploymentTarget: deploymentTarget).report(bundle: bundle)
                if let environmentName {
                    let managed = try bundle ?? RuntimeBundle.locate(environment: environment, executable: executable)
                    let profile = try EnvironmentProfile.load(name: environmentName, project: directory, bundle: managed, environment: environment)
                    var metadata = profile.metadata
                    metadata.removeValue(forKey: "files")
                    report["environment_profile"] = metadata
                }
                if machine { try output(report, redactor: redactor) }
                else {
                    print("Static inspection: full compatibility is unverified")
                    for check in report["checks"] as? [[String: Any]] ?? [] {
                        print(redactor.scrub("[\(check["status"] ?? "unknown")] \(check["name"] ?? "check"): \(check["message"] ?? "")"))
                    }
                }
                return report["status"] as? String == "failed" ? 1 : 0
            }
            if (command == "graph" || command == "why") && !args.contains("--refresh") {
                var options = Array(args.dropFirst(command == "why" ? 2 : 1))
                _ = try CommandOptions.take("--project-directory", from: &options)
                guard options.isEmpty else {
                    throw Diagnostic("SP-CLI-ARGUMENT", stage: "cli", "Unknown graph/why option")
                }
                var effective = bundle?.environment(from: environment) ?? environment
                if let environmentName {
                    let managed = try bundle ?? RuntimeBundle.locate(environment: environment, executable: executable)
                    effective.merge(try EnvironmentProfile.load(name: environmentName, project: directory, bundle: managed, environment: environment).overrides) { _, new in new }
                }
                var report = try ProjectState(directory: directory).graph(environment: effective)
                if command == "why" {
                    guard args.count >= 2, !args[1].hasPrefix("-") else { throw Diagnostic("SP-CLI-ARGUMENT", stage: "cli", "why requires a pod name") }
                    report = try DependencyGraph.why(args[1], report: report)
                }
                try output(report, redactor: redactor)
                return 0
            }
            if (command == "graph" || command == "why") && args.contains("--refresh") {
                if command == "why" {
                    guard args.count >= 2, !args[1].hasPrefix("-") else { throw Diagnostic("SP-CLI-ARGUMENT", stage: "cli", "why requires a pod name") }
                    refreshQuery = args[1]
                } else { refreshQuery = "" }
                args = ["install"] + args.dropFirst(command == "why" ? 2 : 1).filter { $0 != "--refresh" }
                command = "install"
            }
            if command == "recover" {
                try output(ProjectState(directory: directory).recover(), redactor: redactor)
                return 0
            }
            if command == "integrity" {
                let action = args.dropFirst().first ?? "verify"
                var options = Array(args.dropFirst(2))
                _ = try CommandOptions.take("--project-directory", from: &options)
                guard options.isEmpty else { throw Diagnostic("SP-CLI-ARGUMENT", stage: "cli", "Unknown integrity option") }
                let integrity = ArtifactIntegrity(project: directory)
                if action == "verify" { try output(integrity.verify(), redactor: redactor) }
                else if action == "record" {
                    let lock = ProjectState(directory: directory); try lock.acquire()
                    try output(integrity.record(report: lock.graph()), redactor: redactor)
                } else { throw Diagnostic("SP-CLI-ARGUMENT", stage: "cli", "Use integrity record or integrity verify") }
                return 0
            }
            var hostEnvironment = environment
            hostEnvironment.removeValue(forKey: "SWIFTPODS_OFFLINE")
            hostEnvironment.removeValue(forKey: "SWIFTPODS_HARDENED_MANIFEST")
            hostEnvironment["SWIFTPODS_PROJECT_ROOT"] = directory.resolvingSymlinksInPath().path
            if args.contains("--offline") {
                guard ["install", "update"].contains(command), !args.contains("--repo-update") else {
                    throw Diagnostic("SP-OFFLINE-OPTION", stage: "cli", "Offline mode supports install/update without --repo-update")
                }
                args.removeAll { $0 == "--offline" }
                hostEnvironment["SWIFTPODS_OFFLINE"] = "1"

            }
            if args.contains("--hardened") {
                guard ["install", "update"].contains(command) else { throw Diagnostic("SP-HARDENED-OPTION", stage: "cli", "Hardened mode supports install/update") }
                guard environmentName == nil else { throw Diagnostic("SP-HARDENED-ENVIRONMENT", stage: "policy", "Hardened mode uses the managed baseline only; imported Gemfiles/plugins cannot execute") }
                let manifest = directory.appendingPathComponent("Podfile.json")
                _ = try ExecutionPolicy.hardenedManifest(manifest)
                args.removeAll { $0 == "--hardened" }
                hostEnvironment["SWIFTPODS_HARDENED_MANIFEST"] = manifest.path
            }
            let managed = try bundle ?? RuntimeBundle.locate(environment: environment, executable: executable)
            let selected = try environmentName.map { try EnvironmentProfile.load(name: $0, project: directory, bundle: managed, environment: environment) }
            try managed.verify()
            let useIntegrity = args.contains("--integrity")
            args.removeAll { $0 == "--integrity" }
            let integrity = ArtifactIntegrity(project: directory)
            let integrityExists = FileManager.default.fileExists(atPath: integrity.path.path)
            if useIntegrity {
                guard ["install", "update"].contains(command) else { throw Diagnostic("SP-CLI-ARGUMENT", stage: "cli", "--integrity supports install/update") }
                if integrityExists { _ = try integrity.verify(allowMissing: true) }
            }
            let mutation = ["init", "install", "update", "deintegrate"].contains(command)
            if mutation {
                guard getuid() != 0 else { throw Diagnostic("SP-CLI-ROOT", stage: "prepare", "Run project mutations as a regular user") }
                let project = ProjectState(directory: directory)
                try project.acquire()
                // Verify before recording a running state or touching Ruby.
                try managed.verify()
                try project.begin(command: requested.map(redactor.scrub), profile: managed.manifest["id"] as? String ?? "unknown")
                state = project
            }
            let result = NativeEngine(bundle: managed).run(arguments: args, environment: hostEnvironment, machine: machine, overrides: selected?.overrides ?? [:])
            lastHostResult = result
            if useIntegrity && result.status == 0 && integrityExists { _ = try integrity.verify() }
            let projectStatus = try state?.finish(result: result, command: requested.map(redactor.scrub), profile: managed.manifest["id"] as? String ?? "unknown")
            if useIntegrity && result.status == 0 && !integrityExists { _ = try integrity.record(report: ProjectState(directory: directory).graph()) }
            if let refreshQuery, result.status == 0 {
                let effective = managed.environment(from: environment).merging(selected?.overrides ?? [:]) { _, new in new }
                var report = try ProjectState(directory: directory).graph(environment: effective)
                if !refreshQuery.isEmpty { report = try DependencyGraph.why(refreshQuery, report: report) }
                report["refresh"] = ["operation": "install", "executed_project_code": true]
                try output(report, redactor: redactor)
                return 0
            }
            if machine {
                try output(["schema_version": 1, "producer": "SwiftPods", "command": requested.map(redactor.scrub),
                            "environment": environmentName ?? "baseline", "offline": hostEnvironment["SWIFTPODS_OFFLINE"] == "1",
                            "hardened": hostEnvironment["SWIFTPODS_HARDENED_MANIFEST"] != nil,
                            "exit_status": result.status, "events": result.events,
                            "project_state": projectStatus ?? "untracked"], redactor: redactor)
            }
            return sp_cancellation_number() == 0 ? result.status : 128 + Int32(sp_cancellation_number())
        } catch {
            if let state {
                _ = try? state.finish(result: HostResult(status: 125, events: lastHostResult?.events ?? []), command: requested.map(redactor.scrub), profile: "interrupted")
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

    private static func projectDirectory(arguments: [String]) throws -> URL {
        var path = FileManager.default.currentDirectoryPath
        var explicit = false
        for (index, argument) in arguments.enumerated() {
            if argument.hasPrefix("--project-directory=") { path = String(argument.dropFirst("--project-directory=".count)); explicit = true }
            if argument == "--project-directory" {
                guard index + 1 < arguments.count else { throw Diagnostic("SP-CLI-ARGUMENT", stage: "cli", "Missing project directory") }
                path = arguments[index + 1]
                explicit = true
            }
        }
        let result = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: result.path, isDirectory: &directory), directory.boolValue else {
            throw Diagnostic("SP-CLI-DIRECTORY", stage: "cli", "Project directory does not exist", file: result.path)
        }
        if !explicit && arguments.first != "init" {
            var candidate = result
            let names = ["CocoaPods.podfile.yaml", "CocoaPods.podfile", "Podfile"] + (arguments.contains("--hardened") ? ["Podfile.json"] : [])
            while candidate.path != "/" {
                if names.contains(where: { FileManager.default.fileExists(atPath: candidate.appendingPathComponent($0).path) }) { return candidate }
                candidate.deleteLastPathComponent()
            }
        }
        return result
    }

    private static func output(_ object: [String: Any], redactor: Redactor) throws {
        let text = String(decoding: try jsonData(redactor.scrubObject(object)), as: UTF8.self)
        print(text)
    }

    private static let help = """
    SwiftPods \(version) — Dependency manager for Apple platforms

    swiftpods install [--deployment] [--repo-update] [--offline] [--integrity] [--json]
    swiftpods update [POD ...]
    swiftpods init | outdated
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
    swiftpods shim --directory PATH
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
    SWIFTPODS_RUBY selects an absolute external CRuby 3.4 executable (>= 3.4.11).
    --environment NAME explicitly selects an imported frozen gem profile.
    install/update --hardened require Podfile.json and JSON podspecs; Ruby,
    plugins, prepare commands and script phases are rejected before execution.
    --offline prevents network requests by managed loaders; hooks are trusted code.
    """
}
