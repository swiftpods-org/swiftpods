import CryptoKit
import Darwin
import Foundation
import SwiftPodsManifest

/// Package catalogs read directly from a Git commit: one `<Name>.podfile` per package under `Packages/`.
///
/// The cache holds one bare repository per origin. Entries are read from committed blobs, so nothing is ever checked
/// out. Git runs with the user's own configuration, credentials and SSH settings.
final class GitCatalog: PackageCatalog, @unchecked Sendable {
    struct Resolution: Sendable, Equatable {
        let url: String
        let revision: String
        let entries: [SwiftPodsLock.Entry]
    }

    private struct Prepared {
        let repository: URL
        let revision: String
    }

    private struct EntryReference {
        let prepared: Prepared
        let path: String
        let object: String
    }

    private let cache: URL
    private let runner: CommandRunner
    private let update: Bool
    private let offline: Bool
    private let lockProvider: @Sendable () throws -> SwiftPodsLock?
    private let requiresLock: Bool
    // Guards prepared indexes and the resolutions recorded during this run.
    private let lock = NSLock()
    private var indexes: [String: [String: EntryReference]] = [:]
    private var recorded: [String: (url: String, revision: String, entries: [String: SwiftPodsLock.Entry])] = [:]

    static var defaultCache: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("SwiftPods/sources", isDirectory: true)
    }

    init(
        cache: URL, runner: CommandRunner, update: Bool, offline: Bool,
        requiresLock: Bool = false, lockProvider: (@Sendable () throws -> SwiftPodsLock?)? = nil
    ) {
        self.cache = cache
        self.runner = runner
        self.update = update
        self.offline = offline
        self.requiresLock = requiresLock
        self.lockProvider = lockProvider ?? { nil }
    }

    /// Exact catalog commits and raw entry hashes used during this run, in deterministic order.
    var resolutions: [Resolution] {
        lock.lock()
        defer { lock.unlock() }
        return recorded.values.map { value in
            Resolution(
                url: value.url, revision: value.revision,
                entries: value.entries.values.sorted { ($0.name.lowercased(), $0.name) < ($1.name.lowercased(), $1.name) })
        }.sorted { Data($0.url.utf8).lexicographicallyPrecedes(Data($1.url.utf8)) }
    }

    func entry(named name: String, in sources: [Source]) throws -> CatalogEntry? {
        let lockFile = try lockProvider()
        for source in sources {
            guard let reference = try index(source, lock: lockFile)[Self.nameKey(name)] else { continue }
            let data = try git(["-C", reference.prepared.repository.path, "cat-file", "blob", reference.object])
            guard let text = String(data: data, encoding: .utf8) else {
                throw SwiftPodsError("Catalog entry \(reference.path) is not valid UTF-8")
            }
            let digest = Self.sha256(data)
            let entry = try CatalogEntry.parse(text, file: source.url + "#" + reference.path, source: source.url)
            guard Self.nameKey(entry.name) == Self.nameKey(name) else {
                throw SwiftPodsError("Catalog file \((reference.path as NSString).lastPathComponent) declares `\(entry.name)`")
            }
            let locked = lockFile?.catalog(url: source.url)?.entries.first { Self.nameKey($0.name) == Self.nameKey(entry.name) }
            if let locked {
                guard locked.sha256 == digest else {
                    throw SwiftPodsError(
                        "Catalog entry `\(entry.name)` does not match SwiftPods.lock",
                        hint: "Review the catalog change, then run `swiftpods install --update-sources`")
                }
            } else if requiresLock {
                throw SwiftPodsError(
                    "Catalog entry `\(entry.name)` from \(source.url) is not recorded in SwiftPods.lock",
                    hint: "Run `swiftpods install` without --deployment; add --update-sources only if the catalog revision must move")
            }
            record(source: source, revision: reference.prepared.revision, entry: .init(name: entry.name, sha256: digest))
            return entry
        }
        return nil
    }

    /// All package names of a source, for search.
    func names(_ source: Source) throws -> [String] {
        try index(source, lock: lockProvider()).values.map {
            (($0.path as NSString).lastPathComponent as NSString).deletingPathExtension
        }.sorted()
    }

    /// Writes one commit's tree, then those of its direct gitlinks when `submodules` allows them, into `directory`.
    /// Returns the tracked paths under the resolver directories `.swiftpm` and `.build`.
    func exportPackageTree(url: String, revision: String, submodules: Bool, into directory: URL) throws -> [String] {
        guard GitPackageTree.isObjectID(revision) else { throw SwiftPodsError("Package override requires a full commit ID") }
        var metadataPaths: [String] = []
        let links = try exportRepository(
            url: url, revision: revision, prefix: "", allowSubmodules: submodules, into: directory, metadataPaths: &metadataPaths)
        for link in links {
            _ = try exportRepository(
                url: link.url, revision: link.revision, prefix: link.path, allowSubmodules: false, into: directory,
                metadataPaths: &metadataPaths)
        }
        return metadataPaths.sorted()
    }

    private func exportRepository(
        url: String, revision: String, prefix: String, allowSubmodules: Bool, into directory: URL,
        metadataPaths: inout [String]
    ) throws -> [(path: String, url: String, revision: String)] {
        let prepared: Prepared
        do {
            prepared = try prepare(Source(url: url, revision: revision), lock: nil, pinnedTree: true)
        } catch {
            throw SwiftPodsError("Cannot fetch override Git commit \(revision) from \(url): \(error)")
        }
        let repository = prepared.repository.path
        let listing = try git(["-C", repository, "ls-tree", "-r", "-t", "-l", "-z", "--full-tree", prepared.revision])
        let entries = try GitPackageTree.parse(listing, objectIDLength: prepared.revision.utf8.count, prefix: prefix)
        if prefix.isEmpty, !entries.contains(where: { $0.path == "Package.swift" && $0.isRegularFile }) {
            throw SwiftPodsError("Package override commit must contain a regular Package.swift at its root")
        }
        let links = entries.filter { $0.kind == .submodule }
        var origins: [String: String] = [:]
        if !links.isEmpty {
            guard allowSubmodules else {
                throw SwiftPodsError(prefix.isEmpty
                    ? "Package override contains a gitlink; use submodules: true to include direct submodules"
                    : "Package override submodule \(prefix) contains a nested gitlink")
            }
            guard let config = entries.first(where: { $0.path == (prefix.isEmpty ? "" : prefix + "/") + ".gitmodules" && $0.isRegularFile }) else {
                throw SwiftPodsError("Package override has gitlinks but no .gitmodules")
            }
            let parsed = try git(["-C", repository, "config", "--no-includes", "--blob", config.object, "--null", "--list"])
            origins = try GitPackageTree.submoduleOrigins(parsed, links: links)
        }

        let blobs = entries.filter { $0.kind != .directory && $0.kind != .submodule }
        let contents = try readBlobs(blobs.map(\.object), in: repository)
        for entry in entries {
            // Paths were checked by their text; the file system decides which names are the same, so nothing is
            // written through a link or over an earlier entry either (see FileTree.parentsAreDirectories).
            guard FileTree.parentsAreDirectories(entry.path.split(separator: "/").map(String.init), in: directory) else {
                throw SwiftPodsError("Package override path \(entry.path) has a parent that is not a directory")
            }
            let target = directory.appendingPathComponent(entry.path)
            switch entry.kind {
            case .directory, .submodule:
                if FileTree.exists(target) {
                    guard FileTree.isDirectory(target) else {
                        throw SwiftPodsError("Package override path \(entry.path) names an earlier entry")
                    }
                } else {
                    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                }
                chmod(target.path, 0o755)
            case .file(let executable):
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileTree.create(target, contents: contents[entry.object]!, executable: executable)
            case .symbolicLink:
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                let destination = try GitPackageTree.linkTarget(contents[entry.object]!, at: entry.path)
                try FileManager.default.createSymbolicLink(atPath: target.path, withDestinationPath: destination)
            }
            if GeneratedPackageMetadata.contains(entry.path) { metadataPaths.append(entry.path) }
        }
        return links.map { ($0.path, origins[$0.path]!, $0.object) }
    }

    /// The contents of `objects`, read by one `git cat-file --batch`.
    private func readBlobs(_ objects: [String], in repository: String) throws -> [String: Data] {
        guard !objects.isEmpty else { return [:] }
        let list = FileManager.default.temporaryDirectory.appendingPathComponent("swiftpods-objects-" + UUID().uuidString)
        try Data((objects.joined(separator: "\n") + "\n").utf8).write(to: list)
        defer { try? FileManager.default.removeItem(at: list) }
        let output = try runner.runData(
            "/bin/sh", ["-c", #"exec /usr/bin/git -C "$1" cat-file --batch < "$2""#, "swiftpods", repository, list.path], in: nil)
        var result: [String: Data] = [:]
        var index = output.startIndex
        while index < output.endIndex {
            guard let newline = output[index...].firstIndex(of: 0x0A),
                let header = String(data: output[index..<newline], encoding: .utf8)
            else { throw SwiftPodsError("Unexpected output from git cat-file") }
            let fields = header.split(separator: " ")
            guard fields.count == 3, fields[1] == "blob", let size = Int(fields[2]),
                output.distance(from: newline, to: output.endIndex) > size
            else { throw SwiftPodsError("Git cannot read object \(fields.first ?? "")") }
            let start = output.index(after: newline)
            result[String(fields[0])] = output[start..<output.index(start, offsetBy: size)]
            index = output.index(start, offsetBy: size + 1)
        }
        return result
    }

    private func record(source: Source, revision: String, entry: SwiftPodsLock.Entry) {
        lock.lock()
        defer { lock.unlock() }
        var value = recorded[source.url] ?? (source.url, revision, [:])
        value.revision = revision
        value.entries[Self.nameKey(entry.name)] = entry
        recorded[source.url] = value
    }

    private func index(_ source: Source, lock lockFile: SwiftPodsLock?) throws -> [String: EntryReference] {
        let key = source.url + "@" + (source.revision ?? "")
        lock.lock()
        defer { lock.unlock() }
        if let cached = indexes[key] { return cached }
        let prepared = try prepare(source, lock: lockFile)
        var resolution = recorded[source.url] ?? (source.url, prepared.revision, [:])
        guard resolution.revision == prepared.revision else {
            throw SwiftPodsError("Catalog \(source.url) resolved to more than one commit in a single install")
        }
        resolution.revision = prepared.revision
        recorded[source.url] = resolution
        let listing = try git(["-C", prepared.repository.path, "ls-tree", "-r", "-z", prepared.revision, "--", "Packages"])
        var index: [String: EntryReference] = [:]
        for raw in listing.split(separator: 0) {
            guard let record = String(data: Data(raw), encoding: .utf8), let tab = record.firstIndex(of: "\t") else {
                throw SwiftPodsError("Catalog \(source.url) has an invalid Git tree entry")
            }
            let fields = record[..<tab].split(separator: " ")
            let path = String(record[record.index(after: tab)...])
            guard fields.count == 3, path.hasPrefix("Packages/"), path.hasSuffix(".podfile") else { continue }
            guard fields[0] == "100644" || fields[0] == "100755", fields[1] == "blob" else {
                throw SwiftPodsError("Catalog \(source.url) contains a symbolic link or special entry at \(path)")
            }
            let name = Self.nameKey(((path as NSString).lastPathComponent as NSString).deletingPathExtension)
            if let other = index[name] {
                throw SwiftPodsError(
                    "Catalog \(source.url) declares `\(name)` twice: \((other.path as NSString).lastPathComponent) and \((path as NSString).lastPathComponent)")
            }
            index[name] = EntryReference(prepared: prepared, path: path, object: String(fields[2]))
        }
        indexes[key] = index
        return index
    }

    /// The cached repository of a source and the commit to read, fetching what is missing.
    private func prepare(_ source: Source, lock lockFile: SwiftPodsLock?, pinnedTree: Bool = false) throws -> Prepared {
        guard PackageLocation.isSafeCatalogSource(source.url) else {
            throw SwiftPodsError("Catalog source is not a supported HTTPS, SSH, or absolute local Git location: \(source.url)")
        }
        let locked = lockFile?.catalog(url: source.url)
        if requiresLock, !pinnedTree, locked == nil {
            throw SwiftPodsError(
                "Catalog \(source.url) is not recorded in SwiftPods.lock",
                hint: "Run `swiftpods install` without --deployment; add --update-sources only if the catalog revision must move")
        }
        if let requested = source.revision, let locked, requested.lowercased() != locked.revision {
            throw SwiftPodsError("Catalog \(source.url) revision \(requested) does not match SwiftPods.lock revision \(locked.revision)")
        }
        let desired = locked?.revision ?? source.revision?.lowercased()
        if let desired, !GitPackageTree.isObjectID(desired) {
            throw SwiftPodsError("Catalog revisions must be full 40- or 64-character commit hashes; found \(desired)")
        }

        let repository = cache.appendingPathComponent(Self.repositoryName(source.url), isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        // Serializes installs that share the cache; Git itself fails when two processes fetch into one repository.
        let lockDescriptor = open(repository.path + ".lock", O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard lockDescriptor >= 0 else {
            throw SwiftPodsError("Cannot lock the catalog cache \(repository.path): \(String(cString: strerror(errno)))")
        }
        defer { close(lockDescriptor) }
        // Waits for another install without blocking in flock, which an ignored Ctrl-C would not interrupt.
        while flock(lockDescriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR else {
                throw SwiftPodsError("Cannot lock the catalog cache \(repository.path): \(String(cString: strerror(errno)))")
            }
            try Interruption.check()
            usleep(100_000)
        }

        if FileTree.isDirectory(repository) {
            if let desired, (try? revision(desired, in: repository)) == desired {
                try retainRevision(desired, in: repository)
                return Prepared(repository: repository, revision: desired)
            }
            if desired == nil, !update, let head = try? revision("HEAD", in: repository) {
                try retainRevision(head, in: repository)
                return Prepared(repository: repository, revision: head)
            }
        }
        if pinnedTree, let desired {
            // SwiftPods 0.3.17 stored each override commit and submodule in its own bare repository.
            let previous = cache.appendingPathComponent(Self.pinnedTreeCacheName(url: source.url, revision: desired))
            if FileTree.isDirectory(previous),
                (try? git(["-C", previous.path, "config", "--local", "--get", "remote.origin.url"])) == Data((source.url + "\n").utf8),
                (try? revision(desired, in: previous)) == desired
            {
                return Prepared(repository: previous, revision: desired)
            }
        }
        guard !offline else {
            let suffix = desired.map { " at \($0)" } ?? ""
            throw SwiftPodsError("\(source.url)\(suffix) is not cached and --offline forbids fetching it")
        }
        if !FileTree.isDirectory(repository) {
            let objectFormat = desired?.utf8.count == 64 ? ["--object-format=sha256"] : []
            _ = try git(["init", "--bare", "--quiet"] + objectFormat + ["--", repository.path])
            _ = try git(["-C", repository.path, "remote", "add", "origin", source.url])
        }
        // A pinned commit needs that commit only, not the history and every ref.
        _ = try git(["-C", repository.path, "fetch", "--quiet", "--depth", "1", "--no-tags", "origin", desired ?? "HEAD"])
        let fetched = try revision("FETCH_HEAD", in: repository)
        guard desired == nil || fetched == desired else {
            throw SwiftPodsError("\(source.url) returned commit \(fetched) instead of \(desired!)")
        }
        try retainRevision(fetched, in: repository)
        _ = try git(["-C", repository.path, "update-ref", "HEAD", fetched])
        return Prepared(repository: repository, revision: fetched)
    }

    /// The cache directory of an origin.
    static func repositoryName(_ url: String) -> String {
        let label = PackageLocation.identity(url).filter { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
        return (label.isEmpty ? "catalog" : String(label.prefix(64))) + "-" + String(sha256(Data(url.utf8)).prefix(32)) + ".git"
    }

    static func pinnedTreeCacheName(url: String, revision: String) -> String {
        "override-" + String(sha256(Data((url + "\0" + revision).utf8)).prefix(32)) + ".git"
    }

    /// Retains commits used by lock files even after a later fetch moves HEAD.
    private func retainRevision(_ commit: String, in repository: URL) throws {
        let reference = "refs/swiftpods/pins/" + commit
        guard (try? revision(reference, in: repository)) != commit else { return }
        _ = try git(["-C", repository.path, "update-ref", reference, commit])
    }

    private func revision(_ expression: String, in repository: URL) throws -> String {
        let output = try git(["-C", repository.path, "rev-parse", "--verify", "--quiet", expression + "^{commit}"])
        return String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func git(_ arguments: [String]) throws -> Data {
        try runner.runData("/usr/bin/git", arguments, in: nil)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func nameKey(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }
}
