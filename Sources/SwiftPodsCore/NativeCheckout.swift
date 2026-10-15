import Foundation

extension NativeSources {
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
