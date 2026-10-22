import Foundation

extension NativeSources {
    /// Git resolves local sources against the manifest, including their cache identity.
    func gitLocation(_ location: String) -> String {
        NativeSourceOptions.resolvedLocation(location, project: project)
    }

    func checkout(
        _ location: String, selector: String, fresh: Bool = false, submodules: Bool = false, pod: String? = nil
    )
        throws -> URL
    {
        guard !CommandOptions.hasOptionPrefix(location), !CommandOptions.hasOptionPrefix(selector), !selector.isEmpty
        else {
            throw Diagnostic("SP-SOURCE-URL", stage: "download", "Invalid Git source or revision")
        }
        let location = gitLocation(location)
        let identity = digest(Data((location + "\n" + selector + (submodules ? "\nsubmodules" : "")).utf8))
        let directory = cache.appendingPathComponent("git/" + identity)
        let cacheLock = try NativeCacheLock(cache: cache, key: identity)
        defer { cacheLock.release() }
        let refresh = fresh || (pod == nil && refreshRepositories)
        // A verified commit is immutable even when an update asks for it again.
        // Replacing it would invalidate paths held by another active consumer.
        if refresh, !offline,
            selector.range(of: #"\A[0-9a-fA-F]{40}(?:[0-9a-fA-F]{24})?\z"#, options: .regularExpression) != nil,
            let metadata = try? NativeGitCache.verify(directory),
            metadata["origin_identity"] as? String == digest(Data(location.utf8)),
            (metadata["commit"] as? String)?.lowercased() == selector.lowercased()
        {
            if let pod { try NativeGitCache.addOwners([pod], directory: directory, metadata: metadata) }
            return try cacheCommit(directory, location: location, refreshed: true)
        }
        if FileManager.default.fileExists(atPath: directory.path), !refresh || offline {
            let metadata = try NativeGitCache.verify(directory)
            guard metadata["origin_identity"] as? String == digest(Data(location.utf8)),
                selector.range(of: #"\A[0-9a-fA-F]{40}(?:[0-9a-fA-F]{24})?\z"#, options: .regularExpression) == nil
                    || (metadata["commit"] as? String)?.lowercased() == selector.lowercased()
            else {
                throw Diagnostic(
                    "SP-CACHE-INTEGRITY", stage: "cache", "Cached checkout does not match its source revision")
            }
            if let pod { try NativeGitCache.addOwners([pod], directory: directory, metadata: metadata) }
            return try cacheCommit(directory, location: location)
        }
        guard !offline else {
            throw Diagnostic("SP-OFFLINE-MISSING", stage: "download", "Git source is not cached: \(location)")
        }
        try FileManager.default.createDirectory(
            at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = directory.deletingLastPathComponent().appendingPathComponent(".git-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staging) }
        try command("/usr/bin/git", ["clone", "--no-checkout", "--", location, staging.path])
        let selectedCommit = try gitCommit(selector, in: staging)
        try command("/usr/bin/git", ["-C", staging.path, "checkout", "--detach", selectedCommit])
        if submodules, FileManager.default.fileExists(atPath: staging.appendingPathComponent(".gitmodules").path) {
            try command("/usr/bin/git", ["-C", staging.path, "submodule", "update", "--init", "--recursive"])
        }
        let revision = try ToolProcess.run("/usr/bin/git", ["-C", staging.path, "rev-parse", "HEAD"])
        guard revision.status == 0 else {
            throw Diagnostic("SP-SOURCE-REVISION", stage: "download", "Cannot record Git checkout revision")
        }
        let commit = String(decoding: revision.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        try FileManager.default.removeItem(at: staging.appendingPathComponent(".git"))
        _ = try FileFingerprint.tree(staging, requireContainedLinks: true)
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
        try FileManager.default.moveItem(at: staging, to: directory)
        try NativeGitCache.write(
            directory,
            metadata: [
                "commit": commit, "origin_identity": digest(Data(location.utf8)), "submodules": submodules,
                "pod_names": pod.map { [$0] } ?? [],
            ])
        return try cacheCommit(directory, location: location, refreshed: true)
    }

    private func gitCommit(_ selector: String, in directory: URL) throws -> String {
        // A remote branch without a local counterpart makes Git try to create
        // a branch even with --detach. Resolve its commit before checking it out.
        for reference in [selector, "refs/remotes/origin/" + selector] {
            let result = try ToolProcess.run(
                "/usr/bin/git",
                ["-C", directory.path, "rev-parse", "--verify", "--quiet", "--end-of-options", reference + "^{commit}"])
            if result.status == 0 {
                return String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        throw Diagnostic("SP-SOURCE-REVISION", stage: "download", "Cannot resolve Git revision " + selector)
    }

    func shouldUpdate(_ root: String) -> Bool { updating && (updateRoots.isEmpty || updateRoots.contains(root)) }
    func pinnedSelector(_ root: String, source: [String: Any]) -> String {
        let declared =
            NativeSourceOptions.gitSelector(source["commit"])
            ?? NativeSourceOptions.gitSelector(source["tag"]) ?? source["branch"] as? String ?? "HEAD"
        if !shouldUpdate(root), let pin = pinnedCheckouts[root], pin["git"] == source["git"] as? String,
            pin["tag"] == NativeSourceOptions.gitSelector(source["tag"]), pin["branch"] == source["branch"] as? String,
            let commit = pin["commit"]
        {
            return commit
        }
        return declared
    }
    func checkoutIdentity(_ root: String, source: [String: Any], directory: URL) throws -> [String: String] {
        guard let git = source["git"] as? String else { return [:] }
        let cacheLock = try NativeCacheLock(cache: cache, key: directory.lastPathComponent)
        defer { cacheLock.release() }
        let metadata = try NativeGitCache.verify(directory)
        guard let commit = metadata["commit"] as? String,
            metadata["origin_identity"] as? String == digest(Data(gitLocation(git).utf8))
        else { throw Diagnostic("SP-SOURCE-REVISION", stage: "download", "Invalid Git revision metadata", file: root) }
        try NativeGitCache.addOwners([root], directory: directory, metadata: metadata)
        try cacheCommit(directory, location: git)
        var identity = ["git": git, "commit": commit]
        for key in ["branch", "tag"] {
            if let value = NativeSourceOptions.gitSelector(source[key]) { identity[key] = value }
        }
        if source["submodules"] as? Bool == true { identity["submodules"] = "true" }
        return identity
    }
    @discardableResult
    func cacheCommit(_ directory: URL, location: String, refreshed: Bool = false) throws -> URL {
        let location = gitLocation(location)
        let metadata = try NativeGitCache.verify(directory)
        guard let commit = metadata["commit"] as? String,
            metadata["origin_identity"] as? String == digest(Data(location.utf8))
        else {
            throw Diagnostic("SP-CACHE-REVISION", stage: "cache", "Invalid cached Git revision", file: directory.path)
        }
        let destination = cache.appendingPathComponent(
            "git/"
                + digest(
                    Data(
                        (location + "\n" + commit + (metadata["submodules"] as? Bool == true ? "\nsubmodules" : ""))
                            .utf8)))
        guard destination.standardizedFileURL.path != directory.standardizedFileURL.path else { return directory }
        let cacheLock = try NativeCacheLock(cache: cache, key: destination.lastPathComponent)
        defer { cacheLock.release() }
        if FileManager.default.fileExists(atPath: destination.path) {
            var existing: [String: Any]?
            do {
                existing = try NativeGitCache.verify(destination)
            } catch {
                guard refreshed else { throw error }
                try FileManager.default.removeItem(at: destination)
            }
            if let existing {
                try NativeGitCache.addOwners(
                    metadata["pod_names"] as? [String] ?? [], directory: destination, metadata: existing)
                return destination
            }
        }
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".commit-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.copyItem(at: directory, to: staging)
        try FileManager.default.moveItem(at: staging, to: destination)
        try NativeGitCache.write(destination, metadata: metadata)
        return destination
    }
}
