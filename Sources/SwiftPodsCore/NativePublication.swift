import Foundation

enum NativePublication {
    static func push(
        arguments: [String], project: URL, bundle: RuntimeBundle, environment: [String: String],
        overrides: [String: String]
    ) throws -> [String: Any] {
        _ = try NativeValidation.Options(Array(arguments.dropFirst()), additionalFlags: ["--local-only"])
        var args = arguments
        let local = args.contains("--local-only")
        args.removeAll { $0 == "--local-only" }
        guard let name = args.first else {
            throw Diagnostic("SP-CLI-ARGUMENT", stage: "repo", "Use repo push NAME [SPEC] [lint options]")
        }
        args.removeFirst()
        let path: URL
        if let raw = args.first, !CommandOptions.hasOptionPrefix(raw) {
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
        let cache = URL(fileURLWithPath: bundle.cacheRootPath(from: environment))
        let repositories = NativeRepositories(cache: cache)
        guard let initialEntry = try repositories.record(name), initialEntry["name"] as? String == name,
            initialEntry["kind"] as? String == "git"
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
        try validateDestination(destination, in: directory)
        guard !FileManager.default.fileExists(atPath: destination.deletingLastPathComponent().path) else {
            throw Diagnostic(
                "SP-REPO-VERSION-EXISTS", stage: "repo", "Published versions are immutable",
                file: spec.name + " " + spec.version.description)
        }
        // Freeze the evaluated Ruby once. Lint and its source installation must
        // read the same JSON bytes that will be committed to the specs repository.
        let snapshotDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "swiftpods-publication-" + UUID().uuidString)
        try FileManager.default.createDirectory(
            at: snapshotDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: snapshotDirectory) }
        let snapshot = snapshotDirectory.appendingPathComponent(spec.name + ".podspec.json")
        let serialized = try jsonData(data)
        try serialized.write(to: snapshot, options: .atomic)
        var lint = try NativeValidation(bundle: bundle, environment: environment, overrides: overrides).run(
            action: "spec", arguments: [snapshot.path] + args, project: project)
        guard lint["status"] as? String == "passed" else {
            throw Diagnostic("SP-REPO-LINT", stage: "repo", "Specification validation failed", file: path.path)
        }
        guard try Data(contentsOf: snapshot) == serialized else {
            throw Diagnostic("SP-REPO-CONFLICT", stage: "repo", "Specification changed during validation", file: path.path)
        }
        lint["specifications"] = (lint["specifications"] as? [[String: Any]] ?? []).map { original in
            var report = original
            if report["path"] as? String == snapshot.path { report["path"] = path.path }
            return report
        }
        // Lint may install dependencies, so take the exclusive lease afterwards.
        let lease = try NativeCacheLease(cache: cache, exclusive: true)
        defer { withExtendedLifetime(lease) {} }
        guard var entry = try repositories.record(name), try jsonData(entry) == jsonData(initialEntry) else {
            throw Diagnostic("SP-REPO-CONFLICT", stage: "repo", "Repository changed during validation", file: name)
        }
        try repositories.requireClean(directory)
        // Rejected pushes leave the registered checkout unchanged.
        let staging = repositories.root.appendingPathComponent(".publish-" + UUID().uuidString)
        var checkout = directory
        let transaction = try local ? NativeRepositoryPublication(directory: directory) : nil
        defer { try? FileManager.default.removeItem(at: staging) }
        if let transaction {
            checkout = transaction.staging
            destination = checkout.appendingPathComponent(relative)
        } else {
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
        try validateDestination(destination, in: checkout)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try serialized.write(to: destination, options: .atomic)
        let gitOptions = try local
            ? ["-c", "core.worktree=" + checkout.path] : publicationIdentity(in: directory)
        try command("/usr/bin/git", gitOptions + ["add", "--", destination.path], directory: checkout)
        try command(
            "/usr/bin/git",
            gitOptions + ["commit", "-m", "Add " + spec.name + " " + spec.version.description, "--", destination.path],
            directory: checkout)
        if !local { try command("/usr/bin/git", ["push", "origin", "HEAD"], directory: checkout) }
        var refreshed = local
        if local {
            entry["revision"] = try repositories.revision(checkout)
            try transaction!.publish(entry, repositories: repositories)
        } else {
            refreshed = (try? repositories.update(name)) != nil
        }
        return [
            "status": "passed", "name": spec.name, "version": spec.version.description, "repository": name,
            "pushed": !local, "local_checkout_refreshed": refreshed, "validation": lint,
        ]
    }

    /// Git cannot stage files through a symlink, even when its target is inside
    /// the checkout. Reject the path before creating directories or writing data.
    static func validateDestination(_ destination: URL, in checkout: URL) throws {
        guard let components = NativePath.relativeComponents(of: destination, to: checkout), !components.isEmpty,
            (try? FileManager.default.attributesOfItem(atPath: checkout.path)[.type]) as? FileAttributeType == .typeDirectory
        else {
            throw Diagnostic("SP-REPO-PATH", stage: "repo", "Publication requires a directory and a path inside its checkout", file: destination.path)
        }
        var path = checkout
        for component in components {
            path.appendPathComponent(component)
            if (try? FileManager.default.attributesOfItem(atPath: path.path)[.type]) as? FileAttributeType == .typeSymbolicLink {
                throw Diagnostic("SP-REPO-PATH", stage: "repo", "Publication path contains a symbolic link", file: path.path)
            }
        }
    }

    private static func publicationIdentity(in directory: URL) throws -> [String] {
        var options: [String] = []
        for key in ["user.name", "user.email"] {
            let result = try ToolProcess.run("/usr/bin/git", ["config", "--get", key], directory: directory)
            if result.status == 1 { continue }
            guard result.status == 0, var value = String(data: result.output, encoding: .utf8) else {
                throw Diagnostic("SP-REPO-GIT", stage: "repo", "Cannot read publication identity", file: directory.path)
            }
            if value.hasSuffix("\n") { value.removeLast() }
            options += ["-c", key + "=" + value]
        }
        return options
    }
}
