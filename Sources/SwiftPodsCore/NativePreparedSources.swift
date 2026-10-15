import Foundation

extension NativeSources {
    func prepareCached(_ spec: NativeSpec) throws {
        guard let directory = spec.directory else { return }
        let key = try digest(jsonData(["spec": spec.data, "checkout": spec.checkout, "raw_sources": FileFingerprint.tree(directory, requireContainedLinks: true)]))
        let root = cache.appendingPathComponent("prepared/" + key)
        let cacheLock = try NativeCacheLock(cache: cache, key: "prepared-" + key)
        defer { cacheLock.release() }
        let receipt = root.appendingPathExtension("json")
        if FileManager.default.fileExists(atPath: root.path), !cleanInstall {
            let metadata = try readObject(receipt)
            guard metadata["fingerprint"] as? String == (try FileFingerprint.tree(root, requireContainedLinks: true)) else { throw Diagnostic("SP-CACHE-INTEGRITY", stage: "prepare", "Prepared source cache changed", file: spec.name) }
            try FileManager.default.removeItem(at: directory)
            try FileManager.default.copyItem(at: root, to: directory)
            return
        }
        try prepare(spec)
        try FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = root.deletingLastPathComponent().appendingPathComponent(".prepared-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.copyItem(at: directory, to: staging)
        let fingerprint = try FileFingerprint.tree(staging, requireContainedLinks: true)
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
        try FileManager.default.moveItem(at: staging, to: root)
        try jsonData(["name": spec.name, "version": spec.version.description, "fingerprint": fingerprint]).write(to: receipt, options: .atomic)
    }
}
