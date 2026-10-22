import Foundation

/// Removal reads ownership, never executes or authenticates cached payloads.
enum NativeCacheCleanup {
    private static let manager = FileManager.default

    static func run(cache: URL, pod: String?) throws -> Int {
        let content = cache.appendingPathComponent("content")
        var removed = 0
        if type(content) == .typeSymbolicLink {
            guard pod == nil else { throw invalid(content) }
            try manager.removeItem(at: content)
        } else {
            removed = try ContentStore(cacheRoot: cache).clean(pod)
        }
        for kind in ["prepared", "git", "snapshots", "podspecs"] {
            let root = cache.appendingPathComponent(kind)
            guard let pod else {
                removed += ((try? children(root)) ?? []).filter { address($0, podspec: kind == "podspecs") }.count
                try remove(root)
                continue
            }
            let entries = try children(root).filter { address($0, podspec: kind == "podspecs") }
            var metadata: [URL: [String: Any]] = [:]
            var owners: [String: Set<String>] = [:]
            for entry in entries {
                let receipt = kind == "podspecs" ? entry : entry.appendingPathExtension(kind == "prepared" ? "json" : "origin.json")
                guard type(receipt) == .typeRegular, let value = try? readObject(receipt) else { continue }
                metadata[entry] = value
                if let identity = try? ownershipIdentity(value, kind: kind) {
                    owners[identity, default: []].formUnion(value["pod_names"] as? [String] ?? [])
                }
            }
            for (entry, value) in metadata {
                if kind == "podspecs" || kind == "prepared" {
                    guard value["name"] as? String == pod else { continue }
                } else {
                    var names = Set(value["pod_names"] as? [String] ?? [])
                    if let identity = try? ownershipIdentity(value, kind: kind) {
                        names.formUnion(owners[identity] ?? [])
                    }
                    guard names.remove(pod) != nil else { continue }
                    if !names.isEmpty {
                        var updated = value
                        updated["pod_names"] = names.sorted()
                        try jsonData(updated).write(to: entry.appendingPathExtension("origin.json"), options: .atomic)
                        continue
                    }
                }
                try remove(entry)
                if kind != "podspecs" {
                    for suffix in kind == "prepared" ? ["json"] : ["origin.json", "sha256"] {
                        try remove(entry.appendingPathExtension(suffix))
                    }
                }
                removed += 1
            }
        }
        return removed
    }

    private static func address(_ path: URL, podspec: Bool) -> Bool {
        path.lastPathComponent.range(
            of: podspec ? #"\A[0-9a-f]{64}\.podspec\.json\z"# : #"\A[0-9a-f]{64}\z"#,
            options: .regularExpression) != nil
    }

    private static func ownershipIdentity(_ metadata: [String: Any], kind: String) throws -> String? {
        switch kind {
        case "git": return try NativeGitCache.ownershipIdentity(metadata)
        case "snapshots": return try NativeSnapshotCache.ownershipIdentity(metadata)
        default: return nil
        }
    }

    private static func children(_ path: URL) throws -> [URL] {
        guard let type = type(path) else { return [] }
        guard type == .typeDirectory else { throw invalid(path) }
        return try manager.contentsOfDirectory(at: path, includingPropertiesForKeys: nil)
    }

    private static func type(_ path: URL) -> FileAttributeType? {
        (try? manager.attributesOfItem(atPath: path.path)[.type]) as? FileAttributeType
    }

    private static func remove(_ path: URL) throws {
        if type(path) != nil { try manager.removeItem(at: path) }
    }

    private static func invalid(_ path: URL) -> Diagnostic {
        Diagnostic("SP-CACHE-INTEGRITY", stage: "cache", "Cache container is not a directory", file: path.path)
    }
}
