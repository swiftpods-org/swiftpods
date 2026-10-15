import Foundation

enum NativePublication {
    static func push(
        arguments: [String], project: URL, bundle: RuntimeBundle, environment: [String: String],
        overrides: [String: String]
    ) throws -> [String: Any] {
        var args = arguments
        let local = args.contains("--local-only")
        args.removeAll { $0 == "--local-only" }
        guard let name = args.first else {
            throw Diagnostic("SP-CLI-ARGUMENT", stage: "repo", "Use repo push NAME [SPEC] [lint options]")
        }
        args.removeFirst()
        let path: URL
        if let raw = args.first, !raw.hasPrefix("-") {
            path = URL(fileURLWithPath: raw, relativeTo: project).standardizedFileURL
            args.removeFirst()
        } else {
            let files = try FileManager.default.contentsOfDirectory(at: project, includingPropertiesForKeys: nil).filter
            { $0.lastPathComponent.hasSuffix(".podspec") || $0.lastPathComponent.hasSuffix(".podspec.json") }
            guard files.count == 1 else {
                throw Diagnostic("SP-SPEC-MISSING", stage: "repo", "Specify exactly one podspec")
            }
            path = files[0]
        }
        let cache = URL(fileURLWithPath: bundle.environment(from: environment)["SWIFTPODS_CACHE_ROOT"]!)
        let repositories = NativeRepositories(cache: cache)
        guard var entry = try repositories.record(name), entry["name"] as? String == name,
            entry["kind"] as? String == "git"
        else {
            throw Diagnostic(
                "SP-REPO-MISSING", stage: "repo", "Publication requires a registered Git specs repository", file: name)
        }
        let directory = repositories.root.appendingPathComponent(name)
        try repositories.requireClean(directory)
        let dsl = try NativeDSL(bundle: bundle, environment: environment, directory: project, overrides: overrides)
        let data = try path.pathExtension == "json" ? readObject(path) : dsl.object("spec", ["path": path.path])
        let spec = try NativeSpec(data: data)
        let relative = spec.name + "/" + spec.version.description + "/" + spec.name + ".podspec.json"
        var destination = directory.appendingPathComponent(relative)
        guard !FileManager.default.fileExists(atPath: destination.deletingLastPathComponent().path) else {
            throw Diagnostic(
                "SP-REPO-VERSION-EXISTS", stage: "repo", "Published versions are immutable",
                file: spec.name + " " + spec.version.description)
        }
        let lint = try NativeValidation(bundle: bundle, environment: environment, overrides: overrides).run(
            action: "spec", arguments: [path.path] + args, project: project)
        guard lint["status"] as? String == "passed" else {
            throw Diagnostic("SP-REPO-LINT", stage: "repo", "Specification validation failed", file: path.path)
        }
        // Rejected pushes leave the registered checkout unchanged.
        let staging = repositories.root.appendingPathComponent(".publish-" + UUID().uuidString)
        var checkout = directory
        defer { try? FileManager.default.removeItem(at: staging) }
        if !local {
            guard let origin = entry["url"] as? String else {
                throw Diagnostic("SP-REPO-RECORD", stage: "repo", "Missing publication origin")
            }
            try command(
                "/usr/bin/git",
                ["clone"] + ((entry["branch"] as? String).map { ["--branch", $0] } ?? []) + [
                    "--", origin, staging.path,
                ])
            checkout = staging
            destination = staging.appendingPathComponent(relative)
            guard !FileManager.default.fileExists(atPath: destination.deletingLastPathComponent().path) else {
                throw Diagnostic(
                    "SP-REPO-VERSION-EXISTS", stage: "repo", "Published versions are immutable",
                    file: spec.name + " " + spec.version.description)
            }
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try jsonData(data).write(to: destination, options: .atomic)
        try command("/usr/bin/git", ["add", "--", destination.path], directory: checkout)
        try command(
            "/usr/bin/git",
            ["commit", "-m", "Add " + spec.name + " " + spec.version.description, "--", destination.path],
            directory: checkout)
        if !local { try command("/usr/bin/git", ["push", "origin", "HEAD"], directory: checkout) }
        var refreshed = local
        if local {
            entry["revision"] = try repositories.revision(directory)
            try repositories.write(entry)
        } else {
            refreshed = (try? repositories.update(name)) != nil
        }
        return [
            "status": "passed", "name": spec.name, "version": spec.version.description, "repository": name,
            "pushed": !local, "local_checkout_refreshed": refreshed, "validation": lint,
        ]
    }
}
