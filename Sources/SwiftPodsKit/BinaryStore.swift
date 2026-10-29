import CryptoKit
import Foundation
import SwiftPodsManifest

/// Downloads, verifies and unpacks binary SDK archives, cached by checksum.
struct BinaryStore {
    let cache: URL
    let runner: CommandRunner
    let offline: Bool

    static var defaultCache: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("SwiftPods/binaries", isDirectory: true)
    }

    struct Contents {
        let xcframeworks: [URL]
        let resources: [URL]
    }

    /// The `.xcframework` directories and resource bundles a binary provides.
    func contents(_ binary: Binary, podfileDirectory: URL) throws -> Contents {
        let root: URL
        switch binary.source {
        case .local(let path):
            root = URL(fileURLWithPath: path, relativeTo: podfileDirectory).standardizedFileURL
            guard FileManager.default.fileExists(atPath: root.path) else {
                throw SwiftPodsError("Binary `\(binary.name)`: \(path) does not exist", file: binary.declaredAt.description)
            }
            if root.pathExtension == "xcframework" {
                guard binary.xcframeworks == nil, binary.resources.isEmpty else {
                    throw SwiftPodsError(
                        "Binary `\(binary.name)`: `xcframeworks` and `resources` need `path` to be a directory", file: binary.declaredAt.description)
                }
                return Contents(xcframeworks: [root], resources: [])
            }
        case .remote(let url, let sha256):
            root = try unpacked(url: url, sha256: sha256, binary: binary)
        }
        let resources = try binary.resources.map { path in
            let url = root.appendingPathComponent(path).standardizedFileURL
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue else {
                throw SwiftPodsError(
                    "Binary `\(binary.name)` has no \(path)", file: binary.declaredAt.description,
                    hint: "Found: " + Self.find(root, extension: "bundle").map { Paths.relative(from: root, to: $0) }.joined(separator: ", "))
            }
            return url
        }
        return Contents(xcframeworks: try select(binary, in: root), resources: resources)
    }

    private func select(_ binary: Binary, in root: URL) throws -> [URL] {
        if let paths = binary.xcframeworks {
            return try paths.map { path in
                let url = root.appendingPathComponent(path).standardizedFileURL
                var directory: ObjCBool = false
                guard url.pathExtension == "xcframework", FileManager.default.fileExists(atPath: url.path, isDirectory: &directory),
                    directory.boolValue
                else {
                    throw SwiftPodsError("Binary `\(binary.name)` has no \(path)", file: binary.declaredAt.description,
                        hint: "Found: " + Self.find(root, extension: "xcframework").map { Paths.relative(from: root, to: $0) }.joined(separator: ", "))
                }
                return url
            }
        }
        let found = Self.find(root, extension: "xcframework")
        guard !found.isEmpty else {
            let legacy = Self.find(root, extension: "framework")
            throw SwiftPodsError(
                "Binary `\(binary.name)` contains no .xcframework", file: binary.declaredAt.description,
                hint: legacy.isEmpty ? nil : "It contains \(legacy.map(\.lastPathComponent).joined(separator: ", ")); "
                    + "wrap each with `xcodebuild -create-xcframework -framework …` and use `path:`")
        }
        return found
    }

    /// Directories with the extension, not descending into matches.
    static func find(_ root: URL, extension pathExtension: String) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        else { return [] }
        var result: [URL] = []
        for case let url as URL in enumerator {
            if url.lastPathComponent == "__MACOSX" {
                enumerator.skipDescendants()
            } else if url.pathExtension == pathExtension {
                result.append(url.standardizedFileURL)
                enumerator.skipDescendants()
            }
        }
        return result.sorted { $0.path < $1.path }
    }

    private func unpacked(url: String, sha256: String, binary: Binary) throws -> URL {
        let entry = cache.appendingPathComponent(sha256, isDirectory: true)
        let content = entry.appendingPathComponent("content", isDirectory: true)
        let complete = entry.appendingPathComponent(".complete")
        if FileManager.default.fileExists(atPath: complete.path) { return content }
        guard !offline else {
            throw SwiftPodsError("Binary `\(binary.name)` is not cached and --offline forbids downloading it", file: binary.declaredAt.description)
        }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: cache, withIntermediateDirectories: true)
        let staging = cache.appendingPathComponent(".download-" + UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }
        let archive = staging.appendingPathComponent("archive")
        _ = try runner.run("/usr/bin/curl", ["--fail", "--location", "--silent", "--show-error", "--retry", "3", "--output", archive.path, url], in: nil)
        let actual = try Self.sha256(of: archive)
        guard actual == sha256 else {
            throw SwiftPodsError(
                "Binary `\(binary.name)`: the archive's SHA-256 is \(actual), the Podfile expects \(sha256)",
                file: binary.declaredAt.description, hint: "If the new archive is trusted, update `sha256`")
        }
        let unpacked = staging.appendingPathComponent("content", isDirectory: true)
        try fileManager.createDirectory(at: unpacked, withIntermediateDirectories: true)
        switch try Self.format(of: archive, url: url) {
        case .zip: _ = try runner.run("/usr/bin/ditto", ["-x", "-k", archive.path, unpacked.path], in: nil)
        case .tar: _ = try runner.run("/usr/bin/tar", ["-xf", archive.path, "-C", unpacked.path], in: nil)
        }
        try? fileManager.removeItem(at: entry)
        try fileManager.createDirectory(at: entry, withIntermediateDirectories: true)
        try fileManager.moveItem(at: unpacked, to: content)
        try Data().write(to: complete)
        return content
    }

    enum Format { case zip, tar }

    static func format(of archive: URL, url: String) throws -> Format {
        let handle = try FileHandle(forReadingFrom: archive)
        defer { try? handle.close() }
        let magic = try handle.read(upToCount: 4) ?? Data()
        if magic.starts(with: [0x50, 0x4B]) { return .zip }
        // gzip, xz, bzip2 or a plain tar header
        if magic.starts(with: [0x1F, 0x8B]) || magic.starts(with: [0xFD, 0x37, 0x7A, 0x58]) || magic.starts(with: [0x42, 0x5A, 0x68]) {
            return .tar
        }
        let lower = url.lowercased()
        if lower.hasSuffix(".tar") { return .tar }
        throw SwiftPodsError("\(url) is not a zip or tar archive")
    }

    /// Hashes in chunks, draining autoreleased buffers per chunk so memory stays flat for large archives.
    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let done = try autoreleasepool { () throws -> Bool in
                guard let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty else { return true }
                hasher.update(data: chunk)
                return false
            }
            if done { break }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
