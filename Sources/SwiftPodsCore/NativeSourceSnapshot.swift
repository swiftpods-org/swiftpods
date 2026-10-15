import Foundation

extension NativeSources {
    func sourceCheckoutIdentity(_ name: String, source: [String: Any], directory: URL) throws -> [String: String] {
        if source["git"] != nil { return try checkoutIdentity(name, source: source, directory: directory) }
        return (try? readObject(directory.appendingPathExtension("origin.json"))["checkout"] as? [String: String])
            ?? [:]
    }
    func sourceSnapshot(_ original: [String: Any], pod: String) throws -> URL {
        var source = original
        source["revision"] = try NativeSourceOptions.revision(source["revision"], file: pod)
        if !shouldUpdate(pod), source["revision"] == nil, let pin = pinnedCheckouts[pod],
            let revision = pin["revision"],
            ["svn", "hg"].contains(where: { source[$0] as? String != nil && source[$0] as? String == pin[$0] }),
            ["tag", "branch", "folder"].allSatisfy({ source[$0] as? String == pin[$0] })
        {
            source["revision"] = revision
        }
        var archive: URL?
        if let location = source["http"] as? String {
            archive = try download(location, pod: pod, headers: source["headers"] as? [String: String] ?? [:])
            source["_archive_digest"] = try FileFingerprint.file(archive!)
        }
        let key = try digest(jsonData(source))
        let directory = cache.appendingPathComponent("snapshots/" + key)
        let cacheLock = try NativeCacheLock(cache: cache, key: "snapshot-" + key)
        defer { cacheLock.release() }
        let receipt = directory.appendingPathExtension("origin.json")
        if FileManager.default.fileExists(atPath: directory.path), (!refresh && !shouldUpdate(pod)) || offline {
            var metadata = try readObject(receipt)
            guard
                metadata["fingerprint"] as? String == (try FileFingerprint.tree(directory, requireContainedLinks: true))
            else { throw Diagnostic("SP-CACHE-INTEGRITY", stage: "download", "Source snapshot changed", file: pod) }
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
        try jsonData(metadata).write(to: receipt, options: .atomic)
        if let revision = checkout["revision"] {
            var frozen = source
            frozen["revision"] = revision
            let identity = try digest(jsonData(frozen))
            let alias = directory.deletingLastPathComponent().appendingPathComponent(identity)
            if alias.path != directory.path {
                let aliasLock = try NativeCacheLock(cache: cache, key: "snapshot-" + identity)
                defer { aliasLock.release() }
                if !FileManager.default.fileExists(atPath: alias.path) {
                    try FileManager.default.copyItem(at: directory, to: alias)
                    try jsonData(metadata).write(to: alias.appendingPathExtension("origin.json"), options: .atomic)
                }
            }
        }
        return directory
    }
}
