import CryptoKit
import Foundation
import SwiftPodsManifest

/// Downloads, verifies and unpacks binary SDK archives, cached by their SHA-256.
///
/// A cache entry `<sha256>/` holds the verified `archive` and its unpacked `content`. Entries are built in a
/// temporary directory beside them and renamed into place, so an entry is either complete or absent, and two
/// installs sharing a cache need no lock: the second rename fails and that install uses the first one's entry.
struct BinaryStore {
    let cache: URL
    let runner: CommandRunner
    let offline: Bool

    /// The layout of older releases lives in other directories of the same cache and is left alone.
    private static let namespace = "v4"

    init(cache: URL, runner: CommandRunner, offline: Bool) {
        self.cache = cache.appendingPathComponent(Self.namespace, isDirectory: true)
        self.runner = runner
        self.offline = offline
    }

    static var defaultCache: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("SwiftPods/binaries", isDirectory: true)
    }

    struct Contents {
        let xcframeworks: [URL]
        let resources: [URL]
        /// The selected artifacts relative to the archive or directory, for messages and the package fingerprint.
        let xcframeworkPaths: [String]
        let resourcePaths: [String]
    }

    /// The `.xcframework` directories and resource bundles a binary provides.
    func contents(_ binary: Binary, podfileDirectory: URL) throws -> Contents {
        let root: URL
        switch binary.source {
        case .local(let path):
            let declared = URL(fileURLWithPath: path, relativeTo: podfileDirectory).standardizedFileURL
            guard FileTree.exists(declared) else {
                throw SwiftPodsError("Binary `\(binary.name)`: \(path) does not exist", file: binary.declaredAt.description)
            }
            if declared.pathExtension == "xcframework" {
                guard binary.xcframeworks == nil, binary.resources.isEmpty else {
                    throw SwiftPodsError(
                        "Binary `\(binary.name)`: `xcframeworks` and `resources` need `path` to be a directory",
                        file: binary.declaredAt.description)
                }
                return Contents(
                    xcframeworks: [declared], resources: [], xcframeworkPaths: [declared.lastPathComponent], resourcePaths: [])
            }
            root = declared
        case .remote(let url, let sha256):
            root = try unpacked(url: url, sha256: sha256, binary: binary, podfileDirectory: podfileDirectory)
        }
        let frameworks = try select(binary, in: root)
        let resources = try Self.locate(binary.resources, in: root, extension: "bundle", binary: binary)
        func relative(_ url: URL) -> String {
            let path = Paths.relative(from: root, to: url)
            return path == "." ? url.lastPathComponent : path
        }
        return Contents(
            xcframeworks: frameworks, resources: resources,
            xcframeworkPaths: frameworks.map(relative), resourcePaths: resources.map(relative))
    }

    private func select(_ binary: Binary, in root: URL) throws -> [URL] {
        if let paths = binary.xcframeworks {
            return try Self.locate(paths, in: root, extension: "xcframework", binary: binary)
        }
        let found = try Self.find(root, extension: "xcframework")
        guard !found.isEmpty else {
            let legacy = try Self.find(root, extension: "framework")
            throw SwiftPodsError(
                "Binary `\(binary.name)` contains no .xcframework", file: binary.declaredAt.description,
                hint: legacy.isEmpty ? nil : "It contains \(legacy.map(\.lastPathComponent).joined(separator: ", ")); "
                    + "wrap each with `xcodebuild -create-xcframework -framework …` and use `path:`")
        }
        return found
    }

    /// Paths inside the archive or directory, or bare names found at any depth (archives often nest a versioned folder).
    static func locate(_ paths: [String], in root: URL, extension pathExtension: String, binary: Binary) throws -> [URL] {
        guard Set(paths).count == paths.count else {
            throw SwiftPodsError(
                "Binary `\(binary.name)` selects the same .\(pathExtension) path more than once", file: binary.declaredAt.description)
        }
        let candidates = paths.contains(where: { !$0.contains("/") }) ? try find(root, extension: pathExtension) : []
        let candidatesByName = Dictionary(grouping: candidates, by: \.lastPathComponent)
        func foundHint() -> String {
            let values = candidates.prefix(50).map { Paths.relative(from: root, to: $0) }
            return "Found: " + values.joined(separator: ", ") + (candidates.count > values.count ? ", …" : "")
        }
        return try paths.map { path in
            if !path.contains("/") {
                let matches = candidatesByName[path] ?? []
                guard matches.count == 1 else {
                    throw SwiftPodsError(
                        matches.isEmpty ? "Binary `\(binary.name)` has no \(path)" : "Binary `\(binary.name)` has several \(path)",
                        file: binary.declaredAt.description, hint: foundHint())
                }
                return matches[0]
            }
            let url = root.appendingPathComponent(path).standardizedFileURL
            guard !path.hasPrefix("/"), !path.split(separator: "/").contains(".."), url.pathExtension == pathExtension,
                FileTree.isDirectory(url)
            else { throw SwiftPodsError("Binary `\(binary.name)` has no \(path)", file: binary.declaredAt.description) }
            return url
        }
    }

    /// Directories with the extension, not descending into them, skipping hidden entries, Finder metadata and links.
    static func find(_ root: URL, extension pathExtension: String) throws -> [URL] {
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles],
            errorHandler: { _, error in enumerationError = error; return false })
        else { throw SwiftPodsError("Cannot read \(root.path)") }
        var result: [URL] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true, values.isDirectory == true else { continue }
            if url.lastPathComponent == "__MACOSX" {
                enumerator.skipDescendants()
            } else if url.pathExtension.lowercased() == pathExtension {
                result.append(url.standardizedFileURL)
                enumerator.skipDescendants()
            }
        }
        if let enumerationError { throw SwiftPodsError("Cannot read \(root.path): \(enumerationError)") }
        return result.sorted { $0.path < $1.path }
    }

    /// The unpacked archive, from the cache or downloaded and verified.
    private func unpacked(url: String, sha256: String, binary: Binary, podfileDirectory: URL) throws -> URL {
        let sha256 = sha256.lowercased()
        guard sha256.count == 64, sha256.allSatisfy(\.isHexDigit) else {
            throw SwiftPodsError("Binary `\(binary.name)` has an invalid SHA-256", file: binary.declaredAt.description)
        }
        let entry = cache.appendingPathComponent(sha256, isDirectory: true)
        let content = entry.appendingPathComponent("content", isDirectory: true)
        if FileTree.isDirectory(content) {
            try FileTree.validateLinks(in: content)
            return content
        }
        guard !offline else {
            throw SwiftPodsError(
                "Binary `\(binary.name)` is not cached and --offline forbids downloading it", file: binary.declaredAt.description)
        }
        guard let source = URL(string: url), ["https", "file"].contains(source.scheme?.lowercased()) else {
            throw SwiftPodsError(
                "Binary `\(binary.name)` download URL must use HTTPS or be a file URL", file: binary.declaredAt.description)
        }

        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let staging = cache.appendingPathComponent(".tmp-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let archive = staging.appendingPathComponent("archive")
        if source.isFileURL {
            let local = URL(fileURLWithPath: source.path, relativeTo: podfileDirectory)
            do {
                try FileManager.default.copyItem(at: local, to: archive)
            } catch {
                throw SwiftPodsError("Binary `\(binary.name)`: cannot read \(local.path)", file: binary.declaredAt.description)
            }
        } else {
            do {
                _ = try runner.run(
                    "/usr/bin/curl",
                    ["--fail", "--location", "--silent", "--show-error", "--retry", "3", "--connect-timeout", "30",
                     "--output", archive.path, url],
                    in: nil)
            } catch {
                // The download URL and curl diagnostics can expose signed URLs, including redirect targets.
                throw SwiftPodsError(
                    "Cannot download binary `\(binary.name)` over HTTPS", file: binary.declaredAt.description)
            }
        }
        // The archive's own digest is not shown: copying it into the Podfile would trust whatever was downloaded.
        guard try Self.sha256(of: archive) == sha256 else {
            throw SwiftPodsError(
                "Binary `\(binary.name)`: the archive does not match the Podfile SHA-256", file: binary.declaredAt.description,
                hint: "Verify the archive source and update `sha256` only after authenticating the new release")
        }
        try FileTree.unpack(archive, into: staging.appendingPathComponent("content", isDirectory: true))
        if rename(staging.path, entry.path) != 0 {
            // Another install finished the same entry first.
            guard FileTree.isDirectory(content) else {
                throw SwiftPodsError("Cannot store binary `\(binary.name)` in \(cache.path): \(String(cString: strerror(errno)))")
            }
            try FileTree.validateLinks(in: content)
        }
        return content
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
