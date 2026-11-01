import CryptoKit
import Darwin
import Foundation
import SwiftPodsManifest

/// Package catalogs read directly from a Git commit: one `<Name>.podfile` per package under `Packages/`.
///
/// The cache is a bare repository. SwiftPods never checks an untrusted catalog out, so repository hooks,
/// smudge filters, untracked files and working-tree symlinks cannot affect catalog contents.
final class GitCatalog: PackageCatalog, @unchecked Sendable {
    private static let maximumEntryBytes = 1024 * 1024
    private static let maximumGitOutputBytes = 16 * 1024 * 1024
    private static let maximumStagingEntries = 200_000
    private static let maximumStagingObjects = 200_000
    private static let maximumStagingBytes: Int64 = 512 * 1024 * 1024
    private static let maximumAggregateFetchBytes: Int64 = 512 * 1024 * 1024
    private static let maximumPersistentCacheBytes: Int64 = 8 * 1024 * 1024 * 1024
    private static let maximumPersistentRepositories = 64
    private static let maximumCacheRootEntries = 4_096
    private static let maximumPersistentScanEntries = 1_000_000
    private static let maximumPersistentScanDepth = 64
    private static let persistentScanTimeout: TimeInterval = 30
    private static let maximumTreePathBytes = 16 * 1024
    private static let maximumTreePathDepth = 32
    private static let maximumResolvedAddresses = 64
    private static let dnsTimeout: TimeInterval = 30

    struct GitNetworkPolicy: Equatable {
        let configuration: [String]
    }

    struct Resolution: Sendable, Equatable {
        let url: String
        let revision: String
        let entries: [SwiftPodsLock.Entry]
    }

    private struct Prepared {
        let repository: URL
        let revision: String
        let identity: DirectoryIdentity
    }

    private struct DirectoryIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
    }

    /// Exact metadata for a cache lock after its descriptor and pathname have both been authenticated. A process
    /// can open the expected inode and then wait for another owner in `flock`; retaining every security-relevant
    /// field lets us reject a pathname replacement or in-place mutation before entering the cache transaction.
    private struct CacheLockSnapshot: Equatable {
        let device: UInt64
        let inode: UInt64
        let type: UInt32
        let owner: UInt32
        let group: UInt32
        let links: UInt64
        let mode: UInt32
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64

        init(_ status: stat) {
            device = UInt64(status.st_dev)
            inode = UInt64(status.st_ino)
            type = UInt32(status.st_mode & S_IFMT)
            owner = status.st_uid
            group = status.st_gid
            links = UInt64(status.st_nlink)
            mode = UInt32(status.st_mode & 0o7777)
            size = status.st_size
            modifiedSeconds = Int64(status.st_mtimespec.tv_sec)
            modifiedNanoseconds = Int64(status.st_mtimespec.tv_nsec)
            changedSeconds = Int64(status.st_ctimespec.tv_sec)
            changedNanoseconds = Int64(status.st_ctimespec.tv_nsec)
        }

        var isPrivateRegularFile: Bool {
            type == UInt32(S_IFREG) && owner == geteuid() && links == 1 && mode == 0o600
        }
    }

    private struct OpenedCacheLock {
        let descriptor: Int32
        let name: String
        let snapshot: CacheLockSnapshot
    }

    private final class PreparedCacheRoot {
        let url: URL
        let descriptor: Int32
        private let parentDescriptor: Int32
        private let name: String
        private let identity: DirectoryIdentity

        init(url: URL, descriptor source: Int32) throws {
            self.url = url.standardized
            name = self.url.lastPathComponent
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
                throw SwiftPodsError("Catalog cache has an unsafe final path component")
            }
            descriptor = fcntl(source, F_DUPFD_CLOEXEC, 0)
            guard descriptor >= 0 else { throw SwiftPodsError("Cannot retain catalog cache descriptor") }
            parentDescriptor = self.url.deletingLastPathComponent().path.withCString {
                open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            }
            guard parentDescriptor >= 0 else {
                close(descriptor)
                throw SwiftPodsError("Cannot retain catalog cache parent descriptor")
            }
            var status = stat()
            guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFDIR else {
                close(parentDescriptor)
                close(descriptor)
                throw SwiftPodsError("Cannot inspect retained catalog cache descriptor")
            }
            identity = DirectoryIdentity(device: UInt64(status.st_dev), inode: UInt64(status.st_ino))
            do {
                try verifyIdentity()
            } catch {
                close(parentDescriptor)
                close(descriptor)
                throw error
            }
        }

        deinit {
            close(parentDescriptor)
            close(descriptor)
        }

        func verifyIdentity() throws {
            var opened = stat()
            var linked = stat()
            var pathname = stat()
            guard fstat(descriptor, &opened) == 0,
                name.withCString({ fstatat(parentDescriptor, $0, &linked, AT_SYMLINK_NOFOLLOW) }) == 0,
                url.path.withCString({ lstat($0, &pathname) }) == 0,
                opened.st_mode & S_IFMT == S_IFDIR, linked.st_mode & S_IFMT == S_IFDIR,
                pathname.st_mode & S_IFMT == S_IFDIR,
                UInt64(opened.st_dev) == identity.device, UInt64(opened.st_ino) == identity.inode,
                UInt64(linked.st_dev) == identity.device, UInt64(linked.st_ino) == identity.inode,
                UInt64(pathname.st_dev) == identity.device, UInt64(pathname.st_ino) == identity.inode
            else { throw SwiftPodsError("Catalog cache root changed while it was in use") }
            try GitCatalog.validateCacheDescriptor(descriptor, path: url.path)
        }
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
    private let deploymentLock: @Sendable () throws -> SwiftPodsLock?
    private let requiresLock: Bool
    private let cacheLockTimeout: TimeInterval
    private let maximumFetchFileBytes: Int64
    private let aggregateFetchLimit: Int64
    private let persistentCacheByteLimit: Int64
    private let persistentRepositoryLimit: Int
    private let cacheLockWaitHook: (@Sendable (String) -> Void)?
    private let aggregateFetchLock = NSLock()
    private var aggregateFetchedBytes: Int64 = 0
    // Guards prepared indexes and the resolutions recorded during this run.
    private let lock = NSLock()
    private var indexes: [String: (prepared: Prepared, entries: [String: EntryReference])] = [:]
    private var recorded: [String: (url: String, revision: String, entries: [String: SwiftPodsLock.Entry])] = [:]

    static var defaultCache: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("SwiftPods/sources", isDirectory: true)
    }

    init(
        cache: URL, runner: CommandRunner, update: Bool, offline: Bool,
        deploymentLock: SwiftPodsLock? = nil, requiresLock: Bool = false,
        lockProvider: (@Sendable () throws -> SwiftPodsLock?)? = nil,
        cacheLockTimeout: TimeInterval = 30,
        maximumFetchFileBytes: Int64 = GitCatalog.maximumStagingBytes,
        maximumAggregateFetchBytes: Int64 = GitCatalog.maximumAggregateFetchBytes,
        maximumPersistentCacheBytes: Int64 = GitCatalog.maximumPersistentCacheBytes,
        maximumPersistentRepositories: Int = GitCatalog.maximumPersistentRepositories,
        _cacheLockWaitHook: (@Sendable (String) -> Void)? = nil
    ) {
        self.cache = cache
        self.runner = runner
        self.update = update
        self.offline = offline
        self.deploymentLock = lockProvider ?? { deploymentLock }
        self.requiresLock = requiresLock
        self.cacheLockTimeout = min(max(0, cacheLockTimeout), 5 * 60)
        self.maximumFetchFileBytes = min(max(1, maximumFetchFileBytes), Self.maximumStagingBytes)
        self.aggregateFetchLimit = min(max(1, maximumAggregateFetchBytes), Self.maximumAggregateFetchBytes)
        self.persistentCacheByteLimit = min(
            max(1, maximumPersistentCacheBytes), Self.maximumPersistentCacheBytes)
        self.persistentRepositoryLimit = min(
            max(1, maximumPersistentRepositories), Self.maximumPersistentRepositories)
        cacheLockWaitHook = _cacheLockWaitHook
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
        // Resolve and validate lock evidence before opening or creating any catalog-cache path.
        let deploymentLock = try deploymentLock()
        for source in sources {
            let entry = try withCacheLock(for: source) { cacheRoot -> CatalogEntry? in
                guard let reference = try index(
                    source, deploymentLock: deploymentLock, cacheRoot: cacheRoot
                )[Self.catalogNameKey(name)] else {
                    return nil
                }
                try verify(reference.prepared, in: cacheRoot)
                let data = try cacheGitData(
                    ["-C", reference.prepared.repository.path, "cat-file", "blob", reference.object],
                    maximumOutputBytes: Self.maximumEntryBytes, cacheRoot: cacheRoot)
                try verify(reference.prepared, in: cacheRoot)
                guard let text = String(data: data, encoding: .utf8) else {
                    throw SwiftPodsError("Catalog entry \(reference.path) is not valid UTF-8")
                }
                let digest = Self.sha256(data)
                let entry = try CatalogEntry.parse(text, file: source.url + "#" + reference.path, source: source.url)
                guard Self.catalogNameKey(entry.name) == Self.catalogNameKey(name) else {
                    throw SwiftPodsError("Catalog file \((reference.path as NSString).lastPathComponent) declares `\(entry.name)`")
                }
                let lockedEntry = deploymentLock?.catalog(url: source.url)?.entries.first {
                    Self.catalogNameKey($0.name) == Self.catalogNameKey(entry.name)
                }
                if let lockedEntry {
                    guard lockedEntry.sha256 == digest else {
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
            if let entry { return entry }
        }
        return nil
    }

    /// All package names of a source, for search.
    func names(_ source: Source) throws -> [String] {
        let deploymentLock = try deploymentLock()
        return try withCacheLock(for: source) { cacheRoot in
            try index(source, deploymentLock: deploymentLock, cacheRoot: cacheRoot).values.map {
                (($0.path as NSString).lastPathComponent as NSString).deletingPathExtension
            }.sorted()
        }
    }

    private func record(source: Source, revision: String, entry: SwiftPodsLock.Entry) {
        lock.lock()
        defer { lock.unlock() }
        let key = Self.originKey(source.url)
        var value = recorded[key] ?? (source.url, revision, [:])
        value.revision = revision
        value.entries[Self.catalogNameKey(entry.name)] = entry
        recorded[key] = value
    }

    private func index(
        _ source: Source, deploymentLock: SwiftPodsLock?, cacheRoot: PreparedCacheRoot
    ) throws -> [String: EntryReference] {
        let key = Self.originKey(source.url) + "@" + (source.revision ?? "")
        lock.lock()
        defer { lock.unlock() }
        if let cached = indexes[key], Self.directoryIdentity(cached.prepared.repository) == cached.prepared.identity {
            try cacheRoot.verifyIdentity()
            return cached.entries
        }
        indexes.removeValue(forKey: key)
        let prepared = try prepare(source, deploymentLock: deploymentLock, cacheRoot: cacheRoot)
        let origin = Self.originKey(source.url)
        var resolution = recorded[origin] ?? (source.url, prepared.revision, [:])
        guard resolution.revision == prepared.revision else {
            throw SwiftPodsError("Catalog \(source.url) resolved to more than one commit in a single install")
        }
        resolution.revision = prepared.revision
        recorded[origin] = resolution
        let listing = try cacheGit(
            ["-C", prepared.repository.path, "ls-tree", "-r", "-z", prepared.revision, "--", "Packages"],
            cacheRoot: cacheRoot)
        try verify(prepared, in: cacheRoot)
        var index: [String: EntryReference] = [:]
        for raw in listing.split(separator: "\0", omittingEmptySubsequences: true) {
            guard let tab = raw.firstIndex(of: "\t") else {
                throw SwiftPodsError("Catalog \(source.url) has an invalid Git tree entry")
            }
            let fields = raw[..<tab].split(separator: " ")
            let path = String(raw[raw.index(after: tab)...])
            guard fields.count == 3 else { throw SwiftPodsError("Catalog \(source.url) has an invalid Git tree entry") }
            guard Self.isSafeTreePath(path) else {
                // Never reflect an unsafe repository path into diagnostics: a newline or terminal control in a
                // catalog tree name must not become a CI workflow command or alter the surrounding log.
                throw SwiftPodsError("Catalog contains an unsafe Git tree path")
            }
            let mode = fields[0]
            let type = fields[1]
            let object = String(fields[2])
            guard mode == "100644" || mode == "100755", type == "blob" else {
                throw SwiftPodsError("Catalog \(source.url) contains a symbolic link or special entry at \(path)")
            }
            guard path.hasPrefix("Packages/"), path.hasSuffix(".podfile") else { continue }
            let declaredName = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            guard !declaredName.isEmpty, declaredName != ".", declaredName != ".." else {
                throw SwiftPodsError("Catalog contains an unsafe package entry name")
            }
            let name = Self.catalogNameKey(declaredName)
            if let other = index[name] {
                throw SwiftPodsError(
                    "Catalog \(source.url) declares `\(name)` twice: \((other.path as NSString).lastPathComponent) and \((path as NSString).lastPathComponent)")
            }
            index[name] = EntryReference(prepared: prepared, path: path, object: object)
        }
        indexes[key] = (prepared, index)
        return index
    }

    private func prepare(
        _ source: Source, deploymentLock: SwiftPodsLock?, cacheRoot: PreparedCacheRoot
    ) throws -> Prepared {
        guard PackageLocation.isSafeCatalogSource(source.url) else {
            throw SwiftPodsError("Catalog source is not a supported HTTPS, SSH, or absolute local Git location")
        }
        let locked = deploymentLock?.catalog(url: source.url)
        if requiresLock, locked == nil {
            throw SwiftPodsError(
                "Catalog \(source.url) is not recorded in SwiftPods.lock",
                hint: "Run `swiftpods install` without --deployment; add --update-sources only if the catalog revision must move")
        }
        if let requested = source.revision, let locked, requested.lowercased() != locked.revision {
            throw SwiftPodsError("Catalog \(source.url) revision \(requested) does not match SwiftPods.lock revision \(locked.revision)")
        }
        let desired = locked?.revision ?? source.revision?.lowercased()
        if let desired, !Self.isFullObjectID(desired) {
            throw SwiftPodsError("Catalog revisions must be full 40- or 64-character commit hashes; found \(desired)")
        }

        let digest = Self.originKey(source.url)
        let rawLabel = PackageLocation.identity(source.url)
        let label = String(rawLabel.filter {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".")
        }.prefix(64))
        try cacheRoot.verifyIdentity()
        let repository = cacheRoot.url.appendingPathComponent(
            (label.isEmpty ? "catalog" : label) + "-" + String(digest.prefix(32)) + ".git")
        let exists = Self.isDirectory(repository)

        if exists, desired != nil || !update {
            do {
                let revision = try validate(
                    repository: repository, source: source.url, desired: desired, cacheRoot: cacheRoot)
                try enforcePersistentCacheQuota(in: cacheRoot, preserving: repository.lastPathComponent)
                Self.touch(repository)
                guard let identity = Self.directoryIdentity(repository) else {
                    throw SwiftPodsError("Catalog cache changed while it was being validated")
                }
                try cacheRoot.verifyIdentity()
                return Prepared(repository: repository, revision: revision, identity: identity)
            } catch {
                if offline {
                    throw SwiftPodsError("Cached catalog \(source.url) is not a clean exact-origin repository", hint: "Remove the cache and fetch it again: \(error)")
                }
            }
        }
        guard !offline else {
            let suffix = desired.map { " at \($0)" } ?? ""
            throw SwiftPodsError("Catalog \(source.url)\(suffix) is not cached and --offline forbids fetching it")
        }
        let networkPolicy = try gitNetworkPolicy(for: source.url)

        let staging = cacheRoot.url.appendingPathComponent(".clone-" + UUID().uuidString + ".git")
        defer { try? Self.removeCacheItem(staging, in: cacheRoot) }
        if let desired {
            // A locked cold install needs one commit, not the repository's complete history and every ref.
            _ = try cacheGit(
                ["init", "--bare", "--quiet", "--template=", "--", staging.path], cacheRoot: cacheRoot)
            _ = try cacheGit(
                ["-C", staging.path, "remote", "add", "origin", source.url], cacheRoot: cacheRoot)
            _ = try cacheGit(
                ["-C", staging.path, "fetch", "--quiet", "--depth", "1", "--no-tags", "origin", desired],
                maximumFileBytes: maximumFetchFileBytes, networkPolicy: networkPolicy, cacheRoot: cacheRoot)
            _ = try cacheGit(
                ["-C", staging.path, "update-ref", "refs/heads/swiftpods-pinned", desired], cacheRoot: cacheRoot)
            _ = try cacheGit(
                ["-C", staging.path, "symbolic-ref", "HEAD", "refs/heads/swiftpods-pinned"],
                cacheRoot: cacheRoot)
        } else {
            _ = try cacheGit(
                [
                    "clone", "--bare", "--quiet", "--no-local", "--template=", "--depth", "1", "--no-tags",
                    "--", source.url, staging.path,
                ], maximumFileBytes: maximumFetchFileBytes, networkPolicy: networkPolicy, cacheRoot: cacheRoot)
        }
        let stagingBytes = try validateStagingBudget(staging, cacheRoot: cacheRoot)
        let revision = try validate(
            repository: staging, source: source.url, desired: desired, cacheRoot: cacheRoot)
        try consumeAggregateFetchBudget(stagingBytes)
        try cacheRoot.verifyIdentity()
        if FileManager.default.fileExists(atPath: repository.path) || (try? FileManager.default.destinationOfSymbolicLink(atPath: repository.path)) != nil {
            try Self.removeCacheItem(repository, in: cacheRoot)
        }
        try Self.moveCacheItem(from: staging, to: repository, in: cacheRoot)
        do {
            try enforcePersistentCacheQuota(in: cacheRoot, preserving: repository.lastPathComponent)
        } catch {
            try? Self.removeCacheItem(repository, in: cacheRoot)
            throw error
        }
        Self.touch(repository)
        guard let identity = Self.directoryIdentity(repository) else {
            throw SwiftPodsError("Catalog cache changed while it was being installed")
        }
        try cacheRoot.verifyIdentity()
        return Prepared(repository: repository, revision: revision, identity: identity)
    }

    /// Serializes a source's complete cache transaction across SwiftPods processes. The entry blob is
    /// consumed before this lock is released, so a concurrent updater cannot replace the repository
    /// between `ls-tree` and `cat-file`.
    private func withCacheLock<T>(
        for source: Source, _ operation: (PreparedCacheRoot) throws -> T
    ) throws -> T {
        let cacheRoot = try secureCacheRoot()
        let globalLock = try openCacheLock(named: ".lock-global", in: cacheRoot)
        defer { close(globalLock.descriptor) }
        try acquireCacheLock(globalLock, source: "the persistent cache", in: cacheRoot)
        defer { _ = flock(globalLock.descriptor, LOCK_UN) }
        // One lock per origin leaked a permanent inode for every URL ever mentioned by a Podfile. The global lock
        // already serializes root maintenance; a fixed bucket retains the narrower protocol without unbounded state.
        try reapLegacyCacheResidue(in: cacheRoot)
        try verifyAcquiredCacheLock(globalLock, in: cacheRoot)
        let lockName = ".lock-source-" + String(Self.originKey(source.url).prefix(2))
        let sourceLock = try openCacheLock(named: lockName, in: cacheRoot)
        defer { close(sourceLock.descriptor) }
        try acquireCacheLock(sourceLock, source: source.url, in: cacheRoot)
        defer { _ = flock(sourceLock.descriptor, LOCK_UN) }
        // The global pathname can also be replaced while this process waits for the source lock. Revalidate both
        // held descriptors immediately before any Git or cache mutation.
        try verifyAcquiredCacheLock(globalLock, in: cacheRoot)
        try verifyAcquiredCacheLock(sourceLock, in: cacheRoot)
        try cacheRoot.verifyIdentity()
        let result = try operation(cacheRoot)
        try cacheRoot.verifyIdentity()
        try verifyAcquiredCacheLock(sourceLock, in: cacheRoot)
        try verifyAcquiredCacheLock(globalLock, in: cacheRoot)
        return result
    }

    /// Removes only names produced by older SwiftPods cache transactions. This runs while `.lock-global` is held, so
    /// no current writer can own a legacy origin lock or a clone staging directory. Unknown names are never guessed at
    /// destructively, and every candidate is validated without following links before removal.
    private func reapLegacyCacheResidue(in cacheRoot: PreparedCacheRoot) throws {
        var changed = false
        var budget = PersistentScanBudget()
        for name in try Self.cacheRootNames(in: cacheRoot) {
            if Self.isLegacyOriginLockName(name) {
                changed = try removeLegacyOriginLock(named: name, in: cacheRoot) || changed
                continue
            }
            guard Self.isCloneStagingName(name) else { continue }
            let candidate = cacheRoot.url.appendingPathComponent(name, isDirectory: true)
            let status = try Self.statusNoFollow(candidate)
            guard status.st_mode & S_IFMT == S_IFDIR, status.st_uid == geteuid() else {
                throw SwiftPodsError("Catalog clone residue is not an owned directory")
            }
            _ = try Self.persistentCacheUsage(candidate, status: status, budget: &budget)
            try Self.removeCacheItem(candidate, in: cacheRoot)
            changed = true
        }
        if changed {
            guard fsync(cacheRoot.descriptor) == 0 else {
                throw SwiftPodsError("Cannot synchronize catalog cache residue cleanup")
            }
        }
    }

    private func removeLegacyOriginLock(
        named name: String, in cacheRoot: PreparedCacheRoot
    ) throws -> Bool {
        var linked = stat()
        guard name.withCString({
            fstatat(cacheRoot.descriptor, $0, &linked, AT_SYMLINK_NOFOLLOW)
        }) == 0,
            linked.st_mode & S_IFMT == S_IFREG, linked.st_uid == geteuid(), linked.st_nlink == 1
        else { throw SwiftPodsError("Legacy catalog cache lock is not a private regular file") }
        let descriptor = name.withCString {
            openat(cacheRoot.descriptor, $0, O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else { throw SwiftPodsError("Cannot inspect a legacy catalog cache lock") }
        defer { close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
            opened.st_dev == linked.st_dev, opened.st_ino == linked.st_ino,
            opened.st_mode & S_IFMT == S_IFREG, opened.st_uid == geteuid(), opened.st_nlink == 1
        else { throw SwiftPodsError("Legacy catalog cache lock changed while it was opened") }

        // An older SwiftPods process may still be using this per-origin lock. Do not switch to the new bucket
        // protocol until that process has left its critical section, or both versions could mutate one repository.
        try waitForCacheLock(descriptor, name: name, source: "a legacy catalog cache lock")
        defer { _ = flock(descriptor, LOCK_UN) }
        var immediatelyBefore = stat()
        guard name.withCString({
            fstatat(cacheRoot.descriptor, $0, &immediatelyBefore, AT_SYMLINK_NOFOLLOW)
        }) == 0,
            immediatelyBefore.st_dev == opened.st_dev, immediatelyBefore.st_ino == opened.st_ino,
            immediatelyBefore.st_mode & S_IFMT == S_IFREG,
            name.withCString({ unlinkat(cacheRoot.descriptor, $0, 0) }) == 0
        else { throw SwiftPodsError("Legacy catalog cache lock changed during cleanup") }
        return true
    }

    private func openCacheLock(named name: String, in cacheRoot: PreparedCacheRoot) throws -> OpenedCacheLock {
        var descriptor = name.withCString {
            openat(
                cacheRoot.descriptor, $0,
                O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK,
                S_IRUSR | S_IWUSR)
        }
        if descriptor < 0, errno == EEXIST {
            descriptor = name.withCString {
                openat(cacheRoot.descriptor, $0, O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            }
        }
        guard descriptor >= 0 else {
            throw SwiftPodsError("Cannot lock catalog cache: \(String(cString: strerror(errno)))")
        }
        var status = stat()
        var linked = stat()
        guard fstat(descriptor, &status) == 0,
            name.withCString({ fstatat(cacheRoot.descriptor, $0, &linked, AT_SYMLINK_NOFOLLOW) }) == 0,
            status.st_mode & S_IFMT == S_IFREG, linked.st_mode & S_IFMT == S_IFREG,
            status.st_dev == linked.st_dev, status.st_ino == linked.st_ino,
            status.st_uid == geteuid(), status.st_nlink == 1
        else {
            close(descriptor)
            throw SwiftPodsError("Catalog cache lock is not a private regular file")
        }
        do {
            try Self.secureDescriptor(descriptor, mode: 0o600, kind: "Catalog cache lock")
            try cacheRoot.verifyIdentity()
            let snapshot = try authenticatedCacheLockSnapshot(
                descriptor: descriptor, name: name, in: cacheRoot)
            try cacheRoot.verifyIdentity()
            return OpenedCacheLock(descriptor: descriptor, name: name, snapshot: snapshot)
        } catch {
            close(descriptor)
            throw error
        }
    }

    private func acquireCacheLock(
        _ lock: OpenedCacheLock, source: String, in cacheRoot: PreparedCacheRoot
    ) throws {
        try waitForCacheLock(lock.descriptor, name: lock.name, source: source)
        do {
            try verifyAcquiredCacheLock(lock, in: cacheRoot)
        } catch {
            _ = flock(lock.descriptor, LOCK_UN)
            throw error
        }
    }

    private func waitForCacheLock(_ descriptor: Int32, name: String, source: String) throws {
        let started = DispatchTime.now().uptimeNanoseconds
        let duration = UInt64(cacheLockTimeout * 1_000_000_000)
        let deadline = started.addingReportingOverflow(duration).partialValue
        var reportedWait = false
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let failure = errno
            if failure == EINTR { continue }
            guard failure == EWOULDBLOCK || failure == EAGAIN else {
                throw SwiftPodsError("Cannot lock catalog cache: \(String(cString: strerror(failure)))")
            }
            if !reportedWait {
                reportedWait = true
                cacheLockWaitHook?(name)
            }
            let now = DispatchTime.now().uptimeNanoseconds
            guard !started.addingReportingOverflow(duration).overflow, now < deadline else {
                throw SwiftPodsError("Timed out waiting for the catalog cache lock for \(source)")
            }
            let remaining = deadline - now
            usleep(useconds_t(min(50_000, max(1, remaining / 1_000))))
        }
    }

    private func verifyAcquiredCacheLock(
        _ lock: OpenedCacheLock, in cacheRoot: PreparedCacheRoot
    ) throws {
        try cacheRoot.verifyIdentity()
        let current = try authenticatedCacheLockSnapshot(
            descriptor: lock.descriptor, name: lock.name, in: cacheRoot)
        guard current == lock.snapshot else {
            throw SwiftPodsError("Catalog cache lock changed while it was being acquired")
        }
        try cacheRoot.verifyIdentity()
    }

    private func authenticatedCacheLockSnapshot(
        descriptor: Int32, name: String, in cacheRoot: PreparedCacheRoot
    ) throws -> CacheLockSnapshot {
        var opened = stat()
        var linked = stat()
        guard fstat(descriptor, &opened) == 0,
            name.withCString({
                fstatat(cacheRoot.descriptor, $0, &linked, AT_SYMLINK_NOFOLLOW)
            }) == 0
        else { throw SwiftPodsError("Catalog cache lock changed while it was being acquired") }
        let openedSnapshot = CacheLockSnapshot(opened)
        let linkedSnapshot = CacheLockSnapshot(linked)
        guard openedSnapshot == linkedSnapshot, openedSnapshot.isPrivateRegularFile else {
            throw SwiftPodsError("Catalog cache lock changed while it was being acquired")
        }
        return openedSnapshot
    }

    /// A shallow fetch can still contain an unexpectedly large snapshot. Reject it before it becomes durable cache.
    private func validateStagingBudget(
        _ repository: URL, cacheRoot: PreparedCacheRoot
    ) throws -> Int64 {
        try cacheRoot.verifyIdentity()
        guard Self.isDirectory(repository) else { throw SwiftPodsError("Catalog staging repository is not a directory") }
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: repository, includingPropertiesForKeys: nil, options: [],
            errorHandler: { _, error in enumerationError = error; return false })
        else { throw SwiftPodsError("Cannot inspect the catalog staging repository") }
        var entries = 0
        var bytes: Int64 = 0
        for case let path as URL in enumerator {
            var status = stat()
            guard path.path.withCString({ lstat($0, &status) }) == 0 else {
                throw SwiftPodsError("Catalog staging repository changed while it was inspected")
            }
            let type = status.st_mode & S_IFMT
            guard type == S_IFDIR || type == S_IFREG else {
                throw SwiftPodsError("Catalog staging repository contains a symbolic link or special file")
            }
            entries += 1
            guard entries <= Self.maximumStagingEntries else {
                throw SwiftPodsError("Catalog staging repository contains too many files")
            }
            if type == S_IFREG {
                let allocated = Int64(status.st_blocks) * 512
                let amount = max(status.st_size, allocated)
                guard amount >= 0, amount <= Self.maximumStagingBytes - bytes else {
                    throw SwiftPodsError("Catalog staging repository exceeds the 512 MiB disk budget")
                }
                bytes += amount
            }
        }
        if let enumerationError { throw SwiftPodsError("Cannot inspect the catalog staging repository: \(enumerationError)") }

        let inventory = try cacheGit(
            ["-C", repository.path, "count-objects", "-v"], cacheRoot: cacheRoot)
        var fields: [String: Int64] = [:]
        for line in inventory.split(whereSeparator: \.isNewline) {
            let pair = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.count == 2, let value = Int64(pair[1]) { fields[pair[0]] = value }
        }
        let objects = (fields["count"] ?? 0) + (fields["in-pack"] ?? 0)
        let objectBytes = ((fields["size"] ?? 0) + (fields["size-pack"] ?? 0) + (fields["size-garbage"] ?? 0)) * 1_024
        guard objects >= 0, objects <= Self.maximumStagingObjects else {
            throw SwiftPodsError("Catalog staging repository contains too many Git objects")
        }
        guard objectBytes >= 0, objectBytes <= Self.maximumStagingBytes else {
            throw SwiftPodsError("Catalog staging repository exceeds the 512 MiB Git object budget")
        }
        try cacheRoot.verifyIdentity()
        return bytes
    }

    /// Charges only repositories fetched by this catalog instance. Reusing a previously validated cache
    /// does not consume this run's budget.
    private func consumeAggregateFetchBudget(_ bytes: Int64) throws {
        try aggregateFetchLock.withLock {
            guard bytes >= 0, bytes <= aggregateFetchLimit - aggregateFetchedBytes else {
                throw SwiftPodsError(
                    "Catalog fetches exceed the aggregate disk budget for this run (\(aggregateFetchLimit) bytes)")
            }
            aggregateFetchedBytes += bytes
        }
    }

    private struct PersistentCacheCandidate {
        let url: URL
        let bytes: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
    }

    private struct PersistentScanBudget {
        var entries = 0
        let started = DispatchTime.now().uptimeNanoseconds
        let duration = UInt64(GitCatalog.persistentScanTimeout * 1_000_000_000)

        mutating func consume(depth: Int) throws {
            guard depth <= GitCatalog.maximumPersistentScanDepth else {
                throw SwiftPodsError("Catalog cache exceeds its directory-depth limit")
            }
            entries += 1
            guard entries <= GitCatalog.maximumPersistentScanEntries else {
                throw SwiftPodsError("Catalog cache contains too many filesystem entries")
            }
            let elapsed = DispatchTime.now().uptimeNanoseconds.subtractingReportingOverflow(started)
            guard !elapsed.overflow, elapsed.partialValue <= duration else {
                throw SwiftPodsError("Catalog cache inspection exceeded its time limit")
            }
        }
    }

    /// Enforces a lifetime quota under the cache-global lock. Unknown top-level entries are accounted but never
    /// guessed at destructively; only repositories whose names match SwiftPods' origin-key scheme are evicted.
    private func enforcePersistentCacheQuota(
        in cacheRoot: PreparedCacheRoot, preserving: String
    ) throws {
        try cacheRoot.verifyIdentity()
        let children = try Self.cacheRootNames(in: cacheRoot)
        var bytes: Int64 = 0
        var repositories = 0
        var candidates: [PersistentCacheCandidate] = []
        var budget = PersistentScanBudget()
        for name in children {
            let child = cacheRoot.url.appendingPathComponent(name)
            let status = try Self.statusNoFollow(child)
            let usage = try Self.persistentCacheUsage(child, status: status, budget: &budget)
            let addition = bytes.addingReportingOverflow(usage)
            guard !addition.overflow else { throw SwiftPodsError("Catalog cache size overflowed") }
            bytes = addition.partialValue
            guard Self.isPersistentRepositoryName(name), status.st_mode & S_IFMT == S_IFDIR else { continue }
            repositories += 1
            if name != preserving {
                candidates.append(.init(
                    url: child, bytes: usage,
                    modifiedSeconds: Int64(status.st_mtimespec.tv_sec),
                    modifiedNanoseconds: Int64(status.st_mtimespec.tv_nsec)))
            }
        }
        candidates.sort {
            ($0.modifiedSeconds, $0.modifiedNanoseconds, $0.url.lastPathComponent)
                < ($1.modifiedSeconds, $1.modifiedNanoseconds, $1.url.lastPathComponent)
        }
        for candidate in candidates
        where bytes > persistentCacheByteLimit || repositories > persistentRepositoryLimit {
            try Self.removeCacheItem(candidate.url, in: cacheRoot)
            bytes = max(0, bytes - candidate.bytes)
            repositories -= 1
        }
        try cacheRoot.verifyIdentity()
        guard bytes <= persistentCacheByteLimit, repositories <= persistentRepositoryLimit else {
            throw SwiftPodsError(
                "Catalog cache exceeds its persistent quota and has no safe evictable repository",
                hint: "Remove unknown cache files or the preserved catalog repository and retry")
        }
    }

    private static func persistentCacheUsage(
        _ root: URL, status rootStatus: stat, budget: inout PersistentScanBudget
    ) throws -> Int64 {
        try budget.consume(depth: 0)
        let rootType = rootStatus.st_mode & S_IFMT
        guard rootType == S_IFDIR || rootType == S_IFREG else {
            throw SwiftPodsError("Catalog cache contains a symbolic link or special file")
        }
        var bytes = try allocatedBytes(rootStatus)
        guard rootType == S_IFDIR else { return bytes }
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil, options: [],
            errorHandler: { _, error in enumerationError = error; return false })
        else { throw SwiftPodsError("Cannot inspect persistent catalog cache usage") }
        for case let item as URL in enumerator {
            try budget.consume(depth: enumerator.level)
            let status = try statusNoFollow(item)
            let type = status.st_mode & S_IFMT
            guard type == S_IFDIR || type == S_IFREG else {
                enumerator.skipDescendants()
                throw SwiftPodsError("Catalog cache contains a symbolic link or special file")
            }
            let addition = bytes.addingReportingOverflow(try allocatedBytes(status))
            guard !addition.overflow else { throw SwiftPodsError("Catalog cache size overflowed") }
            bytes = addition.partialValue
        }
        if let enumerationError {
            throw SwiftPodsError("Cannot inspect persistent catalog cache usage: \(enumerationError)")
        }
        return bytes
    }

    /// Streams the cache root through a retained descriptor. The returned array is intentionally capped: candidates
    /// are sorted for LRU eviction, but an attacker cannot first force an unbounded Foundation directory allocation.
    private static func cacheRootNames(in cacheRoot: PreparedCacheRoot) throws -> [String] {
        let duplicate = openat(
            cacheRoot.descriptor, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard duplicate >= 0, let stream = fdopendir(duplicate) else {
            if duplicate >= 0 { close(duplicate) }
            throw SwiftPodsError("Cannot enumerate catalog cache root")
        }
        defer { closedir(stream) }
        var result: [String] = []
        errno = 0
        while let entry = readdir(stream) {
            var bytes = entry.pointee.d_name
            let name = withUnsafeBytes(of: &bytes) { raw in
                String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
            }
            if name != "." && name != ".." {
                guard result.count < maximumCacheRootEntries else {
                    throw SwiftPodsError("Catalog cache root contains too many entries")
                }
                result.append(name)
            }
            errno = 0
        }
        guard errno == 0 else { throw SwiftPodsError("Cannot enumerate catalog cache root") }
        try cacheRoot.verifyIdentity()
        return result.sorted()
    }

    private static func allocatedBytes(_ status: stat) throws -> Int64 {
        let allocated = Int64(status.st_blocks).multipliedReportingOverflow(by: 512)
        guard status.st_size >= 0, status.st_blocks >= 0, !allocated.overflow else {
            throw SwiftPodsError("Catalog cache contains an oversized filesystem object")
        }
        return max(Int64(status.st_size), allocated.partialValue)
    }

    private static func statusNoFollow(_ url: URL) throws -> stat {
        var status = stat()
        guard url.path.withCString({ lstat($0, &status) }) == 0 else {
            throw SwiftPodsError("Catalog cache changed while its quota was checked")
        }
        return status
    }

    private static func isPersistentRepositoryName(_ name: String) -> Bool {
        name.range(
            of: #"^[A-Za-z0-9._-]{1,64}-[0-9a-f]{32}\.git$"#,
            options: .regularExpression) != nil
    }

    private static func isLegacyOriginLockName(_ name: String) -> Bool {
        name.range(of: #"^\.lock-[0-9a-f]{64}$"#, options: .regularExpression) != nil
    }

    private static func isCloneStagingName(_ name: String) -> Bool {
        name.range(
            of: #"^\.clone-[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\.git$"#,
            options: .regularExpression) != nil
    }

    private static func touch(_ repository: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: repository.path)
    }

    private func secureCacheRoot() throws -> PreparedCacheRoot {
        let requested = cache.standardized
        guard requested.path.hasPrefix("/"), requested.path != "/" else {
            throw SwiftPodsError("Catalog cache must use a non-root absolute path")
        }

        var existing = requested
        var components: [String] = []
        while true {
            var status = stat()
            if existing.path.withCString({ lstat($0, &status) }) == 0 { break }
            let problem = errno
            guard problem == ENOENT || problem == ENOTDIR else {
                throw SwiftPodsError("Cannot inspect catalog cache: \(String(cString: strerror(problem)))")
            }
            let component = existing.lastPathComponent
            guard !component.isEmpty, component != ".", component != "..", !component.contains("/") else {
                throw SwiftPodsError("Catalog cache contains an unsafe path component")
            }
            components.insert(component, at: 0)
            let parent = existing.deletingLastPathComponent()
            guard parent.path != existing.path else { throw SwiftPodsError("Cannot locate a catalog cache parent") }
            existing = parent
        }

        // Authenticate the configured spelling before resolving links, then create every missing suffix only through
        // the retained canonical-parent descriptor. This prevents a writable lexical ancestor from laundering itself
        // through a symlink into a trusted target or redirecting FileManager's recursive creation.
        try Self.validateLexicalCacheAncestors(existing)
        let canonicalParent = try Self.canonicalDirectoryURL(existing)
        try Self.validateCacheAncestors(canonicalParent)
        var currentURL = canonicalParent
        var descriptor = canonicalParent.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else {
            throw SwiftPodsError("Cannot safely open catalog cache parent: \(String(cString: strerror(errno)))")
        }
        defer { close(descriptor) }

        for component in components {
            let created: Bool
            if component.withCString({ mkdirat(descriptor, $0, 0o700) }) == 0 {
                created = true
            } else {
                let problem = errno
                guard problem == EEXIST else {
                    throw SwiftPodsError("Cannot create catalog cache: \(String(cString: strerror(problem)))")
                }
                created = false
            }
            let child = component.withCString {
                openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            }
            guard child >= 0 else {
                throw SwiftPodsError("Catalog cache path contains a replaced or unsafe directory")
            }
            close(descriptor)
            descriptor = child
            currentURL.appendPathComponent(component, isDirectory: true)
            if created {
                try Self.secureDescriptor(descriptor, mode: 0o700, kind: "Catalog cache directory")
            }
            try Self.validateCacheDescriptor(descriptor, path: currentURL.path)
        }

        var status = stat()
        try Self.validateCacheDescriptor(descriptor, path: currentURL.path)
        guard fstat(descriptor, &status) == 0 else { throw SwiftPodsError("Cannot inspect catalog cache") }
        // Existing caches created by older SwiftPods releases may be 0755. Tighten only a directory
        // already proven to be the owned, non-shared inode held by this descriptor; never chmod a
        // pathname that could be replaced between validation and mutation.
        if status.st_mode & 0o7777 != 0o700 {
            guard fchmod(descriptor, 0o700) == 0, fstat(descriptor, &status) == 0,
                status.st_mode & 0o7777 == 0o700
            else { throw SwiftPodsError("Cannot secure catalog cache permissions") }
        }
        var linked = stat()
        guard currentURL.path.withCString({ lstat($0, &linked) }) == 0,
            linked.st_mode & S_IFMT == S_IFDIR,
            linked.st_dev == status.st_dev, linked.st_ino == status.st_ino
        else {
            throw SwiftPodsError("Catalog cache changed while its permissions were checked")
        }
        try Self.validateCacheAncestors(currentURL)
        return try PreparedCacheRoot(url: currentURL, descriptor: descriptor)
    }

    private static func validateCacheDescriptor(_ descriptor: Int32, path: String) throws {
        var status = stat()
        guard fstat(descriptor, &status) == 0,
            status.st_mode & S_IFMT == S_IFDIR,
            status.st_uid == geteuid(),
            status.st_mode & 0o022 == 0,
            try !hasExtendedACL(descriptor, kind: "Catalog cache")
        else {
            throw SwiftPodsError(
                "Catalog cache must be an owned directory without group/other write access or an extended ACL: \(path)")
        }
    }

    private static func canonicalDirectoryURL(_ directory: URL) throws -> URL {
        guard let pointer = directory.path.withCString({ realpath($0, nil) }) else {
            throw SwiftPodsError("Cannot canonicalize catalog cache path")
        }
        defer { free(pointer) }
        return URL(fileURLWithPath: String(cString: pointer), isDirectory: true)
    }

    private static func validateCacheAncestors(_ cacheRoot: URL) throws {
        guard let pointer = cacheRoot.path.withCString({ realpath($0, nil) }) else {
            throw SwiftPodsError("Cannot canonicalize catalog cache ancestors")
        }
        defer { free(pointer) }
        let canonicalPath = String(cString: pointer)
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw SwiftPodsError("Cannot inspect catalog cache ancestors") }
        defer { close(descriptor) }

        try validateCacheAncestorDescriptor(descriptor, path: "/")
        var path = ""
        for component in (canonicalPath as NSString).pathComponents.dropFirst() {
            guard !component.isEmpty, component != ".", component != "..", !component.contains("/") else {
                throw SwiftPodsError("Catalog cache contains an unsafe ancestor component")
            }
            let next = component.withCString {
                openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            }
            guard next >= 0 else {
                throw SwiftPodsError(
                    "Cannot safely open catalog cache ancestor \(path)/\(component): \(String(cString: strerror(errno)))")
            }
            close(descriptor)
            descriptor = next
            path += "/" + component
            try validateCacheAncestorDescriptor(descriptor, path: path)
        }
    }

    private static func validateLexicalCacheAncestors(_ existing: URL) throws {
        try validateLexicalCacheAncestors(existing, symlinkDepth: 0)
    }

    private static func validateLexicalCacheAncestors(_ existing: URL, symlinkDepth: Int) throws {
        guard symlinkDepth <= 64 else { throw SwiftPodsError("Catalog cache path contains too many symbolic links") }
        let path = existing.standardized.path
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw SwiftPodsError("Cannot inspect catalog cache ancestors") }
        defer { close(descriptor) }

        try validateCacheAncestorDescriptor(descriptor, path: "/")
        var traversed = ""
        let components = Array((path as NSString).pathComponents.dropFirst())
        for (index, component) in components.enumerated() {
            guard !component.isEmpty, component != ".", component != "..", !component.contains("/") else {
                throw SwiftPodsError("Catalog cache contains an unsafe ancestor component")
            }
            var linked = stat()
            guard component.withCString({
                fstatat(descriptor, $0, &linked, AT_SYMLINK_NOFOLLOW)
            }) == 0 else {
                throw SwiftPodsError(
                    "Cannot safely inspect catalog cache ancestor \(traversed)/\(component): "
                        + String(cString: strerror(errno)))
            }
            let linkedPath = traversed + "/" + component
            if linked.st_mode & S_IFMT == S_IFLNK {
                guard linked.st_uid == 0 || linked.st_uid == geteuid() else {
                    throw SwiftPodsError(
                        "Catalog cache path contains a symbolic link owned by an untrusted account: \(linkedPath)")
                }
                var targetBuffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
                let length = component.withCString { componentPointer in
                    targetBuffer.withUnsafeMutableBufferPointer { buffer in
                        readlinkat(descriptor, componentPointer, buffer.baseAddress, buffer.count)
                    }
                }
                guard length > 0, length < targetBuffer.count,
                    let target = String(
                        bytes: targetBuffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, encoding: .utf8)
                else { throw SwiftPodsError("Cannot safely read catalog cache symbolic link: \(linkedPath)") }
                var rechecked = stat()
                guard component.withCString({
                    fstatat(descriptor, $0, &rechecked, AT_SYMLINK_NOFOLLOW)
                }) == 0, rechecked.st_mode & S_IFMT == S_IFLNK,
                    rechecked.st_dev == linked.st_dev, rechecked.st_ino == linked.st_ino
                else { throw SwiftPodsError("Catalog cache symbolic link changed while it was inspected") }

                let parentPath = traversed.isEmpty ? "/" : traversed
                var redirected = target.hasPrefix("/")
                    ? target : (parentPath as NSString).appendingPathComponent(target)
                for remainder in components.dropFirst(index + 1) {
                    redirected = (redirected as NSString).appendingPathComponent(remainder)
                }
                redirected = URL(fileURLWithPath: redirected, isDirectory: true).standardized.path
                guard redirected.hasPrefix("/") else {
                    throw SwiftPodsError("Catalog cache symbolic link has an unsafe target")
                }
                try validateLexicalCacheAncestors(
                    URL(fileURLWithPath: redirected, isDirectory: true), symlinkDepth: symlinkDepth + 1)
                return
            }
            guard linked.st_mode & S_IFMT == S_IFDIR else {
                throw SwiftPodsError("Catalog cache ancestor is not a directory: \(linkedPath)")
            }
            let next = component.withCString {
                openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            }
            guard next >= 0 else {
                throw SwiftPodsError(
                    "Cannot safely open catalog cache ancestor \(linkedPath): \(String(cString: strerror(errno)))")
            }
            var opened = stat()
            guard fstat(next, &opened) == 0, opened.st_mode & S_IFMT == S_IFDIR,
                opened.st_dev == linked.st_dev, opened.st_ino == linked.st_ino
            else {
                close(next)
                throw SwiftPodsError("Catalog cache ancestor changed while it was opened: \(linkedPath)")
            }
            close(descriptor)
            descriptor = next
            traversed = linkedPath
            try validateCacheAncestorDescriptor(descriptor, path: traversed)
        }
    }

    private static func validateCacheAncestorDescriptor(_ descriptor: Int32, path: String) throws {
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFDIR else {
            throw SwiftPodsError("Cannot inspect catalog cache ancestor: \(path)")
        }
        guard status.st_uid == 0 || status.st_uid == geteuid() else {
            throw SwiftPodsError("Catalog cache is below a directory owned by an untrusted account: \(path)")
        }
        guard try !descriptorHasAllowACL(descriptor) else {
            throw SwiftPodsError("Catalog cache ancestor grants access through an extended ACL: \(path)")
        }
        let writableByOthers = status.st_mode & 0o022 != 0
        let trustedSticky = status.st_mode & mode_t(S_ISVTX) != 0
            && (status.st_uid == 0 || status.st_uid == geteuid())
        guard !writableByOthers || trustedSticky else {
            throw SwiftPodsError(
                "Catalog cache is below a group- or world-writable non-sticky directory: \(path)")
        }
    }

    private static func descriptorHasAllowACL(_ descriptor: Int32) throws -> Bool {
        errno = 0
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            if errno == ENOENT || errno == ENOTSUP || errno == EOPNOTSUPP { return false }
            throw SwiftPodsError("Cannot inspect catalog cache ancestor access controls")
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var selector = Int32(ACL_FIRST_ENTRY.rawValue)
        var readEntry = false
        while true {
            var entry: acl_entry_t?
            errno = 0
            let result = acl_get_entry(acl, selector, &entry)
            let failure = errno
            if result != 0, readEntry, selector == Int32(ACL_NEXT_ENTRY.rawValue), failure == EINVAL {
                return false
            }
            guard result == 0 else {
                throw SwiftPodsError("Cannot inspect catalog cache ancestor access controls")
            }
            guard let entry else { return false }
            readEntry = true
            var tag = ACL_UNDEFINED_TAG
            guard acl_get_tag_type(entry, &tag) == 0 else {
                throw SwiftPodsError("Cannot inspect catalog cache ancestor access controls")
            }
            if tag == ACL_EXTENDED_ALLOW { return true }
            selector = Int32(ACL_NEXT_ENTRY.rawValue)
        }
    }

    private static func requireCacheDescendant(_ item: URL, in cacheRoot: PreparedCacheRoot) throws {
        let root = cacheRoot.url.standardized.path
        let candidate = item.standardized.path
        guard candidate.count > root.count, candidate.hasPrefix(root + "/") else {
            throw SwiftPodsError("Refusing a catalog cache mutation outside its authenticated root")
        }
    }

    private static func removeCacheItem(_ item: URL, in cacheRoot: PreparedCacheRoot) throws {
        try requireCacheDescendant(item, in: cacheRoot)
        try cacheRoot.verifyIdentity()
        do {
            try FileManager.default.removeItem(at: item)
            try cacheRoot.verifyIdentity()
        } catch {
            try cacheRoot.verifyIdentity()
            throw error
        }
    }

    private static func moveCacheItem(
        from source: URL, to destination: URL, in cacheRoot: PreparedCacheRoot
    ) throws {
        try requireCacheDescendant(source, in: cacheRoot)
        try requireCacheDescendant(destination, in: cacheRoot)
        try cacheRoot.verifyIdentity()
        do {
            try FileManager.default.moveItem(at: source, to: destination)
            try cacheRoot.verifyIdentity()
        } catch {
            try cacheRoot.verifyIdentity()
            throw error
        }
    }

    private static func secureDescriptor(_ descriptor: Int32, mode: mode_t, kind: String) throws {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw SwiftPodsError("Cannot inspect \(kind.lowercased()) permissions")
        }
        // Do not issue metadata writes when the inode is already secure. In particular, another process may have
        // this lock inode open while its owner is in the critical section; a no-op chmod/ACL rewrite would change
        // ctime and make an otherwise legitimate waiter indistinguishable from an in-place attacker.
        if status.st_mode & 0o7777 != mode, fchmod(descriptor, mode) != 0 {
            throw SwiftPodsError("Cannot secure \(kind.lowercased()) permissions")
        }
        guard try hasExtendedACL(descriptor, kind: kind) else { return }
        guard let emptyACL = acl_init(0) else {
            throw SwiftPodsError("Cannot allocate an empty access-control list for \(kind.lowercased())")
        }
        errno = 0
        let result = acl_set_fd_np(descriptor, emptyACL, ACL_TYPE_EXTENDED)
        let failure = errno
        acl_free(UnsafeMutableRawPointer(emptyACL))
        if result != 0, failure != ENOTSUP, failure != EOPNOTSUPP {
            throw SwiftPodsError("Cannot remove inherited access controls from \(kind.lowercased())")
        }
    }

    private static func hasExtendedACL(_ descriptor: Int32, kind: String) throws -> Bool {
        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = attrgroup_t(ATTR_CMN_EXTENDED_SECURITY)
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        let capacity = buffer.count
        errno = 0
        let result = buffer.withUnsafeMutableBytes {
            fgetattrlist(descriptor, &attributes, $0.baseAddress, capacity, 0)
        }
        guard result == 0 else {
            let failure = errno
            if failure == ENOTSUP || failure == EOPNOTSUPP { return false }
            throw SwiftPodsError("Cannot inspect access controls on \(kind.lowercased()): \(String(cString: strerror(failure)))")
        }
        let fields = buffer.withUnsafeBytes { bytes -> (UInt32, Int32, UInt32) in
            (bytes.loadUnaligned(as: UInt32.self),
             bytes.loadUnaligned(fromByteOffset: 4, as: Int32.self),
             bytes.loadUnaligned(fromByteOffset: 8, as: UInt32.self))
        }
        let returned = Int(fields.0)
        let dataOffset = Int(fields.1)
        let securityLength = Int(fields.2)
        guard returned >= 12, returned <= buffer.count, dataOffset >= 8,
            dataOffset <= returned - 4, securityLength <= returned - 4 - dataOffset
        else {
            throw SwiftPodsError("Access controls on \(kind.lowercased()) have an invalid kernel representation")
        }
        if securityLength == 0 { return false }
        let dataStart = 4 + dataOffset
        guard securityLength >= 44 else {
            throw SwiftPodsError("Access controls on \(kind.lowercased()) have an invalid kernel representation")
        }
        let security = buffer.withUnsafeBytes { bytes -> (UInt32, UInt32) in
            (bytes.loadUnaligned(fromByteOffset: dataStart, as: UInt32.self),
             bytes.loadUnaligned(fromByteOffset: dataStart + 36, as: UInt32.self))
        }
        guard security.0 == 0x012c_c16d else {
            throw SwiftPodsError("Access controls on \(kind.lowercased()) have an invalid kernel representation")
        }
        return security.1 != 0 && security.1 != UInt32.max
    }

    private func verify(_ prepared: Prepared, in cacheRoot: PreparedCacheRoot) throws {
        try cacheRoot.verifyIdentity()
        guard Self.directoryIdentity(prepared.repository) == prepared.identity else {
            throw SwiftPodsError("Catalog repository changed while it was in use")
        }
    }

    private func cacheGit(
        _ arguments: [String], maximumFileBytes: Int64? = nil,
        networkPolicy: GitNetworkPolicy? = nil, cacheRoot: PreparedCacheRoot
    ) throws -> String {
        try cacheRoot.verifyIdentity()
        let result = try git(
            arguments, maximumFileBytes: maximumFileBytes, networkPolicy: networkPolicy)
        try cacheRoot.verifyIdentity()
        return result
    }

    private func cacheGitData(
        _ arguments: [String], maximumOutputBytes: Int, cacheRoot: PreparedCacheRoot
    ) throws -> Data {
        try cacheRoot.verifyIdentity()
        let result = try gitData(arguments, maximumOutputBytes: maximumOutputBytes)
        try cacheRoot.verifyIdentity()
        return result
    }

    private func validate(
        repository: URL, source: String, desired: String?, cacheRoot: PreparedCacheRoot
    ) throws -> String {
        try cacheRoot.verifyIdentity()
        guard Self.isDirectory(repository) else { throw SwiftPodsError("Catalog cache is not a regular directory") }
        for relative in ["objects/info/alternates", "objects/info/http-alternates", "info/grafts"] {
            let path = repository.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: path.path)
                || (try? FileManager.default.destinationOfSymbolicLink(atPath: path.path)) != nil
            {
                throw SwiftPodsError("Catalog cache contains unsupported object indirection at \(relative)")
            }
        }
        let replacements = try cacheGit(
            ["-C", repository.path, "for-each-ref", "--format=%(refname)", "refs/replace"],
            cacheRoot: cacheRoot)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard replacements.isEmpty else { throw SwiftPodsError("Catalog cache contains Git replacement objects") }
        let origins = try cacheGit(
            ["-C", repository.path, "remote", "get-url", "--all", "origin"], cacheRoot: cacheRoot)
            .split(whereSeparator: \.isNewline).map(String.init)
        guard origins == [source] else {
            throw SwiftPodsError("Catalog cache origin is \(origins.joined(separator: ", ")), expected \(source)")
        }
        let revision = try self.revision(
            in: repository, expression: (desired ?? "HEAD") + "^{commit}", cacheRoot: cacheRoot)
        guard Self.isFullObjectID(revision), desired == nil || revision == desired else {
            throw SwiftPodsError("Catalog cache has commit \(revision), expected \(desired ?? "a full object ID")")
        }
        _ = try cacheGit(
            ["-C", repository.path, "fsck", "--strict", "--no-dangling", revision], cacheRoot: cacheRoot)
        try cacheRoot.verifyIdentity()
        return revision
    }

    private func revision(
        in repository: URL, expression: String, cacheRoot: PreparedCacheRoot
    ) throws -> String {
        try cacheGit(
            ["-C", repository.path, "rev-parse", "--verify", expression], cacheRoot: cacheRoot)
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Harden Git while retaining the system Keychain helper for private repositories on public HTTPS hosts.
    /// No checkout is ever made.
    private func git(
        _ arguments: [String], maximumFileBytes: Int64? = nil,
        networkPolicy: GitNetworkPolicy? = nil
    ) throws -> String {
        let hardenedArguments = gitArguments(arguments, networkPolicy: networkPolicy)
        let executable: String
        let launchedArguments: [String]
        if let maximumFileBytes {
            // A fetch normally receives one pack. Force Git to retain it as a pack and impose a kernel file-size
            // limit before exec, so an untrusted remote cannot fill the disk before the aggregate post-fetch scan.
            // The script is constant; the decimal limit and every Git/user value stay in positional argv.
            let kibibytes = max(1, (maximumFileBytes + 1_023) / 1_024)
            executable = "/bin/sh"
            launchedArguments = [
                "-c", "ulimit -f \"$1\" || exit 125; shift; exec \"$@\"",
                "swiftpods-git-budget", String(kibibytes),
            ] + gitExecutableArguments(hardenedArguments)
        } else {
            executable = "/usr/bin/env"
            launchedArguments = isolatedGitEnvironment + ["/usr/bin/git"] + hardenedArguments
        }
        let data: Data
        do {
            data = try runner.runData(
                executable, launchedArguments, in: Self.gitWorkingDirectory, timeout: 30 * 60,
                maximumOutputBytes: Self.maximumGitOutputBytes)
        } catch {
            if maximumFileBytes != nil,
                case .exitStatus(128 + SIGXFSZ) = (error as? SwiftPodsError)?.commandFailure?.reason
            {
                throw SwiftPodsError("Catalog fetch exceeded its runtime file-size budget")
            }
            if maximumFileBytes != nil {
                throw SwiftPodsError("Catalog fetch failed while its runtime file-size budget was enforced: \(error)")
            }
            throw error
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw SwiftPodsError("Git returned non-UTF-8 output while reading a catalog")
        }
        return text
    }

    private func gitData(_ arguments: [String], maximumOutputBytes: Int) throws -> Data {
        try runner.runData(
            "/usr/bin/env", isolatedGitEnvironment + ["/usr/bin/git"] + gitArguments(arguments),
            in: Self.gitWorkingDirectory, timeout: 60,
            maximumOutputBytes: maximumOutputBytes)
    }

    private static let gitWorkingDirectory = URL(fileURLWithPath: "/", isDirectory: true)

    private var isolatedGitEnvironment: [String] {
        [
            "PATH=/usr/bin:/bin:/usr/sbin:/sbin",
            "GIT_CONFIG_NOSYSTEM=1",
            "GIT_CONFIG_GLOBAL=/dev/null",
        ]
    }

    private func gitExecutableArguments(_ hardenedArguments: [String]) -> [String] {
        ["/usr/bin/env"] + isolatedGitEnvironment + ["/usr/bin/git"] + hardenedArguments
    }

    private func gitArguments(
        _ arguments: [String], networkPolicy: GitNetworkPolicy? = nil
    ) -> [String] {
        var result = [
            "--no-replace-objects",
            "-c", "core.hooksPath=/dev/null",
            "-c", "core.sshCommand=\(Self.isolatedSSHCommand)",
            "-c", "protocol.ext.allow=never",
            "-c", "protocol.file.allow=user",
            "-c", "credential.interactive=never",
            "-c", "credential.helper=",
            "-c", "credential.helper=osxkeychain",
            "-c", "http.sslVerify=true",
            "-c", "http.followRedirects=false",
            "-c", "http.proxy=",
            "-c", "http.extraHeader=",
            "-c", "http.curloptResolve=",
            "-c", "fetch.unpackLimit=1",
            "-c", "fetch.fsckObjects=true",
            "-c", "transfer.fsckObjects=true",
            "-c", "submodule.recurse=false",
        ]
        if let networkPolicy { result += networkPolicy.configuration }
        return result + arguments
    }

    private static let isolatedSSHCommand = [
        "/usr/bin/ssh", "-F", "/dev/null", "-oBatchMode=yes",
        "-oStrictHostKeyChecking=yes", "-oCheckHostIP=no", "-oClearAllForwardings=yes",
        "-oForwardAgent=no", "-oProxyCommand=none", "-oProxyJump=none",
        "-oCanonicalizeHostname=no", "-oPermitLocalCommand=no", "-oRequestTTY=no",
        "-oUpdateHostKeys=no", "-oVerifyHostKeyDNS=no",
    ].joined(separator: " ")

    private func gitNetworkPolicy(for source: String) throws -> GitNetworkPolicy? {
        guard let endpoint = PackageLocation.remoteEndpoint(source) else { return nil }
        if endpoint.transport == .https { try requirePinnedHTTPResolutionSupport() }
        let addresses = try publicAddresses(for: endpoint)
        return try Self.makeGitNetworkPolicy(endpoint: endpoint, addresses: addresses)
    }

    /// Kept internal so security regressions can verify the exact transport
    /// policy without opening a network connection.
    static func makeGitNetworkPolicy(
        endpoint: PackageLocation.RemoteEndpoint, addresses: [String]
    ) throws -> GitNetworkPolicy {
        guard !addresses.isEmpty, addresses.count <= maximumResolvedAddresses,
            addresses.allSatisfy({ address in
                !address.isEmpty && address.unicodeScalars.allSatisfy {
                    $0.isASCII && CharacterSet(charactersIn: "0123456789abcdefABCDEF:.").contains($0)
                }
            })
        else { throw SwiftPodsError("Catalog remote host returned an invalid address set") }

        switch endpoint.transport {
        case .https:
            let host = endpoint.host.contains(":") ? "[\(endpoint.host)]" : endpoint.host
            let pinned = addresses.map { $0.contains(":") ? "[\($0)]" : $0 }.joined(separator: ",")
            return GitNetworkPolicy(configuration: [
                "-c", "http.curloptResolve=\(host):\(endpoint.port):\(pinned)",
                "-c", "http.followRedirects=false",
                "-c", "http.sslVerify=true",
                "-c", "http.proxy=",
            ])
        case .ssh:
            let address = addresses[0]
            let alias = endpoint.port == 22 ? endpoint.host : "[\(endpoint.host)]:\(endpoint.port)"
            let command = isolatedSSHCommand
                + " '-oHostname=\(address)' '-oHostKeyAlias=\(alias)'"
            return GitNetworkPolicy(configuration: ["-c", "core.sshCommand=\(command)"])
        }
    }

    private func requirePinnedHTTPResolutionSupport() throws {
        let data = try gitData(["help", "--config"], maximumOutputBytes: 4 * 1_024 * 1_024)
        guard String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
            .contains("http.curloptResolve")
        else {
            throw SwiftPodsError(
                "The installed Git cannot pin HTTPS catalog DNS resolution",
                hint: "Install a Git version that supports http.curloptResolve, or use an absolute local catalog mirror")
        }
    }

    private func publicAddresses(
        for endpoint: PackageLocation.RemoteEndpoint
    ) throws -> [String] {
        do {
            // Use the exact snapshot classified by the shared bounded resolver. These are the same bytes forced into
            // curl or SSH below, so a later DNS change cannot redirect the connection.
            return try BinaryNetworkPolicy.publicAddressStrings(
                host: endpoint.host, port: endpoint.port, timeout: Self.dnsTimeout)
        } catch {
            throw Self.nonPublicCatalogHostError()
        }
    }

    private static func nonPublicCatalogHostError() -> SwiftPodsError {
        SwiftPodsError(
            "Catalog remote host must resolve only to public IP addresses",
            hint: "For an internal Git server, mirror the catalog to an absolute local path or local file URL")
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func originKey(_ url: String) -> String { sha256(Data(url.utf8)) }

    private static func catalogNameKey(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased().precomposedStringWithCanonicalMapping
    }

    private static func isFullObjectID(_ text: String) -> Bool {
        (text.count == 40 || text.count == 64) && text.allSatisfy { $0.isASCII && ($0.isNumber || "abcdef".contains($0)) }
    }

    private static func isSafeTreePath(_ path: String) -> Bool {
        guard !path.isEmpty, path.utf8.count <= maximumTreePathBytes, !path.contains("\\"),
            !path.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0)
            })
        else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return components.count <= maximumTreePathDepth && components.allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 4_096
        }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        directoryIdentity(url) != nil
    }

    private static func directoryIdentity(_ url: URL) -> DirectoryIdentity? {
        var status = stat()
        guard url.path.withCString({ lstat($0, &status) }) == 0, status.st_mode & S_IFMT == S_IFDIR else {
            return nil
        }
        return DirectoryIdentity(device: UInt64(status.st_dev), inode: UInt64(status.st_ino))
    }
}
