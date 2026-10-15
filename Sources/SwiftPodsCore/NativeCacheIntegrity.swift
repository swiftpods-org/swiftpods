import Foundation

enum NativeCacheIntegrity {
    static func verify(_ cache: URL) throws -> [String: Any] {
        let lease = try NativeCacheLease(cache: cache, exclusive: true)
        defer { withExtendedLifetime(lease) {} }
        var result = try ContentStore(cacheRoot: cache).verify()
        var counts: [String: Int] = [:]
        for kind in ["git", "prepared", "snapshots"] {
            for path in (try? FileManager.default.contentsOfDirectory(at: cache.appendingPathComponent(kind), includingPropertiesForKeys: [.isDirectoryKey])) ?? [] where path.lastPathComponent.range(of: #"\A[0-9a-f]{64}\z"#, options: .regularExpression) != nil {
                let receipt = path.appendingPathExtension(kind == "git" ? "sha256" : kind == "prepared" ? "json" : "origin.json")
                guard FileManager.default.fileExists(atPath: receipt.path) else { throw Diagnostic("SP-CACHE-INTEGRITY", stage: "cache", "Cached source receipt is missing", file: path.path) }
                let expected = kind == "git" ? try String(contentsOf: receipt, encoding: .utf8) : try readObject(receipt)["fingerprint"] as? String
                guard let expected, expected == (try FileFingerprint.tree(path, requireContainedLinks: true)) else { throw Diagnostic("SP-CACHE-INTEGRITY", stage: "cache", "Cached sources changed", file: path.path) }
                counts[kind, default: 0] += 1
            }
        }
        result["source_snapshots"] = counts
        return result
    }
}
