import Foundation

extension NativeSources {
    func checkout(_ location: String, selector: String, fresh: Bool = false, submodules: Bool = false) throws -> URL {
        guard !location.hasPrefix("-"), !selector.hasPrefix("-"), !selector.isEmpty else {
            throw Diagnostic("SP-SOURCE-URL", stage: "download", "Invalid Git source or revision")
        }
        let identity = digest(Data((location + "\n" + selector + (submodules ? "\nsubmodules" : "")).utf8))
        let directory = cache.appendingPathComponent("git/" + identity)
        let cacheLock = try NativeCacheLock(cache: cache, key: identity)
        defer { cacheLock.release() }
        let receipt = directory.appendingPathExtension("sha256")
        if FileManager.default.fileExists(atPath: directory.path), (!refresh && !fresh) || offline {
            guard let expected = try? String(contentsOf: receipt, encoding: .utf8),
                try FileFingerprint.tree(directory, requireContainedLinks: true) == expected
            else {
                throw Diagnostic(
                    "SP-CACHE-INTEGRITY", stage: "cache", "Cached Git checkout changed", file: directory.path)
            }
            if !FileManager.default.fileExists(atPath: directory.appendingPathExtension("origin.json").path) {
                guard
                    selector.range(of: #"\A[0-9a-fA-F]{40}(?:[0-9a-fA-F]{24})?\z"#, options: .regularExpression) != nil
                else {
                    throw Diagnostic(
                        "SP-CACHE-REVISION", stage: "cache",
                        "Cached checkout predates revision metadata; refresh it with --repo-update",
                        file: directory.path)
                }
                try jsonData(["commit": selector, "origin_identity": digest(Data(location.utf8))]).write(
                    to: directory.appendingPathExtension("origin.json"), options: .atomic)
            }
            try cacheCommit(directory, location: location)
            return directory
        }
        guard !offline else {
            throw Diagnostic("SP-OFFLINE-MISSING", stage: "download", "Git source is not cached: \(location)")
        }
        try FileManager.default.createDirectory(
            at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = directory.deletingLastPathComponent().appendingPathComponent(".git-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staging) }
        try command("/usr/bin/git", ["clone", "--no-checkout", "--", location, staging.path])
        try command("/usr/bin/git", ["-C", staging.path, "checkout", "--detach", selector])
        if submodules, FileManager.default.fileExists(atPath: staging.appendingPathComponent(".gitmodules").path) {
            try command("/usr/bin/git", ["-C", staging.path, "submodule", "update", "--init", "--recursive"])
        }
        let revision = try ToolProcess.run("/usr/bin/git", ["-C", staging.path, "rev-parse", "HEAD"])
        guard revision.status == 0 else {
            throw Diagnostic("SP-SOURCE-REVISION", stage: "download", "Cannot record Git checkout revision")
        }
        let commit = String(decoding: revision.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        try FileManager.default.removeItem(at: staging.appendingPathComponent(".git"))
        let fingerprint = try FileFingerprint.tree(staging, requireContainedLinks: true)
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
        try FileManager.default.moveItem(at: staging, to: directory)
        try Data(fingerprint.utf8).write(to: receipt, options: .atomic)
        try jsonData(["commit": commit, "origin_identity": digest(Data(location.utf8)), "submodules": submodules])
            .write(to: directory.appendingPathExtension("origin.json"), options: .atomic)
        try cacheCommit(directory, location: location)
        return directory
    }
    func shouldUpdate(_ root: String) -> Bool { updating && (updateRoots.isEmpty || updateRoots.contains(root)) }
    func pinnedSelector(_ root: String, source: [String: Any]) -> String {
        if let commit = source["commit"] as? String { return commit }
        let declared = source["tag"] as? String ?? source["branch"] as? String ?? "HEAD"
        if !shouldUpdate(root), let pin = pinnedCheckouts[root], pin["git"] == source["git"] as? String,
            pin["tag"] == source["tag"] as? String, pin["branch"] == source["branch"] as? String,
            let commit = pin["commit"]
        {
            return commit
        }
        return declared
    }
    func checkoutIdentity(_ root: String, source: [String: Any], directory: URL) throws -> [String: String] {
        guard let git = source["git"] as? String else { return [:] }
        var metadata = try readObject(directory.appendingPathExtension("origin.json"))
        guard let commit = metadata["commit"] as? String,
            metadata["origin_identity"] as? String == digest(Data(git.utf8))
        else { throw Diagnostic("SP-SOURCE-REVISION", stage: "download", "Invalid Git revision metadata", file: root) }
        metadata["pod_names"] = Set((metadata["pod_names"] as? [String] ?? []) + [root]).sorted()
        try jsonData(metadata).write(to: directory.appendingPathExtension("origin.json"), options: .atomic)
        var identity = ["git": git, "commit": commit]
        for key in ["branch", "tag"] { if let value = source[key] as? String { identity[key] = value } }
        if source["submodules"] as? Bool == true { identity["submodules"] = "true" }
        return identity
    }
    func cacheCommit(_ directory: URL, location: String) throws {
        let metadata = try readObject(directory.appendingPathExtension("origin.json"))
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
        guard destination.standardizedFileURL.path != directory.standardizedFileURL.path else { return }
        let cacheLock = try NativeCacheLock(cache: cache, key: destination.lastPathComponent)
        defer { cacheLock.release() }
        guard !FileManager.default.fileExists(atPath: destination.path) else { return }
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".commit-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.copyItem(at: directory, to: staging)
        try FileManager.default.moveItem(at: staging, to: destination)
        try Data(FileFingerprint.tree(destination, requireContainedLinks: true).utf8).write(
            to: destination.appendingPathExtension("sha256"), options: .atomic)
        try jsonData(metadata).write(to: destination.appendingPathExtension("origin.json"), options: .atomic)
    }
}
