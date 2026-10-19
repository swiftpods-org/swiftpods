import Foundation

extension NativeSources {
    func sourceCheckoutIdentity(_ name: String, source: [String: Any], directory: URL) throws -> [String: String] {
        if source["git"] != nil { return try checkoutIdentity(name, source: source, directory: directory) }
        let metadata = try NativeSnapshotCache.verify(directory)
        var expected = source
        if let location = source["hg"] as? String {
            expected["hg"] = NativeSourceOptions.resolvedLocation(location, project: project)
        }
        var checkout = try NativeSnapshotCache.checkout(metadata, matching: expected)
        if let location = source["hg"] as? String { checkout["hg"] = location }
        return checkout
    }
    func sourceSnapshot(_ original: [String: Any], pod: String) throws -> URL {
        var source = original
        source["revision"] = try NativeSourceOptions.revision(source["revision"], file: pod)
        if !shouldUpdate(pod), let pin = pinnedCheckouts[pod],
            let revision = pin["revision"],
            ["svn", "hg"].contains(where: { source[$0] as? String != nil && source[$0] as? String == pin[$0] }),
            ["tag", "branch", "folder"].allSatisfy({ source[$0] as? String == pin[$0] })
        {
            source["revision"] = revision
        }
        if let location = source["hg"] as? String {
            guard !location.isEmpty, !CommandOptions.hasOptionPrefix(location) else {
                throw Diagnostic("SP-SOURCE-URL", stage: "download", "Invalid Mercurial source")
            }
            source["hg"] = NativeSourceOptions.resolvedLocation(location, project: project)
        }
        var archive: URL?
        if source["http"] != nil {
            archive = try downloadArchive(source, pod: pod)
            source["_archive_digest"] = try FileFingerprint.file(archive!)
            source["_archive_layout"] = "format-aware-v1"
        }
        let key = try digest(jsonData(source))
        let directory = cache.appendingPathComponent("snapshots/" + key)
        let cacheLock = try NativeCacheLock(cache: cache, key: "snapshot-" + key)
        defer { cacheLock.release() }
        let receipt = directory.appendingPathExtension("origin.json")
        if FileManager.default.fileExists(atPath: directory.path), !shouldUpdate(pod) || offline {
            var metadata = try NativeSnapshotCache.verify(directory)
            let checkout = try NativeSnapshotCache.checkout(metadata, matching: source)
            if let expected = source["revision"] as? String,
                expected.range(of: #"\A(?:[0-9]+|[0-9a-fA-F]{40})\z"#, options: .regularExpression) != nil,
                source["svn"] != nil || expected.count == 40,
                checkout["revision"]?.lowercased() != expected.lowercased()
            {
                throw Diagnostic(
                    "SP-CACHE-INTEGRITY", stage: "download", "Snapshot does not match its pinned revision", file: pod)
            }
            metadata["pod_names"] = Set((metadata["pod_names"] as? [String] ?? []) + [pod]).sorted()
            try jsonData(metadata).write(to: receipt, options: .atomic)
            return directory
        }
        guard !offline || archive != nil else {
            throw Diagnostic("SP-OFFLINE-MISSING", stage: "download", "Source revision is not cached", file: pod)
        }
        try FileManager.default.createDirectory(
            at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = directory.deletingLastPathComponent().appendingPathComponent(".snapshot-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staging) }
        var checkout: [String: String] = [:]
        if let archive {
            for key in ["http", "sha256", "sha1"] { if let value = source[key] as? String { checkout[key] = value } }
            try NativeArchive.extract(archive, source: source, destination: staging, pod: pod)
        } else {
            checkout = try NativeVCS.export(source, destination: staging)
        }
        let fingerprint = try FileFingerprint.tree(staging, requireContainedLinks: true)
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
        try FileManager.default.moveItem(at: staging, to: directory)
        let metadata: [String: Any] = ["fingerprint": fingerprint, "pod_names": [pod], "checkout": checkout]
        try NativeSnapshotCache.write(directory, metadata: metadata)
        if let revision = checkout["revision"] {
            var frozen = source
            frozen["revision"] = revision
            let identity = try digest(jsonData(frozen))
            let alias = directory.deletingLastPathComponent().appendingPathComponent(identity)
            if alias.path != directory.path {
                let aliasLock = try NativeCacheLock(cache: cache, key: "snapshot-" + identity)
                defer { aliasLock.release() }
                var aliasMetadata = metadata
                if FileManager.default.fileExists(atPath: alias.path) {
                    // A freshly exported revision can repair its older cached alias.
                    // Preserve shared ownership while replacing untrusted provenance.
                    let previous = try? readObject(alias.appendingPathExtension("origin.json"))
                    aliasMetadata["pod_names"] = Set(
                        (previous?["pod_names"] as? [String] ?? []) + [pod]
                    ).sorted()
                    try FileManager.default.removeItem(at: alias)
                }
                try FileManager.default.copyItem(at: directory, to: alias)
                try NativeSnapshotCache.write(alias, metadata: aliasMetadata)
            }
        }
        return directory
    }
}
