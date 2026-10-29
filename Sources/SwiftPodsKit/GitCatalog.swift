import CryptoKit
import Foundation
import SwiftPodsManifest

/// Package catalogs read from Git: one `<Name>.podfile` per package anywhere under `Packages/`, cached between runs.
final class GitCatalog: PackageCatalog, @unchecked Sendable {
    private let cache: URL
    private let runner: CommandRunner
    private let update: Bool
    private let offline: Bool
    // Guarded by `lock`: checkouts already prepared in this run and their file names by lowercased name.
    private let lock = NSLock()
    private var indexes: [String: [String: URL]] = [:]

    static var defaultCache: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("SwiftPods/sources", isDirectory: true)
    }

    init(cache: URL, runner: CommandRunner, update: Bool, offline: Bool) {
        self.cache = cache
        self.runner = runner
        self.update = update
        self.offline = offline
    }

    func entry(named name: String, in sources: [Source]) throws -> CatalogEntry? {
        for source in sources {
            guard let file = try index(source)[name.lowercased()] else { continue }
            let text = try String(contentsOf: file, encoding: .utf8)
            let entry = try CatalogEntry.parse(text, file: file.path, source: source.url)
            guard entry.name.lowercased() == name.lowercased() else {
                throw SwiftPodsError("Catalog file \(file.lastPathComponent) declares `\(entry.name)`", file: file.path)
            }
            return entry
        }
        return nil
    }

    /// All package names of a source, for search.
    func names(_ source: Source) throws -> [String] {
        try index(source).values.map { $0.deletingPathExtension().lastPathComponent }.sorted()
    }

    private func index(_ source: Source) throws -> [String: URL] {
        let key = source.url + "@" + (source.revision ?? "")
        lock.lock()
        defer { lock.unlock() }
        if let index = indexes[key] { return index }
        let checkout = try prepare(source)
        var index: [String: URL] = [:]
        // Subdirectories only group entries; names stay unique across the whole catalog.
        for file in CatalogTools.files(checkout) {
            let name = file.deletingPathExtension().lastPathComponent.lowercased()
            if let other = index[name] {
                throw SwiftPodsError(
                    "Catalog \(source.url) declares `\(name)` twice: \(other.lastPathComponent) and \(file.lastPathComponent)")
            }
            index[name] = file
        }
        indexes[key] = index
        return index
    }

    private func prepare(_ source: Source) throws -> URL {
        let digest = SHA256.hash(data: Data(PackageLocation.canonical(source.url).utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let checkout = cache.appendingPathComponent(PackageLocation.identity(source.url) + "-" + digest, isDirectory: true)
        let git = "/usr/bin/git"
        let exists = FileManager.default.fileExists(atPath: checkout.appendingPathComponent(".git").path)
        func current() -> String? {
            (try? runner.run(git, ["-C", checkout.path, "rev-parse", "HEAD"], in: nil))?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let revision = source.revision {
            if exists, current()?.hasPrefix(revision) == true { return checkout }
            guard !offline else { throw SwiftPodsError("Catalog \(source.url) at \(revision) is not cached and --offline forbids fetching it") }
            if !exists { try clone(source.url, to: checkout) }
            _ = try runner.run(git, ["-C", checkout.path, "fetch", "--quiet", "--depth", "1", "origin", revision], in: nil)
            _ = try runner.run(git, ["-C", checkout.path, "checkout", "--quiet", "--detach", "FETCH_HEAD"], in: nil)
            guard current()?.hasPrefix(revision) == true else {
                throw SwiftPodsError("Catalog \(source.url) has no commit \(revision)")
            }
            return checkout
        }
        if exists && !update { return checkout }
        guard !offline else { throw SwiftPodsError("Catalog \(source.url) is not cached and --offline forbids fetching it") }
        if exists {
            _ = try runner.run(git, ["-C", checkout.path, "fetch", "--quiet", "--depth", "1", "origin", "HEAD"], in: nil)
            _ = try runner.run(git, ["-C", checkout.path, "checkout", "--quiet", "--detach", "FETCH_HEAD"], in: nil)
        } else {
            try clone(source.url, to: checkout)
        }
        return checkout
    }

    private func clone(_ url: String, to checkout: URL) throws {
        try FileManager.default.createDirectory(at: checkout.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = checkout.deletingLastPathComponent().appendingPathComponent(".clone-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staging) }
        _ = try runner.run("/usr/bin/git", ["clone", "--quiet", "--depth", "1", url, staging.path], in: nil)
        try? FileManager.default.removeItem(at: checkout)
        try FileManager.default.moveItem(at: staging, to: checkout)
    }
}
