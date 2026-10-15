import Foundation

enum NativeInspection {
    static func run(action: String, arguments: [String], project: URL, bundle: RuntimeBundle, environment: [String: String], overrides: [String: String]) throws -> Any {
        var args = arguments
        guard !args.isEmpty else { throw Diagnostic("SP-CLI-ARGUMENT", stage: "inspect", "Use ipc spec/podfile PATH or spec cat/which NAME") }
        let operation = args.removeFirst()
        if action == "ipc" {
            guard ["spec", "podfile"].contains(operation), args.count == 1 else { throw Diagnostic("SP-CLI-ARGUMENT", stage: "inspect", "Use ipc spec/podfile PATH") }
            let path = URL(fileURLWithPath: args[0], relativeTo: project).standardizedFileURL
            if path.pathExtension == "json" { return try readObject(path) }
            let dsl = try NativeDSL(bundle: bundle, environment: environment, directory: project, overrides: overrides)
            let access = NativeProjectAccess(root: project)
            dsl.callback = { try access.callback($0, writable: false) }
            return try dsl.object(operation == "spec" ? "spec" : "podfile", ["path": path.path])
        }
        guard ["cat", "which"].contains(operation), !args.isEmpty else { throw Diagnostic("SP-CLI-ARGUMENT", stage: "inspect", "Use spec cat/which NAME [--version VERSION]") }
        let name = args.removeFirst()
        let version = try CommandOptions.take("--version", from: &args)
        let sources = try CommandOptions.take("--sources", from: &args)
        let all = args.contains("--show-all"); args.removeAll { $0 == "--show-all" }
        guard args.isEmpty else { throw Diagnostic("SP-CLI-ARGUMENT", stage: "inspect", "Unknown spec inspection option") }
        let cache = URL(fileURLWithPath: bundle.environment(from: environment)["SWIFTPODS_CACHE_ROOT"]!)
        let repositories = try NativeRepositories(cache: cache).records().compactMap { $0["url"] as? String }
        let declared = sources.map { $0.split(separator: ",").map(String.init) } ?? (repositories + ["https://cdn.cocoapods.org/"])
        let dsl = try NativeDSL(bundle: bundle, environment: environment, directory: project, overrides: overrides)
        let catalog = try NativeSources(project: project, cache: cache, sources: declared, dsl: dsl, offline: environment["SWIFTPODS_OFFLINE"] == "1", refresh: false, hardened: false)
        let dependency = try NativeDependency(["name": name, "requirements": version.map { ["= " + $0] } ?? [">= 0"]])
        let requirement = try PodRequirement(dependency.requirements)
        let candidates = try catalog.candidates(dependency).filter { requirement.accepts($0.version) }.sorted { $0.version > $1.version }
        guard let first = candidates.first else { throw Diagnostic("SP-SPEC-MISSING", stage: "inspect", "No matching podspec", file: name) }
        if operation == "cat" { return try catalog.materialize(first).data }
        var paths: [String] = []
        for candidate in all ? candidates : [first] {
            let spec = try catalog.materialize(candidate)
            let path = cache.appendingPathComponent("specs/" + spec.name + "/" + spec.version.description + "/" + spec.name + ".podspec.json")
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try jsonData(spec.data).write(to: path, options: .atomic); paths.append(path.path)
        }
        return paths
    }
}
