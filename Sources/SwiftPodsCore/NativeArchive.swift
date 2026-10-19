import Foundation

enum NativeArchive {
    static func extract(_ archive: URL, source: [String: Any], destination: URL, pod: String) throws {
        try NativeSourceOptions.validate(source, file: pod)
        let content = try Data(contentsOf: archive)
        try verifyChecksums(content, source: source, pod: pod)
        try ExecutionPolicy.validateArchive(archive.path)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try command("/usr/bin/tar", ["-xf", archive.path, "-C", destination.path])
        _ = try FileFingerprint.tree(destination, requireContainedLinks: true)
        if shouldFlatten(source, archive: archive) { try flatten(destination) }
        _ = try FileFingerprint.tree(destination, requireContainedLinks: true)
    }

    static func verifyChecksums(_ content: Data, source: [String: Any], pod: String) throws {
        if let expected = source["sha256"] as? String, digest(content) != expected.lowercased() {
            throw Diagnostic("SP-SOURCE-CHECKSUM", stage: "download", "Archive SHA-256 mismatch", file: pod)
        }
        if let expected = source["sha1"] as? String, NativeLock.sha1(content) != expected.lowercased() {
            throw Diagnostic("SP-SOURCE-CHECKSUM", stage: "download", "Archive SHA-1 mismatch", file: pod)
        }
    }

    private static func shouldFlatten(_ source: [String: Any], archive: URL) -> Bool {
        if let flatten = source["flatten"] as? Bool { return flatten }
        if let type = source["type"] as? String { return ["tar", "tgz", "tbz", "txz"].contains(type) }
        let path = (source["http"] as? String).flatMap { URL(string: $0)?.path } ?? archive.path
        return [".tar", ".tgz", ".tar.gz", ".tbz", ".tar.bz2", ".txz", ".tar.xz"].contains {
            path.lowercased().hasSuffix($0)
        }
    }

    private static func flatten(_ destination: URL) throws {
        let manager = FileManager.default
        let children = try manager.contentsOfDirectory(
            at: destination, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ).filter { $0.lastPathComponent != "__MACOSX" }
        guard children.count == 1 else { return }
        let wrapper = children[0]
        let values = try wrapper.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { return }

        // Move the wrapper aside first: a child can legitimately have the same
        // name as the wrapper, and must not collide with that existing directory.
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".flatten-" + UUID().uuidString)
        try manager.moveItem(at: wrapper, to: staging)
        defer { try? manager.removeItem(at: staging) }
        for child in try manager.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil) {
            try manager.moveItem(at: child, to: destination.appendingPathComponent(child.lastPathComponent))
        }
    }
}
