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
        let previous = try? readObject(receipt)
        if let previous {
            // Older receipts registered peers on the selector copy only. Move
            // those owners to its revision copy before a refresh replaces it.
            try snapshotAlias(source, directory: directory, metadata: previous, refresh: false)
        }
        let fixedMetadata: [String: Any]? = {
            guard shouldUpdate(pod), !offline, let revision = source["revision"] as? String,
                source["svn"] != nil
                    ? revision.range(of: #"\A[0-9]+\z"#, options: .regularExpression) != nil
                    : source["hg"] != nil && revision.range(of: #"\A[0-9a-fA-F]{40}\z"#, options: .regularExpression) != nil,
                let metadata = try? NativeSnapshotCache.verify(directory),
                let checkout = try? NativeSnapshotCache.checkout(metadata, matching: source),
                checkout["revision"]?.lowercased() == revision.lowercased()
            else { return nil }
            return metadata
        }()
        if FileManager.default.fileExists(atPath: directory.path), !shouldUpdate(pod) || offline || fixedMetadata != nil {
            var metadata = try fixedMetadata ?? NativeSnapshotCache.verify(directory)
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
            return try snapshotAlias(source, directory: directory, metadata: metadata, refresh: true)
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
        let owners = previous?["checkout"] as? [String: String] == checkout
            ? previous?["pod_names"] as? [String] ?? [] : []
        let metadata: [String: Any] = [
            "fingerprint": fingerprint, "pod_names": Set(owners + [pod]).sorted(), "checkout": checkout,
        ]
        try NativeSnapshotCache.write(directory, metadata: metadata)
        return try snapshotAlias(source, directory: directory, metadata: metadata, refresh: true, repair: true)
    }

    @discardableResult
    private func snapshotAlias(
        _ source: [String: Any], directory: URL, metadata: [String: Any], refresh: Bool, repair: Bool = false
    ) throws -> URL {
        guard let checkout = metadata["checkout"] as? [String: String], let revision = checkout["revision"] else { return directory }
        var frozen = source
        frozen["revision"] = revision
        let identity = try digest(jsonData(frozen))
        let alias = directory.deletingLastPathComponent().appendingPathComponent(identity)
        guard alias.path != directory.path else { return directory }
        let aliasLock = try NativeCacheLock(cache: cache, key: "snapshot-" + identity)
        defer { aliasLock.release() }
        let receipt = alias.appendingPathExtension("origin.json")
        let previous = try? readObject(receipt)
        let owners = Set((previous?["pod_names"] as? [String] ?? []) + (metadata["pod_names"] as? [String] ?? [])).sorted()
        if !refresh {
            guard var previous, previous["checkout"] as? [String: String] == checkout else { return directory }
            previous["pod_names"] = owners
            // Ownership never authenticates or repairs the cached payload.
            try jsonData(previous).write(to: receipt, options: .atomic)
            return alias
        }
        if FileManager.default.fileExists(atPath: alias.path) {
            do {
                var verified = try NativeSnapshotCache.verify(alias)
                guard verified["checkout"] as? [String: String] == checkout,
                    verified["fingerprint"] as? String == metadata["fingerprint"] as? String
                else { throw Diagnostic("SP-CACHE-INTEGRITY", stage: "cache", "Revision snapshot differs from its source", file: alias.path) }
                verified["pod_names"] = owners
                try jsonData(verified).write(to: receipt, options: .atomic)
                return alias
            } catch {
                guard repair else { throw error }
            }
        }
        var updated = metadata
        updated["pod_names"] = owners
        if FileManager.default.fileExists(atPath: alias.path) { try FileManager.default.removeItem(at: alias) }
        try FileManager.default.copyItem(at: directory, to: alias)
        try NativeSnapshotCache.write(alias, metadata: updated)
        return alias
    }
}
