import CryptoKit
import Darwin
import Foundation
import SwiftPodsManifest

/// Reproducible provenance for catalog-backed declarations.
///
/// Explicit package and binary declarations do not need this file. A catalog lookup records the exact Git commit
/// and SHA-256 of every raw catalog entry that contributed metadata to the evaluated Podfile.
struct SwiftPodsLock: Sendable, Codable, Equatable {
    static let fileName = "SwiftPods.lock"
    static let schemaVersion = 1
    private static let maximumBytes = 16 * 1_024 * 1_024
    private static let maximumCatalogs = 32
    private static let maximumEntries = 256

    /// The exact directory entry observed when resolution began. Install uses it as a compare-and-swap token so a
    /// concurrently edited lock is never silently replaced after project integration has finished.
    struct FileState: Sendable, Equatable {
        fileprivate struct Parent: Sendable, Equatable {
            let device: UInt64
            let inode: UInt64
            let mode: UInt32
            let owner: UInt32
            let group: UInt32

            init(_ status: stat) {
                device = UInt64(status.st_dev)
                inode = UInt64(status.st_ino)
                mode = UInt32(status.st_mode)
                owner = status.st_uid
                group = status.st_gid
            }
        }

        fileprivate struct Entry: Sendable, Equatable {
            let device: UInt64
            let inode: UInt64
            let mode: UInt32
            let links: UInt64
            let owner: UInt32
            let group: UInt32
            let size: Int64
            let modifiedSeconds: Int64
            let modifiedNanoseconds: Int64
            let changedSeconds: Int64
            let changedNanoseconds: Int64

            init(_ status: stat) {
                device = UInt64(status.st_dev)
                inode = UInt64(status.st_ino)
                mode = UInt32(status.st_mode)
                links = UInt64(status.st_nlink)
                owner = status.st_uid
                group = status.st_gid
                size = status.st_size
                modifiedSeconds = Int64(status.st_mtimespec.tv_sec)
                modifiedNanoseconds = Int64(status.st_mtimespec.tv_nsec)
                changedSeconds = Int64(status.st_ctimespec.tv_sec)
                changedNanoseconds = Int64(status.st_ctimespec.tv_nsec)
            }

            func isSameObject(as other: Self) -> Bool {
                device == other.device && inode == other.inode && mode == other.mode && links == other.links
                    && owner == other.owner && group == other.group && size == other.size
            }
        }

        fileprivate let parent: Parent
        fileprivate let entry: Entry?
        fileprivate let sha256: String?
    }

    /// Does not touch the lock pathname until the first catalog lookup. An irrelevant stale FIFO, symlink, directory,
    /// or oversized file therefore cannot break a Podfile made entirely of explicit sources. Once loaded, the exact
    /// bytes and state are retained as the compare-and-swap token for an eventual write.
    final class DeferredRead: @unchecked Sendable {
        private let file: URL
        private let mutex = NSLock()
        private var raw: RawFile?
        private var decoded: SwiftPodsLock??

        fileprivate init(file: URL) {
            self.file = file
        }

        func lock() throws -> SwiftPodsLock? {
            mutex.lock()
            defer { mutex.unlock() }
            if let decoded { return decoded }
            let raw = try rawLocked()
            let value = try raw.data.map { try SwiftPodsLock(data: $0, file: file) }
            decoded = value
            return value
        }

        /// Loads a bounded regular file without interpreting its JSON. `--update-sources` deliberately ignores the
        /// old semantic lock, but still needs an exact CAS token before it may replace that pathname.
        func replacementState() throws -> FileState {
            mutex.lock()
            defer { mutex.unlock() }
            return try rawLocked().state
        }

        /// Exact bytes retained for deployment freshness checks. A caller must not re-encode the decoded model:
        /// whitespace and key ordering are part of the local file that the generated build phase authenticates.
        func contents() throws -> Data? {
            mutex.lock()
            defer { mutex.unlock() }
            return try rawLocked().data
        }

        private func rawLocked() throws -> RawFile {
            if let raw { return raw }
            // Do not even inspect an irrelevant lock pathname. Explicit-only Podfiles never invoke their catalog
            // provider, so a stale FIFO, symlink, directory, or oversized file beside them remains completely inert.
            // Catalog-backed operations take the initial pathname token immediately before their first catalog I/O.
            let observed = try SwiftPodsLock.observedFile(at: file)
            let current: RawFile
            do {
                current = try SwiftPodsLock.rawFile(at: file)
            } catch let error as SwiftPodsError {
                throw error
            } catch {
                throw SwiftPodsError(
                    "Cannot read SwiftPods.lock", file: file.path,
                    hint: "Restore a valid lock, or remove it and run `swiftpods install`: \(error)")
            }
            guard current.state.parent == observed.parent, current.state.entry == observed.entry else {
                throw SwiftPodsLock.changedBeforeUseError(file)
            }
            raw = current
            return current
        }
    }

    struct Entry: Sendable, Codable, Equatable {
        let name: String
        let sha256: String

        init(name: String, sha256: String) {
            self.name = name
            self.sha256 = sha256
        }
    }

    struct Catalog: Sendable, Codable, Equatable {
        let url: String
        let revision: String
        let entries: [Entry]

        init(url: String, revision: String, entries: [Entry]) {
            self.url = url
            self.revision = revision
            self.entries = entries.sorted { ($0.name.lowercased(), $0.name) < ($1.name.lowercased(), $1.name) }
        }
    }

    let version: Int
    let catalogs: [Catalog]

    var isEmpty: Bool { catalogs.isEmpty }

    init(resolutions: [GitCatalog.Resolution]) {
        self.init(
            version: Self.schemaVersion,
            catalogs: resolutions.map { Catalog(url: $0.url, revision: $0.revision, entries: $0.entries) })
    }

    init(contentsOf file: URL) throws {
        let result = try Self.read(at: file)
        guard let lock = result.lock else {
            throw SwiftPodsError(
                "Cannot read SwiftPods.lock", file: file.path,
                hint: "Restore a valid lock, or remove it and run `swiftpods install`")
        }
        self = lock
    }

    static func deferredRead(at file: URL) throws -> DeferredRead {
        DeferredRead(file: file)
    }

    private init(data: Data, file: URL) throws {
        do {
            try StrictJSONKeyValidator.validate(data)
        } catch StrictJSONKeyValidator.Failure.duplicateKey {
            throw SwiftPodsError("SwiftPods.lock contains duplicate JSON object keys", file: file.path)
        } catch {
            throw SwiftPodsError("SwiftPods.lock is not valid JSON", file: file.path, hint: "Regenerate it with `swiftpods install`")
        }
        try Self.validateJSONSchema(data, file: file.path)
        do {
            self = try JSONDecoder().decode(Self.self, from: data)
        } catch {
            throw SwiftPodsError("SwiftPods.lock is not valid JSON", file: file.path, hint: "Regenerate it with `swiftpods install`: \(error)")
        }
        try validate(file: file.path)
    }

    private init(version: Int, catalogs: [Catalog]) {
        self.version = version
        self.catalogs = catalogs.sorted { Data($0.url.utf8).lexicographicallyPrecedes(Data($1.url.utf8)) }
    }

    func catalog(url: String) -> Catalog? { catalogs.first { $0.url.utf8.elementsEqual(url.utf8) } }

    func data() throws -> Data {
        try validate(file: Self.fileName)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(self)
        data.append(0x0A)
        return data
    }

    func write(to file: URL) throws {
        let state = try Self.rawFile(at: file).state
        try write(to: file, replacing: state)
    }

    func write(
        to file: URL, replacing expected: FileState,
        _temporaryName suppliedTemporaryName: String? = nil,
        _cleanupDirectoryName: String? = nil,
        _beforeTemporaryInstall: (() throws -> Void)? = nil,
        _beforeReplacementSwap: (() throws -> Void)? = nil,
        _beforeFinalPathCheck: (() throws -> Void)? = nil,
        _beforeCleanup: (() throws -> Void)? = nil
    ) throws {
        let contents = try data()
        let parentURL = file.deletingLastPathComponent()
        let name = try Self.safeName(of: file)
        let parent = parentURL.path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NONBLOCK) }
        guard parent >= 0 else { throw Self.writeError(file, "cannot open its parent directory") }
        defer { close(parent) }
        guard try Self.parentIdentity(parent) == expected.parent else {
            throw Self.changedError(file)
        }

        let temporaryName = suppliedTemporaryName ?? ".\(name).tmp-\(UUID().uuidString)"
        guard Self.isLockTemporaryName(temporaryName, lockName: name) else {
            throw Self.writeError(file, "received an unsafe transaction temporary name")
        }
        let output = temporaryName.withCString {
            openat(parent, $0, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o644)
        }
        guard output >= 0 else { throw Self.writeError(file, "cannot create a private temporary file") }
        var removeTemporary = true
        defer {
            close(output)
            if removeTemporary { _ = temporaryName.withCString { unlinkat(parent, $0, 0) } }
        }
        try Self.write(contents, to: output, file: file)
        guard fsync(output) == 0 else { throw Self.writeError(file, "cannot synchronize its temporary file") }
        let installedDigest = SHA256.hash(data: contents).map { String(format: "%02x", $0) }.joined()
        try _beforeTemporaryInstall?()
        let verifiedTemporary = try Self.digest(
            descriptor: output, file: file, description: "temporary source")
        guard verifiedTemporary.sha256 == installedDigest else {
            throw Self.writeError(file, "temporary source bytes changed before installation")
        }
        guard try Self.entryIdentity(name, in: parent) == expected.entry else { throw Self.changedError(file) }
        var linkedTemporaryStatus = stat()
        guard temporaryName.withCString({
                fstatat(parent, $0, &linkedTemporaryStatus, AT_SYMLINK_NOFOLLOW)
            }) == 0,
            verifiedTemporary.entry == FileState.Entry(linkedTemporaryStatus)
        else { throw Self.writeError(file, "temporary source changed before installation") }

        var installedState: FileState?
        var displacedState: FileState?
        var replacementInstalled = false

        func rollbackReplacement() throws {
            guard replacementInstalled else { return }
            guard let installedState else {
                removeTemporary = false
                throw Self.writeError(file, "cannot authenticate the installed lock for rollback; recovery data was preserved")
            }
            guard try Self.linkedEntryMatchesExactly(
                name, in: parent, expected: installedState, file: file)
            else {
                removeTemporary = false
                throw Self.writeError(file, "changed after replacement; the concurrent lock and recovery data were preserved")
            }
            if expected.entry == nil {
                let moved = name.withCString { source in
                    temporaryName.withCString { destination in
                        renameatx_np(parent, source, parent, destination, UInt32(RENAME_EXCL))
                    }
                }
                guard moved == 0, try Self.movedEntryMatches(temporaryName, in: parent, expected: installedState) else {
                    removeTemporary = false
                    throw Self.writeError(file, "could not roll back the newly created lock")
                }
                replacementInstalled = false
                removeTemporary = false
                try _beforeCleanup?()
                try Self.quarantineAndRemove(
                    temporaryName, in: parent, expected: installedState, file: file,
                    cleanupDirectoryName: _cleanupDirectoryName)
            } else {
                guard let displacedState,
                    try Self.linkedEntryMatchesExactly(
                        temporaryName, in: parent, expected: displacedState, file: file)
                else {
                    removeTemporary = false
                    throw Self.writeError(file, "changed after replacement; recovery data was preserved")
                }
                let swapped = temporaryName.withCString { source in
                    name.withCString { destination in
                        renameatx_np(parent, source, parent, destination, UInt32(RENAME_SWAP))
                    }
                }
                guard swapped == 0,
                    try Self.movedEntryMatches(name, in: parent, expected: displacedState),
                    try Self.movedEntryMatches(temporaryName, in: parent, expected: installedState)
                else {
                    removeTemporary = false
                    throw Self.writeError(file, "could not roll back the replaced lock; recovery data was preserved")
                }
                replacementInstalled = false
                removeTemporary = false
                try _beforeCleanup?()
                try Self.quarantineAndRemove(
                    temporaryName, in: parent, expected: installedState, file: file,
                    cleanupDirectoryName: _cleanupDirectoryName)
            }
            _ = fsync(parent)
        }

        do {
            let result: Int32
            if expected.entry == nil {
                result = temporaryName.withCString { source in
                    name.withCString { destination in
                        renameatx_np(parent, source, parent, destination, UInt32(RENAME_EXCL))
                    }
                }
            } else {
                try _beforeReplacementSwap?()
                result = temporaryName.withCString { source in
                    name.withCString { destination in
                        renameatx_np(parent, source, parent, destination, UInt32(RENAME_SWAP))
                    }
                }
            }
            guard result == 0 else { throw Self.changedError(file) }
            replacementInstalled = true
            // After a successful swap this pathname contains the displaced lock, not our temporary file. From this
            // point onward it may only be removed through an authenticated rollback/cleanup path.
            removeTemporary = false
            var installedStatus = stat()
            guard fstat(output, &installedStatus) == 0 else {
                throw Self.writeError(file, "cannot verify its installed temporary file")
            }
            let currentInstalledState = FileState(
                parent: expected.parent, entry: FileState.Entry(installedStatus), sha256: installedDigest)
            installedState = currentInstalledState
            guard try Self.linkedEntryMatchesExactly(
                name, in: parent, expected: currentInstalledState, file: file)
            else {
                throw Self.writeError(file, "installed file changed immediately after replacement")
            }
            if expected.entry != nil {
                let currentDisplacedState = try Self.captureMovedEntry(
                    temporaryName, in: parent, parent: expected.parent, file: file)
                displacedState = currentDisplacedState
                guard Self.representsSameFile(currentDisplacedState, as: expected) else {
                    throw Self.changedError(file)
                }
            }
            guard fsync(parent) == 0 else { throw Self.writeError(file, "cannot synchronize its parent directory") }
            try _beforeFinalPathCheck?()
            let verifiedInstalled = try Self.digest(
                descriptor: output, file: file, description: "installed file")
            guard verifiedInstalled.entry == currentInstalledState.entry,
                verifiedInstalled.sha256 == installedDigest
            else {
                throw Self.writeError(file, "installed bytes changed before final validation")
            }
            let current: (parent: FileState.Parent, entry: FileState.Entry?)
            do { current = try Self.pathIdentity(parentURL: parentURL, name: name) } catch {
                throw Self.changedError(file)
            }
            guard current.parent == expected.parent, current.entry == currentInstalledState.entry else {
                throw Self.changedError(file)
            }

            if expected.entry != nil {
                // All fallible validation and the durability barrier completed while the old inode was still available
                // for rollback. Move it into an owner-private quarantine and recheck its token before unlinking.
                try _beforeCleanup?()
                removeTemporary = false
                guard let displacedState else {
                    throw Self.writeError(file, "lost the displaced lock recovery token")
                }
                try Self.quarantineAndRemove(
                    temporaryName, in: parent, expected: displacedState, file: file,
                    cleanupDirectoryName: _cleanupDirectoryName)
            }
            replacementInstalled = false
            removeTemporary = false
        } catch {
            if replacementInstalled {
                do { try rollbackReplacement() } catch let rollbackError {
                    throw Self.writeError(file, "\(error); rollback failed: \(rollbackError)")
                }
            }
            throw error
        }
    }

    private static func isLockTemporaryName(_ name: String, lockName: String) -> Bool {
        let prefix = ".\(lockName).tmp-"
        guard name.hasPrefix(prefix), name.count == prefix.count + 36 else { return false }
        return UUID(uuidString: String(name.dropFirst(prefix.count))) != nil
    }

    static func remove(
        at file: URL, replacing expected: FileState,
        _beforeFinalPathCheck: (() throws -> Void)? = nil,
        _beforeCleanup: (() throws -> Void)? = nil
    ) throws {
        guard expected.entry != nil else { return }
        let parentURL = file.deletingLastPathComponent()
        let name = try safeName(of: file)
        let parent = parentURL.path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NONBLOCK) }
        guard parent >= 0 else { throw writeError(file, "cannot open its parent directory") }
        defer { close(parent) }
        guard try parentIdentity(parent) == expected.parent,
            try entryIdentity(name, in: parent) == expected.entry
        else { throw changedError(file) }

        let temporaryName = ".\(name).removed-\(UUID().uuidString)"
        let moved = name.withCString { source in
            temporaryName.withCString { destination in
                renameatx_np(parent, source, parent, destination, UInt32(RENAME_EXCL))
            }
        }
        guard moved == 0 else { throw changedError(file) }
        guard try movedEntryMatches(temporaryName, in: parent, expected: expected) else {
            let rollback = temporaryName.withCString { source in
                name.withCString { destination in
                    renameatx_np(parent, source, parent, destination, UInt32(RENAME_EXCL))
                }
            }
            if rollback != 0 {
                throw writeError(file, "changed during removal and was preserved as \(temporaryName)")
            }
            throw changedError(file)
        }
        try _beforeCleanup?()
        try quarantineAndRemove(temporaryName, in: parent, expected: expected, file: file)
        try _beforeFinalPathCheck?()
        let current: (parent: FileState.Parent, entry: FileState.Entry?)
        do { current = try pathIdentity(parentURL: parentURL, name: name) } catch { throw changedError(file) }
        guard current.parent == expected.parent, current.entry == nil else { throw changedError(file) }
    }

    /// Deployment consumes the lock in memory and never writes it. Verify that the pathname still names the exact
    /// file observed before resolution, so a concurrent edit cannot leave successful output beside different evidence.
    static func verifyUnchanged(
        at file: URL, since expected: FileState, _beforeFinalPathCheck: (() throws -> Void)? = nil
    ) throws {
        let current: FileState
        do {
            current = try rawFile(at: file, _beforeFinalPathCheck: _beforeFinalPathCheck).state
        } catch {
            throw deploymentChangedError(file)
        }
        guard current == expected else { throw deploymentChangedError(file) }
    }

    /// Human-readable lock drift. `self` is the previously recorded lock; `actual` is what this run used.
    func problems(comparedTo actual: SwiftPodsLock) -> [String] {
        var problems: [String] = []
        let expectedByURL = Dictionary(uniqueKeysWithValues: catalogs.map { (Data($0.url.utf8), $0) })
        let actualByURL = Dictionary(uniqueKeysWithValues: actual.catalogs.map { (Data($0.url.utf8), $0) })
        let keys = Set(expectedByURL.keys).union(actualByURL.keys).sorted { $0.lexicographicallyPrecedes($1) }
        for key in keys {
            guard let expected = expectedByURL[key] else {
                problems.append("Catalog \(actualByURL[key]!.url) is not recorded")
                continue
            }
            guard let found = actualByURL[key] else {
                problems.append("Catalog \(expected.url) is recorded but no longer used")
                continue
            }
            let url = expected.url
            if expected.revision != found.revision {
                problems.append("Catalog \(url) is at \(found.revision), locked at \(expected.revision)")
            }
            let expectedEntries = Dictionary(uniqueKeysWithValues: expected.entries.map { ($0.name.lowercased(), $0) })
            let foundEntries = Dictionary(uniqueKeysWithValues: found.entries.map { ($0.name.lowercased(), $0) })
            for name in Set(expectedEntries.keys).union(foundEntries.keys).sorted() {
                switch (expectedEntries[name], foundEntries[name]) {
                case (nil, let entry?): problems.append("Catalog entry `\(entry.name)` from \(url) is not recorded")
                case (let entry?, nil): problems.append("Catalog entry `\(entry.name)` from \(url) is recorded but no longer used")
                case (let expectedEntry?, let foundEntry?) where expectedEntry.sha256 != foundEntry.sha256:
                    problems.append("Catalog entry `\(foundEntry.name)` from \(url) does not match its locked SHA-256")
                default: break
                }
            }
        }
        return problems
    }

    private func validate(file: String) throws {
        guard version == Self.schemaVersion else {
            throw SwiftPodsError("SwiftPods.lock has unsupported version \(version)", file: file)
        }
        guard catalogs.count <= Self.maximumCatalogs else {
            throw SwiftPodsError("SwiftPods.lock contains more than \(Self.maximumCatalogs) catalogs", file: file)
        }
        var urls: Set<Data> = []
        var totalEntries = 0
        for catalog in catalogs {
            guard catalog.entries.count <= Self.maximumEntries - totalEntries else {
                throw SwiftPodsError("SwiftPods.lock contains more than \(Self.maximumEntries) catalog entries", file: file)
            }
            totalEntries += catalog.entries.count
            guard catalog.url.utf8.count <= 4_096, PackageLocation.isSafeCatalogSource(catalog.url) else {
                throw SwiftPodsError("SwiftPods.lock contains an invalid catalog URL", file: file)
            }
            guard urls.insert(Data(catalog.url.utf8)).inserted else {
                throw SwiftPodsError("SwiftPods.lock contains a duplicate catalog URL", file: file)
            }
            guard Self.isFullObjectID(catalog.revision) else {
                throw SwiftPodsError("SwiftPods.lock catalog revisions must be full lowercase object IDs", file: file)
            }
            var names: Set<String> = []
            for entry in catalog.entries {
                guard entry.name.utf8.count <= 4_096,
                    !entry.name.isEmpty,
                    !entry.name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
                else { throw SwiftPodsError("SwiftPods.lock contains an invalid catalog entry name", file: file) }
                guard names.insert(entry.name.lowercased()).inserted,
                    entry.sha256.count == 64, entry.sha256.allSatisfy(Self.isLowerHex)
                else {
                    throw SwiftPodsError("SwiftPods.lock contains an invalid or duplicate entry in \(catalog.url)", file: file)
                }
            }
        }
    }

    private static func isFullObjectID(_ text: String) -> Bool {
        (text.count == 40 || text.count == 64) && text.allSatisfy(isLowerHex)
    }

    private static func validateJSONSchema(_ data: Data, file: String) throws {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            Set(root.keys) == ["catalogs", "version"],
            let catalogs = root["catalogs"] as? [Any], catalogs.count <= maximumCatalogs
        else {
            throw SwiftPodsError("SwiftPods.lock has unexpected or missing top-level fields", file: file)
        }
        var totalEntries = 0
        for (catalogIndex, value) in catalogs.enumerated() {
            guard let catalog = value as? [String: Any],
                Set(catalog.keys) == ["entries", "revision", "url"],
                let entries = catalog["entries"] as? [Any], entries.count <= maximumEntries - totalEntries
            else {
                throw SwiftPodsError(
                    "SwiftPods.lock catalog \(catalogIndex + 1) has unexpected or missing fields", file: file)
            }
            totalEntries += entries.count
            for (entryIndex, entryValue) in entries.enumerated() {
                guard let entry = entryValue as? [String: Any], Set(entry.keys) == ["name", "sha256"] else {
                    throw SwiftPodsError(
                        "SwiftPods.lock catalog \(catalogIndex + 1) entry \(entryIndex + 1) has unexpected or missing fields",
                        file: file)
                }
            }
        }
    }

    private static func isLowerHex(_ character: Character) -> Bool {
        character.isASCII && (character.isNumber || "abcdef".contains(character))
    }

    static func read(at file: URL) throws -> (lock: SwiftPodsLock?, state: FileState) {
        let deferred: DeferredRead
        do { deferred = try deferredRead(at: file) } catch {
            throw SwiftPodsError(
                "Cannot read SwiftPods.lock", file: file.path,
                hint: "Restore a valid lock, or remove it and run `swiftpods install`: \(error)")
        }
        return (try deferred.lock(), try deferred.replacementState())
    }

    private struct RawFile: Sendable {
        let data: Data?
        let state: FileState
    }

    private static func observedFile(at file: URL) throws -> FileState {
        let name = try safeName(of: file)
        let parentURL = file.deletingLastPathComponent()
        let identity = try pathIdentity(parentURL: parentURL, name: name)
        return FileState(parent: identity.parent, entry: identity.entry, sha256: nil)
    }

    private static func rawFile(
        at file: URL, _beforeFinalPathCheck: (() throws -> Void)? = nil
    ) throws -> RawFile {
        let name = try safeName(of: file)
        let parentURL = file.deletingLastPathComponent()
        let parent = parentURL.path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NONBLOCK) }
        guard parent >= 0 else { throw CocoaError(.fileReadNoSuchFile) }
        defer { close(parent) }
        let parentState = try parentIdentity(parent)
        let descriptor = name.withCString {
            openat(parent, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        if descriptor < 0, errno == ENOENT {
            try _beforeFinalPathCheck?()
            let current = try pathIdentity(parentURL: parentURL, name: name)
            guard current.parent == parentState, current.entry == nil else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return RawFile(data: nil, state: FileState(parent: parentState, entry: nil, sha256: nil))
        }
        guard descriptor >= 0 else { throw CocoaError(.fileReadNoPermission) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
            status.st_size >= 0, status.st_size <= maximumBytes
        else { throw CocoaError(.fileReadTooLarge) }
        var data = Data()
        while let chunk = try handle.read(upToCount: min(1 << 20, maximumBytes + 1 - data.count)), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= maximumBytes else { throw CocoaError(.fileReadTooLarge) }
        }
        var finalStatus = stat()
        guard fstat(descriptor, &finalStatus) == 0,
            FileState.Entry(finalStatus) == FileState.Entry(status),
            Int64(data.count) == status.st_size
        else { throw CocoaError(.fileReadCorruptFile) }
        try _beforeFinalPathCheck?()
        let current = try pathIdentity(parentURL: parentURL, name: name)
        guard current.parent == parentState, current.entry == FileState.Entry(finalStatus) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return RawFile(
            data: data,
            state: FileState(
                parent: parentState, entry: FileState.Entry(finalStatus),
                sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()))
    }

    private static func safeName(of file: URL) throws -> String {
        let name = file.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"),
            !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { throw writeError(file, "has an unsafe file name") }
        return name
    }

    private static func parentIdentity(_ descriptor: Int32) throws -> FileState.Parent {
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFDIR else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        return FileState.Parent(status)
    }

    private static func entryIdentity(_ name: String, in parent: Int32) throws -> FileState.Entry? {
        var status = stat()
        if name.withCString({ fstatat(parent, $0, &status, AT_SYMLINK_NOFOLLOW) }) == 0 {
            return FileState.Entry(status)
        }
        if errno == ENOENT { return nil }
        throw SwiftPodsError("Cannot inspect SwiftPods.lock: \(String(cString: strerror(errno)))")
    }

    /// Reopens the current parent pathname, then observes the entry relative to that descriptor. This closes the
    /// rename window left by checking only the descriptor that was opened before a potentially long read or write.
    private static func pathIdentity(
        parentURL: URL, name: String
    ) throws -> (parent: FileState.Parent, entry: FileState.Entry?) {
        let parent = parentURL.path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NONBLOCK) }
        guard parent >= 0 else { throw CocoaError(.fileReadNoSuchFile) }
        defer { close(parent) }
        return (try parentIdentity(parent), try entryIdentity(name, in: parent))
    }

    private static func movedEntryMatches(_ name: String, in parent: Int32, expected: FileState) throws -> Bool {
        guard let expectedEntry = expected.entry, let expectedDigest = expected.sha256,
            let actualEntry = try entryIdentity(name, in: parent), actualEntry.isSameObject(as: expectedEntry)
        else { return false }
        return try digest(named: name, in: parent) == expectedDigest
    }

    /// Use only before a rename. Unlike `movedEntryMatches`, this rejects any metadata change since the post-swap
    /// token was captured; the latter deliberately tolerates the ctime advance caused by the rename it verifies.
    private static func linkedEntryMatchesExactly(
        _ name: String, in parent: Int32, expected: FileState, file: URL
    ) throws -> Bool {
        try captureMovedEntry(name, in: parent, parent: expected.parent, file: file) == expected
    }

    /// Captures the exact regular file currently linked under a descriptor-relative recovery name. This token is
    /// retained even when it is not the file the caller expected: a failed `RENAME_SWAP` compare-and-swap can then be
    /// reversed without either deleting or overwriting the concurrent file that the kernel actually displaced.
    private static func captureMovedEntry(
        _ name: String, in parent: Int32, parent parentState: FileState.Parent, file: URL
    ) throws -> FileState {
        let descriptor = name.withCString {
            openat(parent, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else {
            throw writeError(file, "cannot retain the displaced lock recovery file")
        }
        defer { close(descriptor) }
        let captured = try digest(descriptor: descriptor, file: file, description: "displaced file")
        var linked = stat()
        guard name.withCString({ fstatat(parent, $0, &linked, AT_SYMLINK_NOFOLLOW) }) == 0,
            FileState.Entry(linked) == captured.entry
        else { throw writeError(file, "displaced lock changed while its recovery token was captured") }
        return FileState(parent: parentState, entry: captured.entry, sha256: captured.sha256)
    }

    private static func representsSameFile(_ current: FileState, as expected: FileState) -> Bool {
        guard current.parent == expected.parent,
            let currentEntry = current.entry, let expectedEntry = expected.entry,
            let currentDigest = current.sha256, let expectedDigest = expected.sha256
        else { return false }
        return currentEntry.isSameObject(as: expectedEntry) && currentDigest == expectedDigest
    }

    private static func quarantineAndRemove(
        _ name: String, in parent: Int32, expected: FileState, file: URL,
        cleanupDirectoryName: String? = nil
    ) throws {
        let quarantine = try RollbackQuarantine(
            parent: parent, prefix: "lock-cleanup", name: cleanupDirectoryName)
        let item = "displaced"
        guard name.withCString({ source in
            item.withCString {
                renameatx_np(parent, source, quarantine.descriptor, $0, UInt32(RENAME_EXCL))
            }
        }) == 0 else {
            throw writeError(file, "cannot quarantine its recovery entry")
        }
        quarantine.preserveEvidence()
        guard try movedEntryMatches(item, in: quarantine.descriptor, expected: expected) else {
            throw writeError(file, "recovery entry changed before cleanup; evidence remains at \(quarantine.name)")
        }
        guard try movedEntryMatches(item, in: quarantine.descriptor, expected: expected) else {
            throw writeError(file, "recovery entry changed inside quarantine; evidence remains at \(quarantine.name)")
        }
        // POSIX has no compare-and-unlink operation. The final digest/identity check and unlink are adjacent and
        // descriptor-relative inside a random 0700 directory; mismatches are preserved rather than intentionally deleted.
        guard item.withCString({ unlinkat(quarantine.descriptor, $0, 0) }) == 0 else {
            throw writeError(file, "cannot remove its verified quarantined recovery entry")
        }
        try quarantine.finish()
    }

    /// Hashes the inode held open by the caller, not a pathname that another process could replace. The stat token on
    /// both sides of the read catches in-place mutation while the digest is being computed.
    private static func digest(
        descriptor: Int32, file: URL, description: String
    ) throws -> (entry: FileState.Entry, sha256: String) {
        var initial = stat()
        guard fstat(descriptor, &initial) == 0, initial.st_mode & S_IFMT == S_IFREG,
            initial.st_size >= 0, initial.st_size <= maximumBytes
        else { throw writeError(file, "\(description) is not a bounded regular file") }

        var hasher = SHA256()
        var offset: off_t = 0
        while offset < initial.st_size {
            let requested = min(1 << 20, Int(initial.st_size - offset))
            var chunk = Data(count: requested)
            var count: ssize_t = -1
            repeat {
                count = chunk.withUnsafeMutableBytes {
                    pread(descriptor, $0.baseAddress, requested, offset)
                }
            } while count < 0 && errno == EINTR
            guard count > 0 else { throw writeError(file, "\(description) was truncated while it was verified") }
            if count < requested { chunk.removeSubrange(Int(count)..<requested) }
            hasher.update(data: chunk)
            offset += off_t(count)
        }

        var extra: UInt8 = 0
        var extraCount: ssize_t = -1
        repeat {
            extraCount = withUnsafeMutablePointer(to: &extra) {
                pread(descriptor, $0, 1, offset)
            }
        } while extraCount < 0 && errno == EINTR
        var final = stat()
        guard extraCount == 0, fstat(descriptor, &final) == 0,
            FileState.Entry(final) == FileState.Entry(initial)
        else { throw writeError(file, "\(description) changed while it was verified") }
        return (
            FileState.Entry(final),
            hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }

    private static func digest(named name: String, in parent: Int32) throws -> String {
        let descriptor = name.withCString {
            openat(parent, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else { throw SwiftPodsError("Cannot verify the replaced SwiftPods.lock") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var initial = stat()
        guard fstat(descriptor, &initial) == 0, initial.st_mode & S_IFMT == S_IFREG,
            initial.st_size >= 0, initial.st_size <= maximumBytes
        else { throw SwiftPodsError("Replaced SwiftPods.lock is not a bounded regular file") }
        var hasher = SHA256()
        var remaining = initial.st_size
        while remaining > 0 {
            guard let data = try handle.read(upToCount: min(1 << 20, Int(remaining))), !data.isEmpty else {
                throw SwiftPodsError("Replaced SwiftPods.lock was truncated while it was verified")
            }
            remaining -= Int64(data.count)
            hasher.update(data: data)
        }
        let extra = try handle.read(upToCount: 1)
        var final = stat()
        guard fstat(descriptor, &final) == 0, FileState.Entry(final) == FileState.Entry(initial),
            remaining == 0, extra?.isEmpty != false
        else { throw SwiftPodsError("Replaced SwiftPods.lock changed while it was verified") }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func write(_ data: Data, to descriptor: Int32, file: URL) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw writeError(file, "cannot write its temporary file") }
                offset += count
            }
        }
    }

    private static func changedError(_ file: URL) -> SwiftPodsError {
        SwiftPodsError(
            "SwiftPods.lock changed after it was read; refusing to overwrite it", file: file.path,
            hint: "Review the concurrent change and run the command again")
    }

    private static func changedBeforeUseError(_ file: URL) -> SwiftPodsError {
        SwiftPodsError(
            "SwiftPods.lock changed after it was first inspected; refusing catalog resolution", file: file.path,
            hint: "Review the concurrent change and run the command again")
    }

    private static func deploymentChangedError(_ file: URL) -> SwiftPodsError {
        SwiftPodsError(
            "SwiftPods.lock changed after it was read during deployment validation", file: file.path,
            hint: "Review the concurrent change and run the command again")
    }

    private static func writeError(_ file: URL, _ detail: String) -> SwiftPodsError {
        SwiftPodsError("Cannot update SwiftPods.lock: \(detail)", file: file.path)
    }
}
