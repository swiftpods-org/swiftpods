import CryptoKit
import Darwin
import Foundation
import SwiftPodsManifest
import SwiftPodsXcode

/// Capability used by resolver runners that can set cwd from an authenticated directory descriptor. Production's
/// ProcessRunner implements it with the existing posix_spawn fchdir path; test runners may implement it without
/// launching Xcode.
public protocol DescriptorWorkingDirectoryCommandRunner: CommandRunner {
    /// Runs with cwd set from a borrowed authenticated directory descriptor. The implementation must neither close
    /// the descriptor nor replace this capability with a pathname lookup.
    func runDescriptorBacked(
        _ executable: String, _ arguments: [String], workingDirectoryDescriptor: Int32,
        timeout: TimeInterval
    ) throws -> String
}

extension ProcessRunner: DescriptorWorkingDirectoryCommandRunner {
    public func runDescriptorBacked(
        _ executable: String, _ arguments: [String], workingDirectoryDescriptor: Int32,
        timeout: TimeInterval
    ) throws -> String {
        var environment = ProcessRunner.sanitizedEnvironment(ProcessInfo.processInfo.environment)
        // `PWD` is merely caller-controlled text and would still describe SwiftPods' old working directory after the
        // descriptor-backed fchdir. Make every resolver component derive its location from the kernel cwd instead.
        environment.removeValue(forKey: "PWD")
        return String(decoding: try runData(
            executable, arguments, in: nil, timeout: timeout,
            maximumOutputBytes: 64 * 1_024 * 1_024, passingFileDescriptors: [],
            maximumPhysicalMemoryBytes: nil,
            workingDirectoryDescriptor: workingDirectoryDescriptor,
            environment: environment), as: UTF8.self)
    }
}

public struct InstallOptions: Sendable {
    /// Require `Package.resolved` for Swift packages and a matching `SwiftPods.lock` when catalog metadata is used.
    public var deployment = false
    /// Let Xcode resolve packages after integration.
    public var resolve = false
    /// Take over package references added without SwiftPods.
    public var adopt = false
    /// Use cached binaries and catalogs only.
    public var offline = false
    /// Fetch the latest version of catalogs that are not pinned to a revision.
    public var updateSources = false
    /// Trust Podfile-declared script file lists outside the Podfile directory.
    /// This is intentionally opt-in because reading a file list discloses its contents to generated build metadata.
    public var allowExternalFileLists = false

    public init() {}
}

public struct InstallReport: Sendable, Codable {
    public struct ProjectReport: Sendable, Codable {
        public let project: String
        public let changes: [ProjectChange]
    }

    public var projects: [ProjectReport] = []
    public var binaries: [String] = []
    /// Things SwiftPods adjusted that a reader should know about, such as repaired SDK frameworks.
    public var notes: [String] = []
}

/// Installs a directory's Podfile into its Xcode projects.
public struct Installer: Sendable {
    public let directory: URL
    /// The project of targets that do not name one; nil means the only project next to the Podfile.
    public let project: URL?
    private let runner: CommandRunner
    private let cache: URL
    private let sourcesCache: URL
    private let generatedMutationHook: (@Sendable (GeneratedMutationPoint) -> Void)?
    private let lockWriteHook: (@Sendable (LockWritePoint) throws -> Void)?

    /// Internal deterministic race points used by security regression tests. Production initializers never install a
    /// hook; keeping the mutation itself synchronous makes each adversarial replacement reproducible.
    enum GeneratedMutationPoint: Sendable, Equatable {
        case beforeGeneratedRootOpen
        case afterPublish(String)
        case afterWithdraw(String)
        case afterRollbackPublished(String)
        case afterRollbackWithdrawn(String)
        case afterStagingCleanupVerification
        case beforeBinaryRead(String)
        case afterBinaryRead(String)
        case beforeProjectTransactionSnapshot(String)
        case beforeProjectSave(String)
        case beforeDeintegrationMutation
        case beforeDeintegrationCommit
        case afterDeintegratedWorkspace(String)
        case afterDeintegratedProjectSave(String)
        case beforeLockFinalPathCheck
        case beforeLockCleanup
    }

    enum LockWritePoint: Sendable, Equatable {
        case beforeFinalPathCheck
        case beforeCleanup
    }

    public static let generatedDirectory = "SwiftPods"
    private static let ownershipFile = ".swiftpods-owned"
    private static let ownership = "SwiftPods generated directory v1\n"
    private static let stagingOwnershipFile = ".swiftpods-staging"
    private static let stagingOwnership = "SwiftPods generated staging v1\n"
    private static let maximumGeneratedEntries = 20_000
    private static let maximumGeneratedDepth = 64
    private static let maximumGeneratedFileBytes = 8 * 1_024 * 1_024
    private static let maximumGeneratedTextBytes = 128 * 1_024 * 1_024
    private static let maximumGeneratedBinaryEntries = 200_000
    private static let maximumWorkspaceEntries = 100_000
    private static let maximumWorkspaceProjects = 1_024
    private static let maximumScriptFileListBytes = 8 * 1_024 * 1_024
    private static let maximumScriptFileListTotalBytes = 32 * 1_024 * 1_024
    private static let maximumScriptFileLists = 1_024
    private static let maximumScriptFileListEntries = 25_000
    private static let maximumScriptFileListPhysicalLines = 50_000
    private static let maximumExpandedScriptFileListEntries = 200_000
    private static let maximumExpandedScriptFileListBytes = 64 * 1_024 * 1_024
    private static let maximumScriptFileListLineBytes = 16 * 1_024

    /// Enumerates through an independent descriptor and enforces the limit before retaining another name. Keeping this
    /// helper internal gives the regression suite a small limit without creating tens of thousands of filesystem nodes.
    static func boundedDirectoryNames(
        in descriptor: Int32, maximumCount: Int, kind: String
    ) throws -> [String] {
        guard maximumCount >= 0 else { throw SwiftPodsError("\(kind.capitalized) entry budget is invalid") }
        let duplicate = openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard duplicate >= 0, let directory = fdopendir(duplicate) else {
            if duplicate >= 0 { close(duplicate) }
            throw SwiftPodsError("Cannot enumerate \(kind): \(String(cString: strerror(errno)))")
        }
        defer { closedir(directory) }
        var result: [String] = []
        errno = 0
        while let entry = readdir(directory) {
            var bytes = entry.pointee.d_name
            let name = withUnsafeBytes(of: &bytes) { raw in
                String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
            }
            if name != "." && name != ".." {
                guard result.count < maximumCount else {
                    throw SwiftPodsError("\(kind.capitalized) contains more than \(maximumCount) entries")
                }
                result.append(name)
            }
            errno = 0
        }
        guard errno == 0 else {
            throw SwiftPodsError("Cannot enumerate \(kind): \(String(cString: strerror(errno)))")
        }
        return result.sorted()
    }

    private struct ScriptFileListSnapshot {
        let requested: URL
        let freshnessPath: String
        let contents: Data
        let entries: [String]
        let entryBytes: Int
    }

    /// Serializes all SwiftPods workspace mutations without creating a lock file that users would have to ignore.
    /// A directory flock is advisory, so the existing descriptor/CAS checks still defend against non-cooperating
    /// writers; cooperating install and deintegrate commands cannot interleave their multi-file transactions.
    private final class WorkspaceLock {
        let directory: URL
        private let descriptor: Int32
        private let identity: (device: dev_t, inode: ino_t)

        init(directory: URL) throws {
            self.directory = directory
            descriptor = directory.path.withCString {
                open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            }
            guard descriptor >= 0 else {
                throw SwiftPodsError("Cannot safely open the Podfile directory: \(String(cString: strerror(errno)))")
            }
            var opened = stat()
            var linked = stat()
            guard fstat(descriptor, &opened) == 0, opened.st_mode & S_IFMT == S_IFDIR,
                directory.path.withCString({ lstat($0, &linked) }) == 0,
                linked.st_mode & S_IFMT == S_IFDIR,
                opened.st_dev == linked.st_dev, opened.st_ino == linked.st_ino
            else {
                close(descriptor)
                throw SwiftPodsError("The Podfile directory changed while it was opened")
            }
            identity = (opened.st_dev, opened.st_ino)
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                let failure = errno
                close(descriptor)
                throw SwiftPodsError(
                    "Another SwiftPods command is updating this workspace: \(String(cString: strerror(failure)))")
            }
        }

        func verifyIdentity() throws {
            var opened = stat()
            var linked = stat()
            guard fstat(descriptor, &opened) == 0,
                directory.path.withCString({ lstat($0, &linked) }) == 0,
                opened.st_mode & S_IFMT == S_IFDIR, linked.st_mode & S_IFMT == S_IFDIR,
                opened.st_dev == identity.device, opened.st_ino == identity.inode,
                linked.st_dev == identity.device, linked.st_ino == identity.inode
            else { throw SwiftPodsError("The Podfile directory changed while the workspace was locked") }
        }

        /// GeneratedRoot must never reopen `directory.path`: an attacker could rename the locked directory and put a
        /// different tree at that pathname. Duplicating the locked descriptor anchors all generated mutations to the
        /// exact workspace inode that was authenticated before the transaction began.
        func duplicateDirectoryDescriptor() throws -> Int32 {
            try verifyIdentity()
            let duplicate = fcntl(descriptor, F_DUPFD_CLOEXEC, STDERR_FILENO + 1)
            guard duplicate >= 0 else { throw SwiftPodsError("Cannot duplicate the locked Podfile directory") }
            var opened = stat()
            guard fstat(duplicate, &opened) == 0, opened.st_mode & S_IFMT == S_IFDIR,
                opened.st_dev == identity.device, opened.st_ino == identity.inode
            else {
                close(duplicate)
                throw SwiftPodsError("The locked Podfile directory changed while it was duplicated")
            }
            return duplicate
        }

        deinit {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
    }

    private struct TransactionFileSnapshot: Equatable {
        fileprivate struct DirectoryState: Equatable {
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

        fileprivate struct EntryState: Equatable {
            let device: UInt64
            let inode: UInt64
            let mode: UInt32
            let links: UInt64
            let owner: UInt32
            let group: UInt32
            let flags: UInt32
            let size: Int64
            let accessedSeconds: Int64
            let accessedNanoseconds: Int64
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
                flags = status.st_flags
                size = status.st_size
                accessedSeconds = Int64(status.st_atimespec.tv_sec)
                accessedNanoseconds = Int64(status.st_atimespec.tv_nsec)
                modifiedSeconds = Int64(status.st_mtimespec.tv_sec)
                modifiedNanoseconds = Int64(status.st_mtimespec.tv_nsec)
                changedSeconds = Int64(status.st_ctimespec.tv_sec)
                changedNanoseconds = Int64(status.st_ctimespec.tv_nsec)
            }

            static func == (lhs: Self, rhs: Self) -> Bool {
                lhs.device == rhs.device && lhs.inode == rhs.inode && lhs.mode == rhs.mode
                    && lhs.links == rhs.links && lhs.owner == rhs.owner && lhs.group == rhs.group
                    && lhs.flags == rhs.flags && lhs.size == rhs.size
                    && lhs.modifiedSeconds == rhs.modifiedSeconds
                    && lhs.modifiedNanoseconds == rhs.modifiedNanoseconds
                    && lhs.changedSeconds == rhs.changedSeconds && lhs.changedNanoseconds == rhs.changedNanoseconds
            }

            func isSameObject(as other: Self) -> Bool {
                device == other.device && inode == other.inode && mode == other.mode && links == other.links
                    && owner == other.owner && group == other.group
            }

            func representsAfterRename(_ other: Self) -> Bool {
                isSameObject(as: other) && flags == other.flags && size == other.size
                    && modifiedSeconds == other.modifiedSeconds && modifiedNanoseconds == other.modifiedNanoseconds
            }

            func isSameDirectoryObject(as other: Self) -> Bool {
                device == other.device && inode == other.inode && mode == other.mode
                    && owner == other.owner && group == other.group && flags == other.flags
                    && mode & UInt32(S_IFMT) == UInt32(S_IFDIR)
            }

            func hasRestoredMetadata(of other: Self) -> Bool {
                mode == other.mode && owner == other.owner && group == other.group && flags == other.flags
                    && size == other.size && accessedSeconds == other.accessedSeconds
                    && accessedNanoseconds == other.accessedNanoseconds
                    && modifiedSeconds == other.modifiedSeconds
                    && modifiedNanoseconds == other.modifiedNanoseconds
            }
        }

        let parent: DirectoryState
        let entry: EntryState
        let metadata: FileSecurityMetadata
        let data: Data
    }

    private enum GeneratedMutation {
        case published(name: String, installed: GeneratedEntryToken, displaced: GeneratedEntryToken?)
        case withdrawn(name: String, displaced: GeneratedEntryToken)
    }

    private struct GeneratedEntryToken: Equatable {
        let entry: TransactionFileSnapshot.EntryState
        let tree: Data
        /// Exact descriptor-relative entries captured with `tree`. Cleanup uses this manifest instead of enumerating
        /// whatever happens to be present later, so a non-cooperating writer cannot add a child and have it deleted.
        let members: [String: TransactionFileSnapshot.EntryState]

        func preservesManagedMembers(of other: Self) -> Bool {
            let managed = members.filter { !GeneratedPackageMetadata.contains($0.key) }
            let previous = other.members.filter { !GeneratedPackageMetadata.contains($0.key) }
            guard Set(managed.keys) == Set(previous.keys) else { return false }
            return managed.allSatisfy { path, state in
                guard let before = previous[path] else { return false }
                return path.isEmpty ? state.isSameDirectoryObject(as: before) : state == before
            }
        }

        func representsAfterRename(_ other: Self) -> Bool {
            guard entry.representsAfterRename(other.entry), tree == other.tree,
                Set(members.keys) == Set(other.members.keys)
            else { return false }
            for (path, state) in members {
                guard let previous = other.members[path],
                    path.isEmpty ? state.representsAfterRename(previous) : state == previous
                else { return false }
            }
            return true
        }
    }

    private struct ProjectRollback {
        let file: URL
        let directory: RetainedProjectDirectory
        let original: TransactionFileSnapshot
        let installed: TransactionFileSnapshot
    }

    private struct PackageResolvedRollback {
        let project: URL
        let directory: RetainedProjectDirectory
        let original: PackageResolved.PathSnapshot
        let installed: PackageResolved.PathSnapshot
    }

    /// Owns one duplicate of the exact `.xcodeproj` directory retained by `XcodeProject`. Transaction snapshots,
    /// journal backups, rollback and resolver state all share this capability instead of independently reopening the
    /// mutable public pathname.
    private final class RetainedProjectDirectory {
        let descriptor: Int32

        init(_ project: XcodeProject) throws {
            try project.verifyDirectoryPathBinding()
            descriptor = try project.duplicateRetainedDirectoryDescriptor()
        }

        deinit { close(descriptor) }
    }

    /// Reads a file and its parent through retained descriptors. This is used only for transactional rollback of the
    /// project files that XcodeProject has already validated independently.
    private static func transactionSnapshot(
        _ file: URL, in parent: Int32, maximumBytes: Int = 32 * 1_024 * 1_024
    ) throws
        -> TransactionFileSnapshot
    {
        let name = file.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\") else {
            throw SwiftPodsError("Cannot transactionally snapshot an unsafe file name", file: file.path)
        }
        var parentStatus = stat()
        guard fstat(parent, &parentStatus) == 0, parentStatus.st_mode & S_IFMT == S_IFDIR else {
            throw SwiftPodsError("Cannot inspect the file parent", file: file.path)
        }
        let value = try transactionEntry(named: name, in: parent, maximumBytes: maximumBytes, file: file)
        var finalStatus = stat()
        guard fstat(parent, &finalStatus) == 0,
            TransactionFileSnapshot.DirectoryState(finalStatus)
                == TransactionFileSnapshot.DirectoryState(parentStatus)
        else { throw SwiftPodsError("The retained file parent changed while it was read", file: file.path) }
        return TransactionFileSnapshot(
            parent: .init(parentStatus), entry: value.entry, metadata: value.metadata, data: value.data)
    }

    /// Path-based adapter retained only for the deterministic unit-test harness. Production project transactions use
    /// the descriptor overload above.
    private static func transactionSnapshot(_ file: URL, maximumBytes: Int = 32 * 1_024 * 1_024) throws
        -> TransactionFileSnapshot
    {
        let parentURL = file.deletingLastPathComponent()
        let parent = parentURL.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard parent >= 0 else { throw SwiftPodsError("Cannot safely open the file parent", file: file.path) }
        defer { close(parent) }
        return try transactionSnapshot(file, in: parent, maximumBytes: maximumBytes)
    }

    private static func transactionEntry(
        named name: String, in parent: Int32, maximumBytes: Int, file: URL
    ) throws -> (entry: TransactionFileSnapshot.EntryState, metadata: FileSecurityMetadata, data: Data) {
        let descriptor = name.withCString {
            openat(parent, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else { throw SwiftPodsError("Cannot safely read the transaction file", file: file.path) }
        defer { close(descriptor) }
        var initial = stat()
        guard fstat(descriptor, &initial) == 0, initial.st_mode & S_IFMT == S_IFREG,
            initial.st_size >= 0, initial.st_size <= maximumBytes
        else { throw SwiftPodsError("Transaction file is not a bounded regular file", file: file.path) }
        let duplicate = duplicateCloseOnExec(descriptor)
        guard duplicate >= 0 else {
            throw SwiftPodsError("Cannot duplicate the transaction file descriptor", file: file.path)
        }
        let handle = FileHandle(fileDescriptor: duplicate, closeOnDealloc: true)
        defer { try? handle.close() }
        var data = Data()
        while let chunk = try handle.read(upToCount: min(1 << 20, maximumBytes + 1 - data.count)), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= maximumBytes else {
                throw SwiftPodsError("Transaction file exceeds \(maximumBytes) bytes", file: file.path)
            }
        }
        let metadata: FileSecurityMetadata
        do { metadata = try FileSecurityMetadata(descriptor: descriptor) } catch {
            throw SwiftPodsError("Cannot snapshot transaction file ACLs or extended attributes", file: file.path)
        }
        var final = stat()
        var linked = stat()
        guard fstat(descriptor, &final) == 0,
            TransactionFileSnapshot.EntryState(final) == TransactionFileSnapshot.EntryState(initial),
            Int64(data.count) == initial.st_size,
            name.withCString({ fstatat(parent, $0, &linked, AT_SYMLINK_NOFOLLOW) }) == 0,
            TransactionFileSnapshot.EntryState(linked) == TransactionFileSnapshot.EntryState(final)
        else { throw SwiftPodsError("Transaction file changed while it was read", file: file.path) }
        return (.init(initial), metadata, data)
    }

    /// Restores the old bytes only when the pathname still denotes the exact inode and bytes installed by this
    /// transaction. The swap is verified before the displaced file is removed.
    private static func restoreTransactionFile(
        _ original: TransactionFileSnapshot, at file: URL, in parent: Int32,
        replacing expected: TransactionFileSnapshot,
        afterSwapForTesting: (() -> Void)? = nil,
        beforeReverseSwapForTesting: (() -> Void)? = nil,
        beforeCleanupForTesting: (() -> Void)? = nil
    ) throws {
        let name = file.lastPathComponent
        var parentStatus = stat()
        guard fstat(parent, &parentStatus) == 0,
            TransactionFileSnapshot.DirectoryState(parentStatus) == original.parent,
            TransactionFileSnapshot.DirectoryState(parentStatus).device == expected.parent.device,
            TransactionFileSnapshot.DirectoryState(parentStatus).inode == expected.parent.inode
        else { throw SwiftPodsError("Rollback directory changed; refusing to overwrite it", file: file.path) }
        guard flock(parent, LOCK_EX | LOCK_NB) == 0 else {
            throw SwiftPodsError("Another process is updating the rollback directory", file: file.path)
        }
        defer { flock(parent, LOCK_UN) }
        let current = try transactionEntry(named: name, in: parent, maximumBytes: 32 * 1_024 * 1_024, file: file)
        guard current.entry == expected.entry, current.metadata == expected.metadata, current.data == expected.data else {
            throw SwiftPodsError("Transaction file changed; refusing to overwrite a concurrent edit", file: file.path)
        }

        let temporary = ".\(name).rollback-\(UUID().uuidString)"
        let output = temporary.withCString {
            openat(parent, $0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        }
        guard output >= 0 else { throw SwiftPodsError("Cannot create the rollback file", file: file.path) }
        var temporaryExists = true
        defer {
            close(output)
            if temporaryExists { _ = temporary.withCString { unlinkat(parent, $0, 0) } }
        }
        try writeAll(original.data, to: output, file: file)
        var restoredTimes = [
            timespec(tv_sec: time_t(original.entry.accessedSeconds), tv_nsec: Int(original.entry.accessedNanoseconds)),
            timespec(tv_sec: time_t(original.entry.modifiedSeconds), tv_nsec: Int(original.entry.modifiedNanoseconds)),
        ]
        // chown may clear set-id bits, while chmod may rewrite ACL masks. Restore owner and mode before the exact
        // ACL/xattrs, timestamps, and flags.
        guard fchown(output, uid_t(original.entry.owner), gid_t(original.entry.group)) == 0,
            fchmod(output, mode_t(original.entry.mode & 0o7777)) == 0
        else { throw SwiftPodsError("Cannot restore transaction file ownership or mode", file: file.path) }
        do { try original.metadata.apply(to: output) } catch {
            throw SwiftPodsError("Cannot restore transaction file ACLs or extended attributes", file: file.path)
        }
        guard futimens(output, &restoredTimes) == 0,
            fchflags(output, original.entry.flags) == 0, fsync(output) == 0
        else { throw SwiftPodsError("Cannot finalize the rollback file", file: file.path) }

        let beforeSwap = try transactionEntry(named: name, in: parent, maximumBytes: 32 * 1_024 * 1_024, file: file)
        guard beforeSwap.entry == expected.entry, beforeSwap.metadata == expected.metadata,
            beforeSwap.data == expected.data
        else {
            throw SwiftPodsError("Transaction file changed; refusing rollback", file: file.path)
        }
        guard temporary.withCString({ source in
            name.withCString { renameatx_np(parent, source, parent, $0, UInt32(RENAME_SWAP)) }
        }) == 0 else { throw SwiftPodsError("Cannot atomically roll back the transaction file", file: file.path) }
        // Preserve the random recovery name on every exceptional post-swap path. Only a fully verified success may
        // unlink it.
        temporaryExists = false
        afterSwapForTesting?()
        let displaced = try transactionEntry(
            named: temporary, in: parent, maximumBytes: 32 * 1_024 * 1_024, file: file)
        let installed = try transactionEntry(
            named: name, in: parent, maximumBytes: 32 * 1_024 * 1_024, file: file)
        guard displaced.entry.representsAfterRename(expected.entry), displaced.metadata == expected.metadata,
            displaced.data == expected.data, installed.entry.hasRestoredMetadata(of: original.entry),
            installed.metadata == original.metadata, installed.data == original.data
        else {
            beforeReverseSwapForTesting?()
            let displacedBeforeReverse = try transactionEntry(
                named: temporary, in: parent, maximumBytes: 32 * 1_024 * 1_024, file: file)
            let installedBeforeReverse = try transactionEntry(
                named: name, in: parent, maximumBytes: 32 * 1_024 * 1_024, file: file)
            guard displacedBeforeReverse.entry == displaced.entry,
                displacedBeforeReverse.metadata == displaced.metadata,
                displacedBeforeReverse.data == displaced.data,
                installedBeforeReverse.entry == installed.entry,
                installedBeforeReverse.metadata == installed.metadata,
                installedBeforeReverse.data == installed.data
            else {
                throw SwiftPodsError(
                    "Transaction file changed before rollback reversal; recovery evidence remains at \(temporary)",
                    file: file.path)
            }
            guard temporary.withCString({ source in
                name.withCString { renameatx_np(parent, source, parent, $0, UInt32(RENAME_SWAP)) }
            }) == 0 else {
                throw SwiftPodsError(
                    "Cannot reverse the transaction rollback; recovery evidence remains at \(temporary)",
                    file: file.path)
            }
            let restoredExpected = try transactionEntry(
                named: name, in: parent, maximumBytes: 32 * 1_024 * 1_024, file: file)
            let preservedRecovery = try transactionEntry(
                named: temporary, in: parent, maximumBytes: 32 * 1_024 * 1_024, file: file)
            guard restoredExpected.entry.representsAfterRename(displaced.entry),
                restoredExpected.metadata == displaced.metadata, restoredExpected.data == displaced.data,
                preservedRecovery.entry.representsAfterRename(installed.entry),
                preservedRecovery.metadata == installed.metadata, preservedRecovery.data == installed.data
            else {
                throw SwiftPodsError(
                    "Transaction file changed during rollback reversal; recovery evidence remains at \(temporary)",
                    file: file.path)
            }
            throw SwiftPodsError(
                "Transaction file changed during rollback; recovery evidence remains at \(temporary)", file: file.path)
        }
        // Post-swap byte verification may advance atime. Reapply both original timestamps through the retained
        // descriptor and prove that the pathname still denotes that inode before removing displaced evidence.
        guard futimens(output, &restoredTimes) == 0, fsync(output) == 0 else {
            throw SwiftPodsError(
                "Cannot finalize transaction file timestamps; recovery evidence remains at \(temporary)", file: file.path)
        }
        var restoredDescriptorStatus = stat()
        var restoredLinkedStatus = stat()
        guard fstat(output, &restoredDescriptorStatus) == 0,
            name.withCString({ fstatat(parent, $0, &restoredLinkedStatus, AT_SYMLINK_NOFOLLOW) }) == 0,
            TransactionFileSnapshot.EntryState(restoredDescriptorStatus)
                == TransactionFileSnapshot.EntryState(restoredLinkedStatus),
            TransactionFileSnapshot.EntryState(restoredDescriptorStatus).hasRestoredMetadata(of: original.entry)
        else {
            throw SwiftPodsError(
                "Transaction file changed before timestamp finalization; recovery evidence remains at \(temporary)",
                file: file.path)
        }
        try quarantineAndRemoveTransactionRecovery(
            named: temporary, in: parent, expected: displaced, file: file,
            beforeMoveForTesting: beforeCleanupForTesting)
        guard fsync(parent) == 0 else { throw SwiftPodsError("Cannot synchronize the rollback directory", file: file.path) }
    }

    /// Path-based adapter retained only for the deterministic unit-test harness.
    private static func restoreTransactionFile(
        _ original: TransactionFileSnapshot, at file: URL, replacing expected: TransactionFileSnapshot,
        afterSwapForTesting: (() -> Void)? = nil,
        beforeReverseSwapForTesting: (() -> Void)? = nil,
        beforeCleanupForTesting: (() -> Void)? = nil
    ) throws {
        let parentURL = file.deletingLastPathComponent()
        let parent = parentURL.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard parent >= 0 else { throw SwiftPodsError("Cannot safely open the rollback directory", file: file.path) }
        defer { close(parent) }
        try restoreTransactionFile(
            original, at: file, in: parent, replacing: expected,
            afterSwapForTesting: afterSwapForTesting,
            beforeReverseSwapForTesting: beforeReverseSwapForTesting,
            beforeCleanupForTesting: beforeCleanupForTesting)
    }

    private static func quarantineAndRemoveTransactionRecovery(
        named name: String, in parent: Int32,
        expected: (entry: TransactionFileSnapshot.EntryState, metadata: FileSecurityMetadata, data: Data),
        file: URL, beforeMoveForTesting: (() -> Void)?
    ) throws {
        beforeMoveForTesting?()
        let quarantine = try RollbackQuarantine(parent: parent, prefix: "project-cleanup")
        let item = "displaced"
        guard name.withCString({ source in
            item.withCString {
                renameatx_np(parent, source, quarantine.descriptor, $0, UInt32(RENAME_EXCL))
            }
        }) == 0 else {
            throw SwiftPodsError("Cannot quarantine the displaced transaction file", file: file.path)
        }
        quarantine.preserveEvidence()
        let moved = try transactionEntry(
            named: item, in: quarantine.descriptor, maximumBytes: 32 * 1_024 * 1_024, file: file)
        guard moved.entry.representsAfterRename(expected.entry), moved.metadata == expected.metadata,
            moved.data == expected.data
        else {
            throw SwiftPodsError(
                "Displaced transaction file changed before cleanup; evidence remains at \(quarantine.name)",
                file: file.path)
        }
        let immediatelyBeforeUnlink = try transactionEntry(
            named: item, in: quarantine.descriptor, maximumBytes: 32 * 1_024 * 1_024, file: file)
        guard immediatelyBeforeUnlink.entry == moved.entry,
            immediatelyBeforeUnlink.metadata == moved.metadata, immediatelyBeforeUnlink.data == moved.data
        else {
            throw SwiftPodsError(
                "Displaced transaction file changed inside cleanup quarantine; evidence remains at \(quarantine.name)",
                file: file.path)
        }
        // POSIX has no compare-and-unlink primitive. The descriptor-relative unlink follows the final token check
        // immediately inside a random owner-only directory; mismatches are never intentionally removed.
        guard item.withCString({ unlinkat(quarantine.descriptor, $0, 0) }) == 0 else {
            throw SwiftPodsError(
                "Cannot remove verified displaced transaction file at \(quarantine.name)", file: file.path)
        }
        try quarantine.finish()
    }

    /// Internal deterministic harness for the two-name CAS used by project rollback. Production callers use the
    /// private snapshots built by `install`; tests can inject non-cooperating writers at the post-swap boundaries.
    static func testTransactionRollback(
        at file: URL, installed: Data,
        afterSwap: @escaping () -> Void,
        beforeReverseSwap: @escaping () -> Void,
        beforeCleanup: @escaping () -> Void = {}
    ) throws {
        let original = try transactionSnapshot(file)
        try installed.write(to: file, options: .atomic)
        let expected = try transactionSnapshot(file)
        try restoreTransactionFile(
            original, at: file, replacing: expected,
            afterSwapForTesting: afterSwap, beforeReverseSwapForTesting: beforeReverseSwap,
            beforeCleanupForTesting: beforeCleanup)
    }

    private static func writeAll(_ data: Data, to descriptor: Int32, file: URL) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw SwiftPodsError("Cannot write rollback data", file: file.path) }
                offset += count
            }
        }
    }

    /// Keeps every generated-tree mutation relative to already-open directories. Path validation alone cannot prevent
    /// another writer from replacing `SwiftPods` or one of its parents between `lstat` and a later write/rename/remove.
    private final class GeneratedRoot {
        let url: URL
        let name: String
        let parentDescriptor: Int32
        let descriptor: Int32
        private let workspaceLock: WorkspaceLock
        private let mutationHook: (@Sendable (GeneratedMutationPoint) -> Void)?
        private let identity: (device: dev_t, inode: ino_t)

        init(
            workspaceLock: WorkspaceLock, name: String, create: Bool,
            mutationHook: (@Sendable (GeneratedMutationPoint) -> Void)?
        ) throws {
            let parent = workspaceLock.directory
            let generatedURL = parent.appendingPathComponent(name, isDirectory: true)
            let parentDescriptor = try workspaceLock.duplicateDirectoryDescriptor()
            var status = stat()
            let found = name.withCString { fstatat(parentDescriptor, $0, &status, AT_SYMLINK_NOFOLLOW) }
            var created = false
            if found != 0 {
                guard errno == ENOENT, create else {
                    let failure = errno
                    close(parentDescriptor)
                    throw SwiftPodsError("Cannot inspect \(generatedURL.path): \(String(cString: strerror(failure)))")
                }
                guard name.withCString({ mkdirat(parentDescriptor, $0, 0o755) }) == 0 else {
                    let failure = errno
                    close(parentDescriptor)
                    throw SwiftPodsError("Cannot create \(generatedURL.path): \(String(cString: strerror(failure)))")
                }
                created = true
            } else if status.st_mode & S_IFMT != S_IFDIR {
                close(parentDescriptor)
                let detail = status.st_mode & S_IFMT == S_IFLNK ? "symbolic link" : "non-directory"
                throw SwiftPodsError("Refusing to use \(detail) \(generatedURL.path) as the generated directory")
            }
            let descriptor = name.withCString {
                openat(parentDescriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            }
            guard descriptor >= 0 else {
                let failure = errno
                close(parentDescriptor)
                throw SwiftPodsError("Cannot safely open \(generatedURL.path): \(String(cString: strerror(failure)))")
            }
            var opened = stat()
            guard fstat(descriptor, &opened) == 0, opened.st_mode & S_IFMT == S_IFDIR else {
                close(descriptor)
                close(parentDescriptor)
                throw SwiftPodsError("Generated root is not a directory: \(generatedURL.path)")
            }
            do {
                if created {
                    try Self.secureCreatedDescriptor(descriptor, mode: 0o755, kind: "Generated root")
                    guard fstat(descriptor, &opened) == 0 else {
                        throw SwiftPodsError("Cannot inspect generated root permissions")
                    }
                } else {
                    try Self.validateOwnedDescriptor(descriptor, privateDirectory: false, kind: "Generated root")
                }
            } catch {
                close(descriptor)
                close(parentDescriptor)
                throw error
            }
            var linked = stat()
            guard name.withCString({ fstatat(parentDescriptor, $0, &linked, AT_SYMLINK_NOFOLLOW) }) == 0,
                linked.st_mode & S_IFMT == S_IFDIR,
                linked.st_dev == opened.st_dev, linked.st_ino == opened.st_ino
            else {
                close(descriptor)
                close(parentDescriptor)
                throw SwiftPodsError("The generated directory changed while it was being opened: \(generatedURL.path)")
            }
            self.url = generatedURL
            self.name = name
            self.parentDescriptor = parentDescriptor
            self.descriptor = descriptor
            self.workspaceLock = workspaceLock
            self.mutationHook = mutationHook
            identity = (opened.st_dev, opened.st_ino)
        }

        deinit {
            close(descriptor)
            close(parentDescriptor)
        }

        func verifyIdentity() throws {
            try workspaceLock.verifyIdentity()
            var opened = stat()
            var linked = stat()
            guard fstat(descriptor, &opened) == 0,
                name.withCString({ fstatat(parentDescriptor, $0, &linked, AT_SYMLINK_NOFOLLOW) }) == 0,
                opened.st_mode & S_IFMT == S_IFDIR, linked.st_mode & S_IFMT == S_IFDIR,
                opened.st_dev == identity.device, opened.st_ino == identity.inode,
                linked.st_dev == identity.device, linked.st_ino == identity.inode
            else { throw SwiftPodsError("The generated directory changed while it was being updated: \(url.path)") }
            try Self.validateOwnedDescriptor(descriptor, privateDirectory: false, kind: "Generated root")
        }

        fileprivate func invokeMutationHook(_ point: GeneratedMutationPoint) {
            mutationHook?(point)
        }

        func status(named name: String) throws -> stat? {
            try Self.requireComponent(name)
            var value = stat()
            if name.withCString({ fstatat(descriptor, $0, &value, AT_SYMLINK_NOFOLLOW) }) == 0 { return value }
            if errno == ENOENT { return nil }
            throw SwiftPodsError("Cannot inspect \(url.appendingPathComponent(name).path): \(String(cString: strerror(errno)))")
        }

        /// Captures a descriptor-anchored compare-and-swap token for one complete generated tree. File contents need
        /// not be read again: inode, size, flags, mtime and unforgeable ctime are included for every member, while link
        /// targets are hashed explicitly. A same-UID non-cooperating writer therefore cannot replace or edit a member
        /// without changing the token that is verified after the atomic rename.
        fileprivate static func mutationToken(
            named name: String, in parent: Int32, package: Bool? = nil
        ) throws -> GeneratedEntryToken? {
            try requireComponent(name)
            guard let status = try status(named: name, in: parent) else { return nil }
            var hasher = SHA256()
            var entries = 0
            var members: [String: TransactionFileSnapshot.EntryState] = [:]
            let entry = try mutationFingerprint(
                named: name, relative: "", in: parent, depth: 0, entries: &entries,
                members: &members, hasher: &hasher,
                package: package ?? GeneratedPackageMetadata.isPackage(name))
            guard entry == TransactionFileSnapshot.EntryState(status) else {
                throw SwiftPodsError("Generated path changed while its mutation token was captured: \(name)")
            }
            return GeneratedEntryToken(entry: entry, tree: Data(hasher.finalize()), members: members)
        }

        func acceptingResolverMetadata(_ mutation: GeneratedMutation) throws -> GeneratedMutation {
            guard case .published(let name, let installed, let displaced) = mutation,
                GeneratedPackageMetadata.isPackage(name)
            else { return mutation }
            try verifyIdentity()
            guard let current = try Self.mutationToken(named: name, in: descriptor),
                current.preservesManagedMembers(of: installed)
            else { throw SwiftPodsError("Resolver changed managed generated package contents: \(name)") }
            return .published(name: name, installed: current, displaced: displaced)
        }

        private static func representsAfterRename(
            _ current: GeneratedEntryToken?, previous: GeneratedEntryToken?
        ) -> Bool {
            switch (current, previous) {
            case (nil, nil): return true
            case (.some(let current), .some(let previous)): return current.representsAfterRename(previous)
            default: return false
            }
        }

        private static func mutationFingerprint(
            named name: String, relative: String, in parent: Int32, depth: Int,
            entries: inout Int, members: inout [String: TransactionFileSnapshot.EntryState],
            hasher: inout SHA256, package: Bool
        ) throws -> TransactionFileSnapshot.EntryState {
            try requireComponent(name)
            guard depth <= Installer.maximumGeneratedDepth else {
                throw SwiftPodsError("Generated mutation is nested too deeply")
            }
            guard let status = try status(named: name, in: parent) else {
                throw SwiftPodsError("Generated path disappeared while its mutation token was captured: \(name)")
            }
            entries += 1
            guard entries <= Installer.maximumGeneratedBinaryEntries + 1 else {
                throw SwiftPodsError("Generated mutation contains too many entries")
            }
            let state = TransactionFileSnapshot.EntryState(status)
            let derived = package && GeneratedPackageMetadata.contains(relative)
            if derived, !relative.contains("/"), status.st_mode & S_IFMT != S_IFDIR {
                throw SwiftPodsError("Resolver metadata root must be a real directory: \(relative)")
            }
            guard members.updateValue(state, forKey: relative) == nil else {
                throw SwiftPodsError("Generated mutation contains a duplicate path: \(relative)")
            }
            hashMutationField(relative, into: &hasher)
            // Renaming the top-level object legitimately advances its ctime. Descendant ctimes remain part of the
            // fingerprint, while top-level identity/size/mode/mtime still prove which complete tree moved.
            let changedSeconds = relative.isEmpty ? 0 : state.changedSeconds
            let changedNanoseconds = relative.isEmpty ? 0 : state.changedNanoseconds
            hashMutationField(
                [
                    state.device, state.inode, UInt64(state.mode), state.links, UInt64(state.owner),
                    UInt64(state.group), UInt64(state.flags), UInt64(bitPattern: state.size),
                    UInt64(bitPattern: state.modifiedSeconds), UInt64(bitPattern: state.modifiedNanoseconds),
                    UInt64(bitPattern: changedSeconds), UInt64(bitPattern: changedNanoseconds),
                ].map(String.init).joined(separator: ":"),
                into: &hasher)

            switch status.st_mode & S_IFMT {
            case S_IFDIR:
                let directory = name.withCString {
                    openat(parent, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
                }
                guard directory >= 0 else {
                    throw SwiftPodsError("Cannot open generated directory while capturing its mutation token: \(name)")
                }
                defer { close(directory) }
                var opened = stat()
                guard fstat(directory, &opened) == 0,
                    TransactionFileSnapshot.EntryState(opened) == state
                else { throw SwiftPodsError("Generated directory changed while its mutation token was captured: \(name)") }
                if !derived {
                    try validateOwnedDescriptor(
                        directory, privateDirectory: false, kind: "Generated mutation directory \(name)")
                } else if status.st_uid != geteuid() {
                    throw SwiftPodsError("Resolver metadata directory must be owned by the current user")
                }
                let remaining = Installer.maximumGeneratedBinaryEntries + 1 - entries
                for child in try names(in: directory, maximumCount: remaining) {
                    let childRelative = relative.isEmpty ? child : relative + "/" + child
                    _ = try mutationFingerprint(
                        named: child, relative: childRelative, in: directory, depth: depth + 1,
                        entries: &entries, members: &members, hasher: &hasher, package: package)
                }
                var final = stat()
                var linked = stat()
                guard fstat(directory, &final) == 0,
                    TransactionFileSnapshot.EntryState(final) == state,
                    name.withCString({ fstatat(parent, $0, &linked, AT_SYMLINK_NOFOLLOW) }) == 0,
                    TransactionFileSnapshot.EntryState(linked) == state
                else { throw SwiftPodsError("Generated directory changed while its mutation token was captured: \(name)") }
            case S_IFREG:
                let file = name.withCString {
                    openat(parent, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
                }
                guard file >= 0 else {
                    throw SwiftPodsError("Cannot open generated file while capturing its mutation token: \(name)")
                }
                defer { close(file) }
                var opened = stat()
                var linked = stat()
                guard fstat(file, &opened) == 0,
                    TransactionFileSnapshot.EntryState(opened) == state,
                    name.withCString({ fstatat(parent, $0, &linked, AT_SYMLINK_NOFOLLOW) }) == 0,
                    TransactionFileSnapshot.EntryState(linked) == state
                else { throw SwiftPodsError("Generated file changed while its mutation token was captured: \(name)") }
                if !derived {
                    try validateOwnedDescriptor(
                        file, privateDirectory: false, kind: "Generated mutation file \(name)")
                } else if status.st_uid != geteuid() {
                    throw SwiftPodsError("Resolver metadata file must be owned by the current user")
                }
            case S_IFLNK:
                var target = [UInt8](repeating: 0, count: 64 * 1_024)
                let count = target.withUnsafeMutableBytes { buffer in
                    name.withCString {
                        readlinkat(parent, $0, buffer.baseAddress, buffer.count)
                    }
                }
                guard count >= 0, count < target.count else {
                    throw SwiftPodsError("Generated symbolic link is too large or changed: \(name)")
                }
                hashMutationField(Data(target.prefix(Int(count))), into: &hasher)
                var linked = stat()
                guard name.withCString({ fstatat(parent, $0, &linked, AT_SYMLINK_NOFOLLOW) }) == 0,
                    TransactionFileSnapshot.EntryState(linked) == state
                else { throw SwiftPodsError("Generated symbolic link changed while its mutation token was captured: \(name)") }
            default:
                throw SwiftPodsError("Generated mutation contains a special file: \(name)")
            }
            return state
        }

        private static func hashMutationField(_ value: String, into hasher: inout SHA256) {
            hashMutationField(Data(value.utf8), into: &hasher)
        }

        private static func hashMutationField(_ value: Data, into hasher: inout SHA256) {
            var length = UInt64(value.count).littleEndian
            withUnsafeBytes(of: &length) { hasher.update(data: Data($0)) }
            hasher.update(data: value)
        }

        func readText(named name: String, maximumBytes: Int, kind: String) throws -> String {
            try Self.requireComponent(name)
            let file = name.withCString { openat(descriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK) }
            guard file >= 0 else {
                throw SwiftPodsError("Cannot safely read \(kind.lowercased()): \(String(cString: strerror(errno)))")
            }
            defer { close(file) }
            try Self.validateOwnedDescriptor(file, privateDirectory: false, kind: kind)
            return try Self.readText(file, maximumBytes: maximumBytes, kind: kind)
        }

        func writeExclusive(_ data: Data, named name: String) throws {
            try Self.writeExclusive(data, named: name, in: descriptor)
        }

        func makeStaging() throws -> GeneratedStaging {
            try verifyIdentity()
            let name = ".staging-" + UUID().uuidString
            guard name.withCString({ mkdirat(descriptor, $0, 0o700) }) == 0 else {
                throw SwiftPodsError("Cannot create generated staging directory: \(String(cString: strerror(errno)))")
            }
            return try GeneratedStaging(root: self, name: name)
        }

        /// Publishes a staged tree but keeps any displaced tree under the same staging name until the whole workspace
        /// transaction commits. Both sides of the rename are authenticated before and after the mutation: a writer
        /// that does not honor WorkspaceLock can therefore make the transaction fail, but cannot have its replacement
        /// silently deleted as transaction staging.
        func publish(_ name: String, from staging: GeneratedStaging) throws -> GeneratedMutation {
            try verifyIdentity()
            try staging.verifyIdentity()
            try Self.requireComponent(name)
            try staging.validateTree(named: name)
            guard let prepared = try Self.mutationToken(named: name, in: staging.descriptor) else {
                throw SwiftPodsError("Staged generated path disappeared before publication: \(name)")
            }
            let existing = try Self.mutationToken(named: name, in: descriptor)
            let result: Int32 = name.withCString { source in
                name.withCString { destination in
                    if existing == nil {
                        return renameatx_np(staging.descriptor, source, descriptor, destination, UInt32(RENAME_EXCL))
                    }
                    return renameatx_np(staging.descriptor, source, descriptor, destination, UInt32(RENAME_SWAP))
                }
            }
            guard result == 0 else {
                throw SwiftPodsError("Cannot replace generated path \(name): \(String(cString: strerror(errno)))")
            }
            mutationHook?(.afterPublish(name))
            let installed: GeneratedEntryToken?
            let displaced: GeneratedEntryToken?
            do {
                installed = try Self.mutationToken(named: name, in: descriptor)
                displaced = try Self.mutationToken(named: name, in: staging.descriptor)
            } catch {
                staging.preserveEvidence()
                throw SwiftPodsError(
                    "Generated path changed immediately after publication; transaction evidence was preserved: \(name)")
            }
            guard Self.representsAfterRename(installed, previous: prepared),
                Self.representsAfterRename(displaced, previous: existing)
            else {
                // A swap can be reversed without dropping either post-swap object when the expected displaced tree is
                // still present. If either side moves again, leave both namespaces untouched for manual recovery.
                if let existing, let displaced, displaced.representsAfterRename(existing), let installed {
                    let rootCAS = try? Self.mutationToken(named: name, in: descriptor)
                    let stagingCAS = try? Self.mutationToken(named: name, in: staging.descriptor)
                    if rootCAS == installed, stagingCAS == existing,
                        name.withCString({ rootName in
                            name.withCString { stagingName in
                                renameatx_np(
                                    descriptor, rootName, staging.descriptor, stagingName, UInt32(RENAME_SWAP))
                            }
                        }) == 0,
                        (try? Self.mutationToken(named: name, in: descriptor))?
                            .representsAfterRename(existing) == true,
                        (try? Self.mutationToken(named: name, in: staging.descriptor))?
                            .representsAfterRename(installed) == true
                    {
                        staging.preserveEvidence()
                        throw SwiftPodsError(
                            "Generated publication raced with another writer; the old tree was restored and concurrent data was preserved in transaction staging: \(name)")
                    }
                }
                staging.preserveEvidence()
                throw SwiftPodsError(
                    "Generated publication raced with another writer; refusing to remove the preserved transaction evidence: \(name)")
            }
            guard let installed else {
                staging.preserveEvidence()
                throw SwiftPodsError("Published generated path disappeared: \(name)")
            }
            staging.replaceOwned(name, with: displaced)
            return .published(name: name, installed: installed, displaced: displaced)
        }

        /// Moves an obsolete tree into transaction staging instead of deleting it, so a later failure can restore it.
        func withdraw(_ name: String, to staging: GeneratedStaging) throws -> GeneratedMutation? {
            try verifyIdentity()
            try staging.verifyIdentity()
            try Self.requireComponent(name)
            guard let existing = try Self.mutationToken(named: name, in: descriptor) else { return nil }
            guard try Self.mutationToken(named: name, in: staging.descriptor) == nil else {
                throw SwiftPodsError("Transaction staging already contains generated path \(name)")
            }
            let result = name.withCString { source in
                name.withCString { destination in
                    renameatx_np(descriptor, source, staging.descriptor, destination, UInt32(RENAME_EXCL))
                }
            }
            guard result == 0 else {
                throw SwiftPodsError("Cannot stage obsolete generated path \(name): \(String(cString: strerror(errno)))")
            }
            mutationHook?(.afterWithdraw(name))
            let root = try? Self.mutationToken(named: name, in: descriptor)
            let displaced = try? Self.mutationToken(named: name, in: staging.descriptor)
            guard root == nil, displaced?.representsAfterRename(existing) == true else {
                staging.preserveEvidence()
                throw SwiftPodsError(
                    "Generated withdrawal raced with another writer; transaction evidence was preserved: \(name)")
            }
            guard let displaced else {
                staging.preserveEvidence()
                throw SwiftPodsError("Withdrawn generated path disappeared: \(name)")
            }
            staging.replaceOwned(name, with: displaced)
            return .withdrawn(name: name, displaced: displaced)
        }

        func rollbackPublished(
            _ name: String, installed: GeneratedEntryToken, displaced: GeneratedEntryToken?,
            staging: GeneratedStaging
        ) throws {
            try verifyIdentity()
            try staging.verifyIdentity()
            try Self.requireComponent(name)
            guard try Self.mutationToken(named: name, in: descriptor) == installed,
                try Self.mutationToken(named: name, in: staging.descriptor) == displaced
            else {
                staging.preserveEvidence()
                throw SwiftPodsError(
                    "Generated path changed after publication; refusing to overwrite a concurrent replacement: \(name)")
            }
            let result: Int32 = name.withCString { rootName in
                name.withCString { stagingName in
                    if displaced != nil {
                        return renameatx_np(
                            descriptor, rootName, staging.descriptor, stagingName, UInt32(RENAME_SWAP))
                    }
                    return renameatx_np(
                        descriptor, rootName, staging.descriptor, stagingName, UInt32(RENAME_EXCL))
                }
            }
            guard result == 0 else {
                throw SwiftPodsError("Cannot roll back generated path \(name): \(String(cString: strerror(errno)))")
            }
            mutationHook?(.afterRollbackPublished(name))
            let restored = try? Self.mutationToken(named: name, in: descriptor)
            let removed = try? Self.mutationToken(named: name, in: staging.descriptor)
            guard Self.representsAfterRename(restored, previous: displaced),
                Self.representsAfterRename(removed, previous: installed)
            else {
                // For a swap rollback, putting the exact installed tree back at the root is a safe inverse and keeps
                // the raced object in staging. Never guess when the staging side is no longer our installed tree.
                if displaced != nil, removed == installed, let restored,
                    (try? Self.mutationToken(named: name, in: descriptor)) == restored,
                    (try? Self.mutationToken(named: name, in: staging.descriptor)) == installed,
                    name.withCString({ rootName in
                        name.withCString { stagingName in
                            renameatx_np(
                                descriptor, rootName, staging.descriptor, stagingName, UInt32(RENAME_SWAP))
                        }
                    }) == 0,
                    (try? Self.mutationToken(named: name, in: descriptor))?
                        .representsAfterRename(installed) == true,
                    (try? Self.mutationToken(named: name, in: staging.descriptor))?
                        .representsAfterRename(restored) == true
                {
                    staging.preserveEvidence()
                    throw SwiftPodsError(
                        "Generated rollback raced with another writer; the installed tree and concurrent evidence were preserved: \(name)")
                }
                staging.preserveEvidence()
                throw SwiftPodsError(
                    "Generated rollback raced with another writer; transaction evidence was preserved: \(name)")
            }
            guard let removed else {
                staging.preserveEvidence()
                throw SwiftPodsError("Rolled-back generated path disappeared from staging: \(name)")
            }
            staging.replaceOwned(name, with: removed)
        }

        func rollbackWithdrawn(
            _ name: String, displaced: GeneratedEntryToken, staging: GeneratedStaging
        ) throws {
            try verifyIdentity()
            try staging.verifyIdentity()
            try Self.requireComponent(name)
            guard try Self.mutationToken(named: name, in: descriptor) == nil,
                try Self.mutationToken(named: name, in: staging.descriptor) == displaced
            else {
                staging.preserveEvidence()
                throw SwiftPodsError(
                    "Generated path changed after withdrawal; refusing to overwrite a concurrent replacement: \(name)")
            }
            let result = name.withCString { stagingName in
                name.withCString { rootName in
                    renameatx_np(staging.descriptor, stagingName, descriptor, rootName, UInt32(RENAME_EXCL))
                }
            }
            guard result == 0 else {
                throw SwiftPodsError("Cannot restore generated path \(name): \(String(cString: strerror(errno)))")
            }
            mutationHook?(.afterRollbackWithdrawn(name))
            guard (try? Self.mutationToken(named: name, in: descriptor))?
                .representsAfterRename(displaced) == true,
                (try? Self.mutationToken(named: name, in: staging.descriptor)) == nil
            else {
                staging.preserveEvidence()
                throw SwiftPodsError(
                    "Generated withdrawal rollback raced with another writer; transaction evidence was preserved: \(name)")
            }
            staging.replaceOwned(name, with: nil)
        }

        func verifyCommitted(_ mutation: GeneratedMutation, staging: GeneratedStaging) throws {
            try verifyIdentity()
            try staging.verifyIdentity()
            switch mutation {
            case .published(let name, let installed, let displaced):
                guard try Self.mutationToken(named: name, in: descriptor) == installed,
                    try Self.mutationToken(named: name, in: staging.descriptor) == displaced
                else {
                    staging.preserveEvidence()
                    throw SwiftPodsError("Generated path changed before transaction commit: \(name)")
                }
            case .withdrawn(let name, let displaced):
                guard try Self.mutationToken(named: name, in: descriptor) == nil,
                    try Self.mutationToken(named: name, in: staging.descriptor) == displaced
                else {
                    staging.preserveEvidence()
                    throw SwiftPodsError("Withdrawn generated path changed before transaction commit: \(name)")
                }
            }
        }

        func remove(_ name: String) throws {
            try verifyIdentity()
            try Self.remove(name, from: descriptor)
        }

        func removeManagedChildren() throws {
            try verifyIdentity()
            let fixed = Set([
                BinaryPackage.directoryName, DependencyPackage.directoryName, TargetScripts.directoryName, "Settings",
            ])
            for child in try Self.names(in: descriptor) {
                if fixed.contains(child) || Self.isManagedStaging(child, in: descriptor) {
                    try Self.remove(child, from: descriptor)
                }
            }
        }

        private static func isManagedStaging(_ name: String, in parent: Int32) -> Bool {
            let prefix = ".staging-"
            guard name.hasPrefix(prefix) else { return false }
            let suffix = String(name.dropFirst(prefix.count))
            guard let identifier = UUID(uuidString: suffix), identifier.uuidString == suffix else { return false }
            let directory = name.withCString {
                openat(parent, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            }
            guard directory >= 0 else { return false }
            defer { close(directory) }
            do {
                try validateOwnedDescriptor(directory, privateDirectory: true, kind: "Generated staging directory")
                let marker = Installer.stagingOwnershipFile.withCString {
                    openat(directory, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
                }
                guard marker >= 0 else { return false }
                defer { close(marker) }
                try validateOwnedDescriptor(marker, privateDirectory: false, kind: "Generated staging marker")
                return try readText(
                    marker, maximumBytes: 128, kind: "Generated staging marker") == Installer.stagingOwnership
            } catch {
                return false
            }
        }

        func validateManagedChildren() throws {
            try verifyIdentity()
            var textBudget = ValidationBudget()
            for child in [DependencyPackage.directoryName, TargetScripts.directoryName, "Settings"] {
                try Self.validateTree(
                    named: child, in: descriptor, diagnosticRoot: url, allowSymbolicLinks: false,
                    maximumEntries: Installer.maximumGeneratedEntries, countsTextBytes: true,
                    skippedTopLevelNames: GeneratedPackageMetadata.isPackage(child)
                        ? GeneratedPackageMetadata.directories : [], budget: &textBudget)
            }
            var binaryBudget = ValidationBudget()
            try Self.validateTree(
                named: BinaryPackage.directoryName, in: descriptor, diagnosticRoot: url, allowSymbolicLinks: true,
                maximumEntries: Installer.maximumGeneratedBinaryEntries, countsTextBytes: false,
                skippedTopLevelNames: GeneratedPackageMetadata.directories, budget: &binaryBudget)
        }

        func removeRootIfEmpty(removingMarker: Bool) throws {
            try verifyIdentity()
            var children = try Self.names(in: descriptor)
            if removingMarker, children == [Installer.ownershipFile] {
                try Self.remove(Installer.ownershipFile, from: descriptor)
                children.removeAll()
            }
            guard children.isEmpty else { return }
            guard name.withCString({ unlinkat(parentDescriptor, $0, AT_REMOVEDIR) }) == 0 else {
                throw SwiftPodsError("Cannot remove empty generated directory: \(String(cString: strerror(errno)))")
            }
        }

        fileprivate static func status(named name: String, in descriptor: Int32) throws -> stat? {
            try requireComponent(name)
            var value = stat()
            if name.withCString({ fstatat(descriptor, $0, &value, AT_SYMLINK_NOFOLLOW) }) == 0 { return value }
            if errno == ENOENT { return nil }
            throw SwiftPodsError("Cannot inspect generated entry \(name): \(String(cString: strerror(errno)))")
        }

        fileprivate static func names(
            in descriptor: Int32, maximumCount: Int = Installer.maximumGeneratedBinaryEntries + 1
        ) throws -> [String] {
            try Installer.boundedDirectoryNames(
                in: descriptor, maximumCount: maximumCount, kind: "generated directory")
        }

        fileprivate static func remove(_ name: String, from parent: Int32) throws {
            guard let status = try status(named: name, in: parent) else { return }
            if status.st_mode & S_IFMT == S_IFDIR {
                let child = name.withCString {
                    openat(parent, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
                }
                guard child >= 0 else {
                    throw SwiftPodsError("Cannot safely open generated directory \(name): \(String(cString: strerror(errno)))")
                }
                do {
                    for nested in try names(in: child) { try remove(nested, from: child) }
                    close(child)
                } catch {
                    close(child)
                    throw error
                }
                guard name.withCString({ unlinkat(parent, $0, AT_REMOVEDIR) }) == 0 else {
                    throw SwiftPodsError("Cannot remove generated directory \(name): \(String(cString: strerror(errno)))")
                }
            } else {
                // unlinkat removes a link itself and never follows its target.
                guard name.withCString({ unlinkat(parent, $0, 0) }) == 0 else {
                    throw SwiftPodsError("Cannot remove generated entry \(name): \(String(cString: strerror(errno)))")
                }
            }
        }

        fileprivate static func writeExclusive(_ data: Data, named path: String, in base: Int32) throws {
            guard Installer.isSafeGeneratedPath(path) else { throw SwiftPodsError("Refusing unsafe generated path: \(path)") }
            let components = path.split(separator: "/").map(String.init)
            let parent = try openDirectory(Array(components.dropLast()), from: base, create: true)
            defer { close(parent) }
            let leaf = components.last!
            let file = leaf.withCString {
                openat(parent, $0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
            }
            guard file >= 0 else {
                throw SwiftPodsError("Cannot create generated file \(path): \(String(cString: strerror(errno)))")
            }
            do {
                try secureCreatedDescriptor(file, mode: 0o600, kind: "Generated file \(path)")
            } catch {
                close(file)
                throw error
            }
            let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
            do {
                try handle.write(contentsOf: data)
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
        }

        fileprivate static func openDirectory(_ components: [String], from base: Int32, create: Bool) throws -> Int32 {
            var current = duplicateCloseOnExec(base)
            guard current >= 0 else { throw SwiftPodsError("Cannot duplicate generated directory descriptor") }
            do {
                for component in components {
                    try requireComponent(component)
                    if create, component.withCString({ mkdirat(current, $0, 0o755) }) != 0, errno != EEXIST {
                        throw SwiftPodsError("Cannot create generated directory \(component): \(String(cString: strerror(errno)))")
                    }
                    let next = component.withCString {
                        openat(current, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
                    }
                    guard next >= 0 else {
                        throw SwiftPodsError("Cannot safely open generated directory \(component): \(String(cString: strerror(errno)))")
                    }
                    try secureCreatedDescriptor(next, mode: 0o755, kind: "Generated directory \(component)")
                    close(current)
                    current = next
                }
                return current
            } catch {
                close(current)
                throw error
            }
        }

        fileprivate static func readText(_ descriptor: Int32, maximumBytes: Int, kind: String) throws -> String {
            var status = stat()
            guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
                status.st_size >= 0, status.st_size <= maximumBytes
            else { throw SwiftPodsError("\(kind) must be a regular file no larger than \(maximumBytes) bytes") }
            let copy = duplicateCloseOnExec(descriptor)
            guard copy >= 0 else { throw SwiftPodsError("Cannot duplicate \(kind.lowercased()) descriptor") }
            let handle = FileHandle(fileDescriptor: copy, closeOnDealloc: true)
            defer { try? handle.close() }
            var data = Data()
            while let chunk = try handle.read(upToCount: min(1 << 20, maximumBytes + 1 - data.count)), !chunk.isEmpty {
                data.append(chunk)
                guard data.count <= maximumBytes else { throw SwiftPodsError("\(kind) exceeds the \(maximumBytes)-byte limit") }
            }
            var finalStatus = stat()
            guard fstat(descriptor, &finalStatus) == 0,
                finalStatus.st_dev == status.st_dev, finalStatus.st_ino == status.st_ino,
                finalStatus.st_mode == status.st_mode, finalStatus.st_nlink == status.st_nlink,
                finalStatus.st_size == status.st_size,
                finalStatus.st_mtimespec.tv_sec == status.st_mtimespec.tv_sec,
                finalStatus.st_mtimespec.tv_nsec == status.st_mtimespec.tv_nsec,
                finalStatus.st_ctimespec.tv_sec == status.st_ctimespec.tv_sec,
                finalStatus.st_ctimespec.tv_nsec == status.st_ctimespec.tv_nsec,
                data.count == Int(status.st_size)
            else { throw SwiftPodsError("\(kind) changed while it was being read") }
            guard let text = String(data: data, encoding: .utf8) else { throw SwiftPodsError("\(kind) must be valid UTF-8") }
            return text
        }

        fileprivate static func requireComponent(_ name: String) throws {
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"),
                !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            else { throw SwiftPodsError("Refusing unsafe generated path component: \(name)") }
        }

        fileprivate struct ValidationBudget {
            var entries = 0
            var textBytes: Int64 = 0
        }

        fileprivate static func secureCreatedDescriptor(_ descriptor: Int32, mode: mode_t, kind: String) throws {
            guard fchmod(descriptor, mode) == 0 else {
                throw SwiftPodsError("Cannot secure \(kind.lowercased()) permissions")
            }
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
            try validateOwnedDescriptor(
                descriptor, privateDirectory: mode & 0o077 == 0 && mode & S_IFMT == 0, kind: kind)
        }

        fileprivate static func validateOwnedDescriptor(
            _ descriptor: Int32, privateDirectory: Bool, kind: String
        ) throws {
            var status = stat()
            guard fstat(descriptor, &status) == 0,
                status.st_uid == geteuid(),
                status.st_mode & 0o022 == 0,
                !privateDirectory || status.st_mode & 0o077 == 0
            else {
                throw SwiftPodsError("\(kind) must be owned by the current user and not writable by group or others")
            }
            guard try !hasExtendedACL(descriptor, kind: kind) else {
                throw SwiftPodsError("\(kind) has an extended ACL and cannot be used safely")
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

        fileprivate static func validateTree(
            named name: String, in parent: Int32, diagnosticRoot: URL, allowSymbolicLinks: Bool,
            maximumEntries: Int, countsTextBytes: Bool, skippedTopLevelNames: Set<String> = [],
            budget: inout ValidationBudget
        ) throws {
            guard let status = try status(named: name, in: parent) else { return }
            guard status.st_mode & S_IFMT == S_IFDIR else {
                throw SwiftPodsError("Managed generated path is not a directory: \(diagnosticRoot.appendingPathComponent(name).path)")
            }
            let descriptor = name.withCString {
                openat(parent, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            }
            guard descriptor >= 0 else {
                throw SwiftPodsError("Cannot safely open managed generated directory \(name)")
            }
            defer { close(descriptor) }
            var opened = stat()
            guard fstat(descriptor, &opened) == 0,
                opened.st_dev == status.st_dev, opened.st_ino == status.st_ino,
                opened.st_mode & S_IFMT == S_IFDIR
            else { throw SwiftPodsError("Managed generated directory changed while it was opened: \(name)") }
            try validateOwnedDescriptor(descriptor, privateDirectory: false, kind: "Managed generated directory \(name)")
            try validateChildren(
                in: descriptor, relative: name, diagnosticRoot: diagnosticRoot,
                allowSymbolicLinks: allowSymbolicLinks, maximumEntries: maximumEntries,
                countsTextBytes: countsTextBytes, skippedTopLevelNames: skippedTopLevelNames,
                depth: 1, budget: &budget)
        }

        private static func validateChildren(
            in parent: Int32, relative: String, diagnosticRoot: URL, allowSymbolicLinks: Bool,
            maximumEntries: Int, countsTextBytes: Bool, skippedTopLevelNames: Set<String>,
            depth: Int, budget: inout ValidationBudget
        ) throws {
            let remaining = maximumEntries - budget.entries
            let enumerationLimit = remaining + (depth == 1 ? skippedTopLevelNames.count : 0)
            for child in try names(in: parent, maximumCount: enumerationLimit) {
                try requireComponent(child)
                if depth == 1, skippedTopLevelNames.contains(child) {
                    guard let entry = try status(named: child, in: parent), entry.st_mode & S_IFMT == S_IFDIR,
                        entry.st_uid == geteuid()
                    else { throw SwiftPodsError("Resolver metadata root must be an owned real directory: \(child)") }
                    continue
                }
                guard depth < Installer.maximumGeneratedDepth else {
                    throw SwiftPodsError("Generated path is nested too deeply: \(relative)/\(child)")
                }
                guard let status = try status(named: child, in: parent) else {
                    throw SwiftPodsError("Generated path disappeared while it was inspected: \(relative)/\(child)")
                }
                budget.entries += 1
                guard budget.entries <= maximumEntries else {
                    throw SwiftPodsError("Generated directory contains more than \(maximumEntries) managed entries")
                }
                let path = relative + "/" + child
                switch status.st_mode & S_IFMT {
                case S_IFDIR:
                    let descriptor = child.withCString {
                        openat(parent, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
                    }
                    guard descriptor >= 0 else {
                        throw SwiftPodsError("Cannot safely open generated directory \(path)")
                    }
                    do {
                        var opened = stat()
                        guard fstat(descriptor, &opened) == 0,
                            opened.st_dev == status.st_dev, opened.st_ino == status.st_ino,
                            opened.st_mode & S_IFMT == S_IFDIR
                        else { throw SwiftPodsError("Generated directory changed while it was opened: \(path)") }
                        try validateOwnedDescriptor(
                            descriptor, privateDirectory: false, kind: "Managed generated directory \(path)")
                        try validateChildren(
                            in: descriptor, relative: path, diagnosticRoot: diagnosticRoot,
                            allowSymbolicLinks: allowSymbolicLinks, maximumEntries: maximumEntries,
                            countsTextBytes: countsTextBytes, skippedTopLevelNames: [], depth: depth + 1,
                            budget: &budget)
                        close(descriptor)
                    } catch {
                        close(descriptor)
                        throw error
                    }
                case S_IFREG:
                    let descriptor = child.withCString {
                        openat(parent, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
                    }
                    guard descriptor >= 0 else { throw SwiftPodsError("Cannot safely open generated file \(path)") }
                    do {
                        var opened = stat()
                        guard fstat(descriptor, &opened) == 0,
                            opened.st_dev == status.st_dev, opened.st_ino == status.st_ino,
                            opened.st_mode & S_IFMT == S_IFREG
                        else { throw SwiftPodsError("Generated file changed while it was opened: \(path)") }
                        try validateOwnedDescriptor(
                            descriptor, privateDirectory: false, kind: "Managed generated file \(path)")
                        if countsTextBytes {
                            guard opened.st_size >= 0, opened.st_size <= Installer.maximumGeneratedFileBytes else {
                                throw SwiftPodsError(
                                    "Generated file \(path) exceeds \(Installer.maximumGeneratedFileBytes) bytes")
                            }
                            guard opened.st_size <= Int64(Installer.maximumGeneratedTextBytes) - budget.textBytes else {
                                throw SwiftPodsError("Generated files exceed the 128 MiB aggregate limit")
                            }
                            budget.textBytes += opened.st_size
                        }
                        close(descriptor)
                    } catch {
                        close(descriptor)
                        throw error
                    }
                case S_IFLNK where allowSymbolicLinks:
                    guard status.st_uid == geteuid() else {
                        throw SwiftPodsError("Managed generated symbolic link is not owned by the current user: \(path)")
                    }
                default:
                    throw SwiftPodsError("Refusing symbolic link or special file inside the generated directory: \(path)")
                }
            }
        }
    }

    private final class GeneratedStaging {
        let root: GeneratedRoot
        let name: String
        let descriptor: Int32
        private let identity: (device: dev_t, inode: ino_t)
        private var preservesEvidence = false
        private var owned: [String: GeneratedEntryToken] = [:]

        init(root: GeneratedRoot, name: String) throws {
            self.root = root
            self.name = name
            descriptor = name.withCString {
                openat(root.descriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            }
            guard descriptor >= 0 else { throw SwiftPodsError("Cannot open generated staging directory") }
            do {
                try GeneratedRoot.secureCreatedDescriptor(descriptor, mode: 0o700, kind: "Generated staging directory")
            } catch {
                close(descriptor)
                throw error
            }
            var status = stat()
            guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFDIR,
                status.st_uid == geteuid(), status.st_mode & 0o077 == 0
            else {
                close(descriptor)
                throw SwiftPodsError("Generated staging directory is not private")
            }
            identity = (status.st_dev, status.st_ino)
            do {
                try GeneratedRoot.writeExclusive(
                    Data(Installer.stagingOwnership.utf8), named: Installer.stagingOwnershipFile, in: descriptor)
                guard let marker = try GeneratedRoot.mutationToken(
                    named: Installer.stagingOwnershipFile, in: descriptor)
                else { throw SwiftPodsError("Generated staging marker disappeared after creation") }
                owned[Installer.stagingOwnershipFile] = marker
            } catch {
                close(descriptor)
                // Do not recursively normalize a staging path that failed authentication: a same-UID writer may
                // already have placed unrelated data there. A marked orphan is safer than deleting unknown data.
                throw error
            }
        }

        deinit { close(descriptor) }

        func verifyIdentity() throws {
            try root.verifyIdentity()
            var opened = stat()
            guard fstat(descriptor, &opened) == 0,
                let linked = try GeneratedRoot.status(named: name, in: root.descriptor),
                opened.st_mode & S_IFMT == S_IFDIR, linked.st_mode & S_IFMT == S_IFDIR,
                opened.st_dev == identity.device, opened.st_ino == identity.inode,
                linked.st_dev == identity.device, linked.st_ino == identity.inode
            else { throw SwiftPodsError("Generated staging directory changed while it was being used") }
            try GeneratedRoot.validateOwnedDescriptor(
                descriptor, privateDirectory: true, kind: "Generated staging directory")
        }

        func validateTree(named name: String) throws {
            var budget = GeneratedRoot.ValidationBudget()
            try GeneratedRoot.validateTree(
                named: name, in: descriptor, diagnosticRoot: root.url.appendingPathComponent(self.name),
                allowSymbolicLinks: name == BinaryPackage.directoryName,
                maximumEntries: name == BinaryPackage.directoryName
                    ? Installer.maximumGeneratedBinaryEntries : Installer.maximumGeneratedEntries,
                countsTextBytes: name != BinaryPackage.directoryName,
                skippedTopLevelNames: GeneratedPackageMetadata.isPackage(name)
                    ? GeneratedPackageMetadata.directories : [],
                budget: &budget)
        }

        func preserveEvidence() {
            preservesEvidence = true
        }

        func replaceOwned(_ name: String, with token: GeneratedEntryToken?) {
            owned[name] = token
        }

        func writeTree(named name: String, files: [(String, Data)]) throws {
            try verifyIdentity()
            try GeneratedRoot.requireComponent(name)
            guard name.withCString({ mkdirat(descriptor, $0, 0o755) }) == 0 else {
                throw SwiftPodsError("Cannot create staged generated tree \(name): \(String(cString: strerror(errno)))")
            }
            let tree = name.withCString {
                openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            }
            guard tree >= 0 else { throw SwiftPodsError("Cannot open staged generated tree \(name)") }
            defer { close(tree) }
            do {
                try GeneratedRoot.secureCreatedDescriptor(tree, mode: 0o755, kind: "Staged generated tree \(name)")
                for (relative, data) in files { try GeneratedRoot.writeExclusive(data, named: relative, in: tree) }
                guard let token = try GeneratedRoot.mutationToken(named: name, in: descriptor) else {
                    throw SwiftPodsError("Staged generated tree disappeared after creation: \(name)")
                }
                owned[name] = token
            } catch {
                let writeFailure = error
                do {
                    if let partial = try GeneratedRoot.mutationToken(named: name, in: descriptor) {
                        owned[name] = partial
                    } else {
                        preservesEvidence = true
                    }
                } catch {
                    preservesEvidence = true
                }
                throw writeFailure
            }
        }

        func copyTree(from source: URL, named name: String) throws {
            try verifyIdentity()
            try GeneratedRoot.requireComponent(name)
            do {
                try Self.copyDirectory(source, named: name, into: descriptor)
                guard let token = try GeneratedRoot.mutationToken(named: name, in: descriptor) else {
                    throw SwiftPodsError("Copied generated tree disappeared after creation: \(name)")
                }
                owned[name] = token
            } catch {
                let copyFailure = error
                do {
                    if let partial = try GeneratedRoot.mutationToken(named: name, in: descriptor) {
                        owned[name] = partial
                    } else {
                        preservesEvidence = true
                    }
                } catch {
                    preservesEvidence = true
                }
                throw copyFailure
            }
        }

        func cleanup() throws {
            guard !preservesEvidence else {
                throw SwiftPodsError("Generated transaction staging contains preserved concurrent-write evidence")
            }
            do {
                try verifyIdentity()
                try verifyOwnedContents()
                root.invokeMutationHook(.afterStagingCleanupVerification)
                // The hook models a writer entering after the commit-time check. Repeating the exact manifest check
                // is also useful in production, where cleanup must not trust an earlier verification.
                try verifyIdentity()
                try verifyOwnedContents()

                let marker = Installer.stagingOwnershipFile
                var removalOrder = owned.keys.filter { $0 != marker }.sorted()
                if owned[marker] != nil { removalOrder.append(marker) }
                for entry in removalOrder {
                    guard let token = owned[entry] else {
                        throw SwiftPodsError("Generated staging ownership changed during cleanup")
                    }
                    try removeOwned(entry, expected: token)
                    owned.removeValue(forKey: entry)
                    try verifyOwnedContents()
                }
                guard try GeneratedRoot.names(in: descriptor).isEmpty else {
                    throw SwiftPodsError("Generated transaction staging gained an unknown entry during cleanup")
                }
                try verifyIdentity()
                guard name.withCString({ unlinkat(root.descriptor, $0, AT_REMOVEDIR) }) == 0 else {
                    throw SwiftPodsError(
                        "Cannot remove the empty generated staging directory: \(String(cString: strerror(errno)))")
                }
            } catch {
                preservesEvidence = true
                throw error
            }
        }

        private func verifyOwnedContents() throws {
            let actual = try GeneratedRoot.names(in: descriptor)
            guard Set(actual) == Set(owned.keys) else {
                throw SwiftPodsError("Generated transaction staging contains an unknown or missing entry")
            }
            for entry in owned.keys.sorted() {
                guard try GeneratedRoot.mutationToken(named: entry, in: descriptor) == owned[entry] else {
                    throw SwiftPodsError("Generated transaction staging entry changed before cleanup: \(entry)")
                }
            }
        }

        /// Moves an owned entry to an unpredictable name and authenticates what actually moved before unlinking it.
        /// Recursive deletion below follows the captured manifest only; an unexpected child is never enumerated into
        /// the deletion set and instead makes the final directory removal fail with evidence preserved.
        private func removeOwned(_ entry: String, expected: GeneratedEntryToken) throws {
            let quarantine = ".cleanup-" + UUID().uuidString
            let renamed = entry.withCString { source in
                quarantine.withCString { destination in
                    renameatx_np(descriptor, source, descriptor, destination, UInt32(RENAME_EXCL))
                }
            }
            guard renamed == 0 else {
                throw SwiftPodsError(
                    "Cannot quarantine generated staging entry \(entry): \(String(cString: strerror(errno)))")
            }
            let package = GeneratedPackageMetadata.isPackage(entry)
            guard let moved = try GeneratedRoot.mutationToken(
                named: quarantine, in: descriptor, package: package),
                moved.representsAfterRename(expected)
            else {
                throw SwiftPodsError("Generated staging entry changed while it was quarantined: \(entry)")
            }
            try removeManifestEntry(
                named: quarantine, relative: "", expected: moved.entry, manifest: moved.members,
                package: package, in: descriptor)
            guard try GeneratedRoot.status(named: quarantine, in: descriptor) == nil else {
                throw SwiftPodsError("Quarantined generated staging entry was replaced during cleanup: \(entry)")
            }
        }

        private func removeManifestEntry(
            named name: String, relative: String, expected: TransactionFileSnapshot.EntryState,
            manifest: [String: TransactionFileSnapshot.EntryState], package: Bool, in parent: Int32
        ) throws {
            guard let status = try GeneratedRoot.status(named: name, in: parent),
                TransactionFileSnapshot.EntryState(status) == expected
            else { throw SwiftPodsError("Generated staging entry changed before unlink: \(name)") }

            if status.st_mode & S_IFMT != S_IFDIR {
                guard name.withCString({ unlinkat(parent, $0, 0) }) == 0 else {
                    throw SwiftPodsError(
                        "Cannot remove quarantined generated entry \(name): \(String(cString: strerror(errno)))")
                }
                return
            }

            let directory = name.withCString {
                openat(parent, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            }
            guard directory >= 0 else {
                throw SwiftPodsError("Cannot safely open quarantined generated directory \(name)")
            }
            defer { close(directory) }
            var opened = stat()
            guard fstat(directory, &opened) == 0,
                TransactionFileSnapshot.EntryState(opened) == expected
            else { throw SwiftPodsError("Quarantined generated directory changed while it was opened: \(name)") }
            if package, GeneratedPackageMetadata.contains(relative) {
                guard opened.st_uid == geteuid() else {
                    throw SwiftPodsError("Resolver metadata directory is not owned by the current user: \(name)")
                }
            } else {
                try GeneratedRoot.validateOwnedDescriptor(
                    directory, privateDirectory: false, kind: "Quarantined generated directory \(name)")
            }

            let prefix = relative.isEmpty ? "" : relative + "/"
            let children = manifest.keys.compactMap { path -> String? in
                guard path != relative, path.hasPrefix(prefix) else { return nil }
                let suffix = String(path.dropFirst(prefix.count))
                return !suffix.isEmpty && !suffix.contains("/") ? suffix : nil
            }.sorted()
            guard Set(try GeneratedRoot.names(in: directory)) == Set(children) else {
                throw SwiftPodsError("Quarantined generated directory contains an unknown or missing child: \(name)")
            }
            for child in children {
                let childRelative = relative.isEmpty ? child : relative + "/" + child
                guard let childExpected = manifest[childRelative] else {
                    throw SwiftPodsError("Generated staging manifest is incomplete: \(childRelative)")
                }
                let quarantine = ".cleanup-" + UUID().uuidString
                let renamed = child.withCString { source in
                    quarantine.withCString { destination in
                        renameatx_np(directory, source, directory, destination, UInt32(RENAME_EXCL))
                    }
                }
                guard renamed == 0,
                    let moved = try GeneratedRoot.status(named: quarantine, in: directory),
                    TransactionFileSnapshot.EntryState(moved).representsAfterRename(childExpected)
                else {
                    throw SwiftPodsError("Generated staging child changed while it was quarantined: \(childRelative)")
                }
                try removeManifestEntry(
                    named: quarantine, relative: childRelative,
                    expected: TransactionFileSnapshot.EntryState(moved), manifest: manifest,
                    package: package, in: directory)
            }
            guard try GeneratedRoot.names(in: directory).isEmpty else {
                throw SwiftPodsError("Quarantined generated directory gained an unknown child: \(name)")
            }
            var final = stat()
            var linked = stat()
            guard fstat(directory, &final) == 0,
                name.withCString({ fstatat(parent, $0, &linked, AT_SYMLINK_NOFOLLOW) }) == 0,
                final.st_dev == expected.device, final.st_ino == expected.inode,
                linked.st_dev == expected.device, linked.st_ino == expected.inode,
                final.st_mode & S_IFMT == S_IFDIR, linked.st_mode & S_IFMT == S_IFDIR
            else { throw SwiftPodsError("Quarantined generated directory was replaced during cleanup: \(name)") }
            guard name.withCString({ unlinkat(parent, $0, AT_REMOVEDIR) }) == 0 else {
                throw SwiftPodsError(
                    "Cannot remove quarantined generated directory \(name): \(String(cString: strerror(errno)))")
            }
        }

        private static func copyDirectory(_ source: URL, named name: String, into parent: Int32) throws {
            var sourceStatus = stat()
            guard source.path.withCString({ lstat($0, &sourceStatus) }) == 0,
                sourceStatus.st_mode & S_IFMT == S_IFDIR,
                name.withCString({ mkdirat(parent, $0, 0o700) }) == 0
            else { throw SwiftPodsError("Cannot copy generated directory \(source.path)") }
            let destination = name.withCString {
                openat(parent, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            }
            guard destination >= 0 else { throw SwiftPodsError("Cannot open copied generated directory \(name)") }
            defer { close(destination) }
            for child in try FileManager.default.contentsOfDirectory(atPath: source.path).sorted() {
                try GeneratedRoot.requireComponent(child)
                let input = source.appendingPathComponent(child)
                var status = stat()
                guard input.path.withCString({ lstat($0, &status) }) == 0 else {
                    throw SwiftPodsError("Generated source changed while it was copied")
                }
                switch status.st_mode & S_IFMT {
                case S_IFDIR:
                    try copyDirectory(input, named: child, into: destination)
                case S_IFREG:
                    try copyFile(input, status: status, named: child, into: destination)
                case S_IFLNK:
                    let target = try FileManager.default.destinationOfSymbolicLink(atPath: input.path)
                    guard target.withCString({ link in child.withCString { symlinkat(link, destination, $0) } }) == 0 else {
                        throw SwiftPodsError("Cannot copy generated symbolic link \(child)")
                    }
                default:
                    throw SwiftPodsError("Refusing special file in generated source: \(input.path)")
                }
            }
            let safeMode = mode_t(sourceStatus.st_mode & 0o777 & ~mode_t(0o022))
            try GeneratedRoot.secureCreatedDescriptor(
                destination, mode: safeMode, kind: "Copied generated directory \(name)")
        }

        private static func copyFile(_ source: URL, status: stat, named name: String, into parent: Int32) throws {
            let input = source.path.withCString { open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK) }
            guard input >= 0 else { throw SwiftPodsError("Cannot safely copy generated file \(source.path)") }
            defer { close(input) }
            var opened = stat()
            guard fstat(input, &opened) == 0, opened.st_mode & S_IFMT == S_IFREG,
                opened.st_dev == status.st_dev, opened.st_ino == status.st_ino, opened.st_size == status.st_size
            else { throw SwiftPodsError("Generated source changed while it was copied") }
            let output = name.withCString {
                openat(parent, $0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
            }
            guard output >= 0 else { throw SwiftPodsError("Cannot create copied generated file \(name)") }
            defer { close(output) }
            let readerDescriptor = duplicateCloseOnExec(input)
            guard readerDescriptor >= 0 else {
                throw SwiftPodsError("Cannot duplicate generated source file descriptor")
            }
            let writerDescriptor = duplicateCloseOnExec(output)
            guard writerDescriptor >= 0 else {
                close(readerDescriptor)
                throw SwiftPodsError("Cannot duplicate generated destination file descriptor")
            }
            let reader = FileHandle(fileDescriptor: readerDescriptor, closeOnDealloc: true)
            let writer = FileHandle(fileDescriptor: writerDescriptor, closeOnDealloc: true)
            defer {
                try? writer.close()
                try? reader.close()
            }
            var copied: Int64 = 0
            while let data = try reader.read(upToCount: 1 << 20), !data.isEmpty {
                copied += Int64(data.count)
                guard copied <= status.st_size else { throw SwiftPodsError("Generated source grew while it was copied") }
                try writer.write(contentsOf: data)
            }
            try writer.synchronize()
            guard copied == status.st_size else {
                throw SwiftPodsError("Generated source changed while it was copied")
            }
            let safeMode = mode_t(status.st_mode & 0o777 & ~mode_t(0o022))
            try GeneratedRoot.secureCreatedDescriptor(output, mode: safeMode, kind: "Copied generated file \(name)")
        }
    }

    public init(
        directory: URL, project: URL? = nil, runner: CommandRunner = ProcessRunner(), cache: URL? = nil, sourcesCache: URL? = nil
    ) {
        self.directory = directory.standardizedFileURL
        self.project = project?.standardizedFileURL
        self.runner = runner
        self.cache = cache ?? BinaryStore.defaultCache
        self.sourcesCache = sourcesCache ?? GitCatalog.defaultCache
        generatedMutationHook = nil
        lockWriteHook = nil
    }

    init(
        directory: URL, project: URL? = nil, runner: CommandRunner = ProcessRunner(), cache: URL? = nil,
        sourcesCache: URL? = nil, generatedMutationHook: @escaping @Sendable (GeneratedMutationPoint) -> Void
    ) {
        self.directory = directory.standardizedFileURL
        self.project = project?.standardizedFileURL
        self.runner = runner
        self.cache = cache ?? BinaryStore.defaultCache
        self.sourcesCache = sourcesCache ?? GitCatalog.defaultCache
        self.generatedMutationHook = generatedMutationHook
        lockWriteHook = nil
    }

    init(
        directory: URL, project: URL? = nil, runner: CommandRunner = ProcessRunner(), cache: URL? = nil,
        sourcesCache: URL? = nil,
        generatedMutationHook: @escaping @Sendable (GeneratedMutationPoint) -> Void,
        lockWriteHook: @escaping @Sendable (LockWritePoint) throws -> Void
    ) {
        self.directory = directory.standardizedFileURL
        self.project = project?.standardizedFileURL
        self.runner = runner
        self.cache = cache ?? BinaryStore.defaultCache
        self.sourcesCache = sourcesCache ?? GitCatalog.defaultCache
        self.generatedMutationHook = generatedMutationHook
        self.lockWriteHook = lockWriteHook
    }

    private func catalog(
        update: Bool, offline: Bool, deploymentLock: SwiftPodsLock? = nil, requiresLock: Bool = false,
        lockProvider: (@Sendable () throws -> SwiftPodsLock?)? = nil
    ) -> GitCatalog {
        GitCatalog(
            cache: sourcesCache, runner: runner, update: update, offline: offline,
            deploymentLock: deploymentLock, requiresLock: requiresLock, lockProvider: lockProvider)
    }

    private var generated: URL { directory.appendingPathComponent(Self.generatedDirectory, isDirectory: true) }

    public func manifest(updateSources: Bool = false, offline: Bool = false) throws -> Manifest {
        let deferred = try SwiftPodsLock.deferredRead(
            at: directory.appendingPathComponent(SwiftPodsLock.fileName))
        let provider: @Sendable () throws -> SwiftPodsLock?
        if updateSources {
            provider = { nil }
        } else {
            provider = { try deferred.lock() }
        }
        return try manifest(using: catalog(update: updateSources, offline: offline, lockProvider: provider))
    }

    private func manifest(using catalog: GitCatalog) throws -> Manifest {
        let podfile = directory.appendingPathComponent("Podfile")
        guard FileManager.default.fileExists(atPath: podfile.path) else {
            throw SwiftPodsError("No Podfile in \(directory.path)")
        }
        let reader = ManifestReader(catalog: catalog)
        do { return try reader.load(podfile.path) } catch { throw SwiftPodsError.wrap(error) }
    }

    private static func verifyManifestFiles(_ manifest: Manifest) throws {
        do { try manifest.verifyFileSnapshots() } catch {
            throw SwiftPodsError(
                "Podfile or an included path changed after the manifest was read", file: manifest.file,
                hint: "Retry after the process modifying the manifest has finished")
        }
    }

    public func install(_ options: InstallOptions) throws -> InstallReport {
        do { return try performInstall(options) } catch { throw SwiftPodsError.wrap(error) }
    }

    private static func workspaceProjectNames(in descriptor: Int32) throws -> [String] {
        let projects = try boundedDirectoryNames(
            in: descriptor, maximumCount: maximumWorkspaceEntries, kind: "Podfile directory"
        ).filter { $0.hasSuffix(".xcodeproj") }
        guard projects.count <= maximumWorkspaceProjects else {
            throw SwiftPodsError(
                "The Podfile directory contains more than \(maximumWorkspaceProjects) Xcode projects")
        }
        return projects
    }

    private func defaultProject(in workspaceDescriptor: Int32) throws -> String {
        if let project {
            guard FileManager.default.fileExists(atPath: project.appendingPathComponent("project.pbxproj").path) else {
                throw SwiftPodsError("No Xcode project at \(project.path)")
            }
            return Paths.relative(from: directory, to: project)
        }
        let projects = try Self.workspaceProjectNames(in: workspaceDescriptor)
        guard projects.count == 1 else {
            throw SwiftPodsError(
                projects.isEmpty ? "No Xcode project next to the Podfile" : "Several Xcode projects next to the Podfile: " + projects.joined(separator: ", "),
                file: directory.appendingPathComponent("Podfile").path,
                hint: "Declare `project 'Path/To.xcodeproj'` or pass --project")
        }
        return projects[0]
    }

    /// Production resolution is descriptor-rooted: xcodebuild accepts `-project .`, and ProcessRunner changes the
    /// child directory with `posix_spawn_file_actions_addfchdir_np` before exec. A pathname rebind can therefore no
    /// longer redirect Xcode to another project. Injected runners must explicitly implement the same descriptor-backed
    /// capability; a path-only runner fails closed before Xcode or project state is changed.
    private func runPackageResolver(
        _ arguments: [String], project: XcodeProject, directory projectDirectory: RetainedProjectDirectory
    ) throws {
        try project.verifyDirectoryPathBinding()
        guard let descriptorRunner = runner as? any DescriptorWorkingDirectoryCommandRunner else {
            throw SwiftPodsError(
                "Command runner cannot safely resolve packages from an authenticated project directory",
                file: project.path.path,
                hint: "Use ProcessRunner or implement DescriptorWorkingDirectoryCommandRunner")
        }
        _ = try descriptorRunner.runDescriptorBacked(
            "/usr/bin/xcrun", arguments + ["-project", "."],
            workingDirectoryDescriptor: projectDirectory.descriptor,
            timeout: 30 * 60)
        try project.verifyDirectoryPathBinding()
    }

    private func performInstall(_ options: InstallOptions) throws -> InstallReport {
        let workspaceLock = try WorkspaceLock(directory: directory)
        defer { withExtendedLifetime(workspaceLock) {} }
        try InstallTransactionJournal.recover(
            directory: directory, workspaceDescriptor: workspaceLock.duplicateDirectoryDescriptor())
        try workspaceLock.verifyIdentity()
        let lockFile = directory.appendingPathComponent(SwiftPodsLock.fileName)
        let lockRead = try SwiftPodsLock.deferredRead(at: lockFile)
        // An ordinary install is reproducible by default: once a catalog revision has been recorded, keep using it.
        // Updating sources is the explicit opt-in that re-resolves an existing lock. Deployment is always frozen,
        // even if --update-sources was supplied accidentally.
        let honorsExistingLock = options.deployment || !options.updateSources
        let lockProvider: @Sendable () throws -> SwiftPodsLock?
        if honorsExistingLock {
            lockProvider = { try lockRead.lock() }
        } else {
            lockProvider = {
                // Ignore its semantics, but authenticate the original pathname before catalog I/O so the eventual
                // replacement is an exact compare-and-swap rather than an overwrite of a concurrent change.
                _ = try lockRead.replacementState()
                return nil
            }
        }
        let catalog = catalog(
            update: options.updateSources, offline: options.offline,
            requiresLock: options.deployment, lockProvider: lockProvider)
        let manifest = try manifest(using: catalog)
        try Self.verifyManifestFiles(manifest)
        let resolvedLock = SwiftPodsLock(resolutions: catalog.resolutions)
        let freshnessLockContents: Data?
        if resolvedLock.isEmpty {
            freshnessLockContents = nil
        } else if options.deployment {
            guard let contents = try lockRead.contents() else {
                throw SwiftPodsError("Deployment requires SwiftPods.lock", file: lockFile.path)
            }
            freshnessLockContents = contents
        } else {
            freshnessLockContents = try resolvedLock.data()
        }
        let existingLock: SwiftPodsLock?
        if resolvedLock.isEmpty || !honorsExistingLock {
            existingLock = nil
        } else {
            existingLock = try lockRead.lock()
        }
        if options.deployment, !resolvedLock.isEmpty, let existingLock {
            let problems = existingLock.problems(comparedTo: resolvedLock)
            if !problems.isEmpty {
                throw SwiftPodsError(
                    "SwiftPods.lock does not satisfy the Podfile:\n  " + problems.joined(separator: "\n  "), file: lockFile.path,
                    hint: "Review the changes and run `swiftpods install` without --deployment; add --update-sources only if catalog revisions must move")
            }
        }
        let projectWorkspaceDescriptor = try workspaceLock.duplicateDirectoryDescriptor()
        defer { close(projectWorkspaceDescriptor) }
        var defaultProjectPath: String?
        func selectedDefaultProject() throws -> String {
            if let defaultProjectPath { return defaultProjectPath }
            let path = try defaultProject(in: projectWorkspaceDescriptor)
            defaultProjectPath = path
            return path
        }
        var projectPaths: [String] = []
        var targetsByProject: [String: [Target]] = [:]
        for target in manifest.targets {
            let path = try target.project ?? selectedDefaultProject()
            if targetsByProject[path] == nil { projectPaths.append(path) }
            targetsByProject[path, default: []].append(target)
        }
        var projects: [String: XcodeProject] = [:]
        var projectIdentities: [String: String] = [:]
        let manifestProjectPaths = Set(manifest.targets.compactMap(\.project))
        for path in projectPaths {
            let url = directory.appendingPathComponent(path)
            try validateProject(url, mustBeContained: manifestProjectPaths.contains(path))
            let identity = try Self.fileIdentity(at: url)
            if let existing = projectIdentities[identity] {
                throw SwiftPodsError("Project paths \(existing) and \(path) refer to the same Xcode project")
            }
            projectIdentities[identity] = path
            if PackageLocation.isSafeRelativePath(path) {
                projects[path] = try XcodeProject(
                    path: url, relativePath: path,
                    relativeToDirectoryDescriptor: projectWorkspaceDescriptor)
            } else {
                // An explicit --project may intentionally name a project outside the Podfile directory.
                projects[path] = try XcodeProject(path: url)
            }
        }
        let projectDirectories = try Dictionary(uniqueKeysWithValues: projectPaths.map { path in
            (path, try RetainedProjectDirectory(projects[path]!))
        })
        // The journal borrows raw descriptors from these owners. Optimized builds can otherwise release them
        // after the final dictionary lookup, before descriptor-backed verification and rollback have finished.
        defer { withExtendedLifetime(projectDirectories) {} }
        let compileOnlyTargets = Dictionary(uniqueKeysWithValues: projectPaths.map { path in
            (path, Set(targetsByProject[path]!.filter { $0.products.contains { !$0.link } }.map(\.name)))
        })
        let packageModulesByTarget = Dictionary(uniqueKeysWithValues: projectPaths.map { path in
            let staticLibraries = Set(projects[path]!.nativeTargets.compactMap {
                $0.productType == "com.apple.product-type.library.static" ? $0.name : nil
            })
            let modules = Dictionary(uniqueKeysWithValues: targetsByProject[path]!.map { target in
                let names = staticLibraries.contains(target.name)
                    ? Array(Set(target.products.filter(\.link).map { DependencyPackage.moduleName($0.product) })).sorted()
                    : []
                return (target.name, names)
            })
            return (path, modules)
        })
        // Targets embedding a framework target from the Podfile also receive an embedding phase.
        let embedders = Dictionary(uniqueKeysWithValues: projectPaths.map { path in
            let names = Set(targetsByProject[path]!.map(\.name))
            return (path, ProjectIntegration.embeddingTargets(projects[path]!, of: names))
        })
        let applicationRuntimeSearchPaths = Dictionary(uniqueKeysWithValues: projectPaths.map { path in
            let project = projects[path]!
            let declaredPlatforms = Dictionary(uniqueKeysWithValues: targetsByProject[path]!.map { ($0.name, $0.platform) })
            var paths: [String: String] = [:]
            for target in project.nativeTargets {
                guard target.productType == "com.apple.product-type.application",
                    let platform = Self.platformName(of: target.name, declared: declaredPlatforms[target.name] ?? nil, in: project)
                else { continue }
                let frameworks = platform == .macos ? "@executable_path/../Frameworks" : "@executable_path/Frameworks"
                if paths[target.name] == nil { paths[target.name] = "$(inherited) " + frameworks }
            }
            return (path, paths)
        })

        var deploymentSnapshots: [String: PackageResolved.PathSnapshot] = [:]
        if options.deployment {
            for path in projectPaths {
                let used = Set(targetsByProject[path]!.flatMap { $0.products.map(\.package) })
                let declaredPackages = manifest.packages.filter { used.contains($0.identity) }
                guard !declaredPackages.isEmpty else { continue }
                let projectURL = projects[path]!.path
                let file = PackageResolved.location(project: projectURL)
                let snapshot = try PackageResolved.snapshot(
                    project: projectURL, projectDescriptor: projectDirectories[path]!.descriptor)
                deploymentSnapshots[path] = snapshot
                // A catalog that moved a name since Package.resolved was committed leaves that package without a pin.
                let packages = declaredPackages.filter { $0.requirement != nil }
                let problems = try PackageResolved(snapshot: snapshot, file: file).problems(for: packages)
                if !problems.isEmpty {
                    throw SwiftPodsError(
                        "Package.resolved does not satisfy the Podfile:\n  " + problems.joined(separator: "\n  "), file: file.path,
                        hint: "Run `swiftpods install --resolve` and commit Package.resolved")
                }
            }
        }

        let fileManager = FileManager.default
        generatedMutationHook?(.beforeGeneratedRootOpen)
        try workspaceLock.verifyIdentity()
        try Self.verifyManifestFiles(manifest)
        let generatedRoot = try ensureGeneratedRoot(workspaceLock: workspaceLock)
        defer { try? generatedRoot.removeRootIfEmpty(removingMarker: true) }
        let staging = try generatedRoot.makeStaging()
        var cleanStagingOnExit = true
        defer { if cleanStagingOnExit { try? staging.cleanup() } }
        let renderStaging = try Self.privateStagingDirectory()
        defer { try? fileManager.removeItem(at: renderStaging) }
        var staged: [String] = []
        var obsolete: [String] = []
        var stagedEntryCount = 0
        var stagedTextBytes = 0

        func stage(_ name: String, _ files: [String: String]) throws {
            guard files.count <= Self.maximumGeneratedEntries - stagedEntryCount else {
                throw SwiftPodsError("Generated output contains more than \(Self.maximumGeneratedEntries) files")
            }
            var encoded: [(String, Data)] = []
            encoded.reserveCapacity(files.count)
            for (relative, text) in files.sorted(by: { $0.key < $1.key }) {
                guard Self.isSafeGeneratedPath(relative) else {
                    throw SwiftPodsError("Refusing unsafe generated path: \(relative)")
                }
                let data = Data(text.utf8)
                guard data.count <= Self.maximumGeneratedFileBytes else {
                    throw SwiftPodsError("Generated file \(relative) exceeds the 8 MiB limit")
                }
                guard data.count <= Self.maximumGeneratedTextBytes - stagedTextBytes else {
                    throw SwiftPodsError("Generated text exceeds the 128 MiB aggregate limit")
                }
                stagedTextBytes += data.count
                encoded.append((relative, data))
            }
            stagedEntryCount += files.count
            let destination = generated.appendingPathComponent(name, isDirectory: true)
            guard try !Self.generatedTree(at: destination, matches: Dictionary(uniqueKeysWithValues: encoded)) else {
                return
            }
            try staging.writeTree(named: name, files: encoded)
            staged.append(name)
        }
        func stem(_ path: String) -> String {
            Self.pathComponent(((path as NSString).lastPathComponent as NSString).deletingPathExtension)
        }
        func folder(_ name: String) -> String { Self.pathComponent(name) }
        let groupedProjects = Dictionary(grouping: projectPaths) { Self.fileSystemKey(stem($0)) }
        let projectFolders = Dictionary(uniqueKeysWithValues: projectPaths.map { path in
            let base = stem(path)
            let folder = groupedProjects[Self.fileSystemKey(base)]!.count == 1 ? base : base + "-" + Self.shortDigest(path)
            return (path, folder)
        })
        guard Set(projectFolders.values.map(Self.fileSystemKey)).count == projectFolders.count else {
            throw SwiftPodsError("Xcode project names produce colliding SwiftPods paths")
        }
        let targetNames = Dictionary(uniqueKeysWithValues: projectPaths.map { path in
            let names = targetsByProject[path]!.map(\.name) + embedders[path]!.filter {
                embedder in !targetsByProject[path]!.contains { $0.name == embedder }
            }
            return (path, names)
        })
        let targetFolders = Dictionary(uniqueKeysWithValues: projectPaths.map { path in
            let names = targetNames[path]!
            let groups = Dictionary(grouping: names, by: Self.fileSystemKey)
            let folders = Dictionary(uniqueKeysWithValues: names.map { name in
                let base = folder(name)
                return (name, groups[Self.fileSystemKey(name)]!.count == 1 ? base : base + "-" + Self.shortDigest(name))
            })
            return (path, folders)
        })
        for (path, folders) in targetFolders {
            guard Set(folders.values.map(Self.fileSystemKey)).count == folders.count else {
                throw SwiftPodsError("Targets in \(path) produce colliding SwiftPods paths")
            }
        }

        // Both generated packages support the lowest deployment target any target has.
        var platforms: [Platform] = []
        for path in projectPaths {
            for target in targetsByProject[path]! {
                guard let platform = Self.platform(of: target, in: projects[path]!) else { continue }
                if let index = platforms.firstIndex(where: { $0.name == platform.name }) {
                    let current = platforms[index].deploymentTarget.flatMap(Version.init)
                    if let new = platform.deploymentTarget.flatMap(Version.init), current.map({ new < $0 }) ?? true {
                        platforms[index] = platform
                    }
                } else {
                    platforms.append(platform)
                }
            }
        }

        // Binaries become one generated local package.
        let binaryDirectory = generated.appendingPathComponent(BinaryPackage.directoryName, isDirectory: true)
        let usesBinaries = manifest.targets.contains { !$0.binaries.isEmpty }
        var binaryEntries: [BinaryPackage.Entry] = []
        var notes: [String] = []
        if usesBinaries {
            let store = BinaryStore(cache: cache, runner: runner, offline: options.offline)
            let binaryWorkspaceDescriptor = try workspaceLock.duplicateDirectoryDescriptor()
            defer { close(binaryWorkspaceDescriptor) }
            for binary in manifest.binaries {
                // Remote cache snapshots can live in this private staging tree. Local sources may include `SwiftPods`
                // itself, so BinaryStore leases a disjoint temporary snapshot for them until rendering completes.
                let snapshot: URL?
                switch binary.source {
                case .local: snapshot = nil
                case .remote:
                    snapshot = renderStaging.appendingPathComponent("binary-snapshots/" + UUID().uuidString, isDirectory: true)
                }
                try workspaceLock.verifyIdentity()
                try Self.verifyManifestFiles(manifest)
                let contents = try { () throws -> BinaryStore.Contents in
                    generatedMutationHook?(.beforeBinaryRead(binary.name))
                    defer { generatedMutationHook?(.afterBinaryRead(binary.name)) }
                    return try store.contents(
                        binary, podfileDirectory: directory,
                        anchoredPodfileDirectory: binaryWorkspaceDescriptor, snapshotDirectory: snapshot)
                }()
                try workspaceLock.verifyIdentity()
                try Self.verifyManifestFiles(manifest)
                binaryEntries.append(BinaryPackage.Entry(
                    binary: binary, xcframeworks: contents.xcframeworks, resources: contents.resources,
                    xcframeworkPaths: contents.xcframeworkPaths, resourcePaths: contents.resourcePaths,
                    snapshotLease: contents.snapshotLease))
            }
            let package = try BinaryPackage(entries: binaryEntries, platforms: platforms)
            try package.validate()
            // A fingerprint stored inside the generated tree is not evidence that its artifacts are still authentic.
            // Materialize a trusted candidate from BinaryStore, then compare every managed path and byte.
            let target = renderStaging.appendingPathComponent(BinaryPackage.directoryName, isDirectory: true)
            let renderedNotes = try package.render(into: target)
            let expectedDigest = try SecureFileTree.generatedPackageDigest(of: target)
            let currentDigest = try? SecureFileTree.generatedPackageDigest(of: binaryDirectory)
            if currentDigest != expectedDigest {
                notes = renderedNotes
                try staging.copyTree(from: target, named: BinaryPackage.directoryName)
                staged.append(BinaryPackage.directoryName)
            }
        } else if try generatedRoot.status(named: BinaryPackage.directoryName) != nil {
            obsolete.append(BinaryPackage.directoryName)
        }

        // Binary SDKs go through one generated package. Swift package products are attached directly to Xcode
        // targets below: a transitive dependency of a wrapper package is not visible to Objective-C/Objective-C++
        // compilation, even though Swift can import it.
        let dependencyDirectory = generated.appendingPathComponent(DependencyPackage.directoryName, isDirectory: true)
        let targetCounts = Dictionary(projectPaths.flatMap { path in targetsByProject[path]!.map { ($0.name, 1) } }, uniquingKeysWith: +)
        func productBase(_ target: Target, _ path: String) -> String {
            targetCounts[target.name]! > 1 ? projectFolders[path]! + "-" + target.name : target.name
        }
        let used = Set(manifest.targets.flatMap { $0.products.map(\.package) })
        let usedPackages = manifest.packages.filter { used.contains($0.identity) }
        var productSpecifications: [(name: String, dependencies: [(product: String, package: String)])] = []
        for path in projectPaths {
            for target in targetsByProject[path]! {
                let linked = DependencyPackage.productName(productBase(target, path))
                productSpecifications.append((
                    name: linked,
                    dependencies: target.binaries.map { ($0, BinaryPackage.directoryName) }))
            }
        }
        let productNames = productSpecifications.map(\.name)
        guard Set(productNames).count == productNames.count else {
            throw SwiftPodsError("Targets produce duplicate SwiftPods package products")
        }
        let moduleGroups = Dictionary(grouping: productNames) { Self.fileSystemKey(DependencyPackage.moduleName($0)) }
        let products = productSpecifications.map { specification in
            let base = DependencyPackage.moduleName(specification.name)
            let module = moduleGroups[Self.fileSystemKey(base)]!.count == 1 ? base : base + "_" + Self.shortDigest(specification.name)
            return DependencyPackage.Product(name: specification.name, module: module, dependencies: specification.dependencies)
        }
        guard Set(products.map { Self.fileSystemKey($0.module) }).count == products.count else {
            throw SwiftPodsError("Targets produce colliding Swift module names after disambiguation")
        }
        let dependencies = DependencyPackage(
            platforms: platforms,
            local: usesBinaries ? [Paths.relative(from: dependencyDirectory, to: binaryDirectory)] : [],
            products: products)
        try stage(DependencyPackage.directoryName, dependencies.files())

        // Build settings become one xcconfig per declared target. Application embedders outside the Podfile also get
        // the runtime search path required for frameworks copied into their bundle by the Finish phase.
        let settingsDirectory = generated.appendingPathComponent("Settings", isDirectory: true)
        var settingsFiles: [String: [String: URL]] = [:]
        var settingsTexts: [String: String] = [:]
        for path in projectPaths {
            let declared = Dictionary(uniqueKeysWithValues: targetsByProject[path]!.map { ($0.name, $0) })
            for name in targetNames[path]! {
                let target = declared[name]
                let runtimeSearchPaths = applicationRuntimeSearchPaths[path]?[name]
                guard target != nil || runtimeSearchPaths != nil else { continue }
                let file = settingsDirectory.appendingPathComponent(projectFolders[path]!)
                    .appendingPathComponent(targetFolders[path]![name]! + ".xcconfig")
                settingsFiles[path, default: [:]][name] = file
                settingsTexts[Paths.relative(from: settingsDirectory, to: file)] = Self.xcconfig(
                    target?.settings ?? [], runtimeSearchPaths: runtimeSearchPaths,
                    packageModuleBridge: !(packageModulesByTarget[path]?[name] ?? []).isEmpty,
                    compileOnlyPackages: compileOnlyTargets[path]!.contains(name))
            }
        }
        try stage("Settings", settingsTexts)

        // Script phases, binary resources and the check that the installation is current run from generated scripts.
        let scriptsDirectory = generated.appendingPathComponent(TargetScripts.directoryName, isDirectory: true)
        let fileListWorkspaceDescriptor = try workspaceLock.duplicateDirectoryDescriptor()
        defer { close(fileListWorkspaceDescriptor) }
        var scriptFiles: [String: String] = [:]
        var fileListSnapshots: [ScriptFileListSnapshot] = []
        var fileListCache: [String: ScriptFileListSnapshot] = [:]
        var missingFileLists = Set<String>()
        var missingFileListUses: [String: (target: String, declaration: String, count: Int)] = [:]
        var attemptedFileLists = Set<String>()
        var fileListsByTarget: [String: [String: [String: [String]]]] = [:]
        var distinctFileListBytes = 0
        var expandedFileListEntries = 0
        var expandedFileListBytes = 0

        // Parse each physical spelling at most once, then account every use before TargetScripts expands it. This
        // prevents a small, repeatedly referenced newline-heavy list from creating an unbounded intermediate array.
        for path in projectPaths {
            let projectDirectory = projects[path]!.sourceRoot
            for target in targetsByProject[path]! {
                var targetFileLists: [String: [String]] = [:]
                for list in target.scriptPhases.flatMap({ $0.inputFileLists + $0.outputFileLists }) {
                    let resolved = list.replacingOccurrences(of: "$(SRCROOT)", with: projectDirectory.path)
                        .replacingOccurrences(of: "${SRCROOT}", with: projectDirectory.path)
                    let requested = resolved.hasPrefix("/")
                        ? URL(fileURLWithPath: resolved).standardizedFileURL
                        : projectDirectory.appendingPathComponent(resolved).standardizedFileURL
                    let key = requested.path
                    if attemptedFileLists.insert(key).inserted {
                        guard attemptedFileLists.count <= Self.maximumScriptFileLists else {
                            throw SwiftPodsError(
                                "Podfile references more than \(Self.maximumScriptFileLists) distinct script file lists")
                        }
                        if let snapshot = try Self.readScriptFileList(
                            requested, workspaceDirectory: directory, workspaceDescriptor: fileListWorkspaceDescriptor,
                            allowExternal: options.allowExternalFileLists)
                        {
                            guard snapshot.contents.count <= Self.maximumScriptFileListTotalBytes - distinctFileListBytes else {
                                throw SwiftPodsError(
                                    "Script file lists exceed the \(Self.maximumScriptFileListTotalBytes)-byte aggregate limit")
                            }
                            distinctFileListBytes += snapshot.contents.count
                            fileListCache[key] = snapshot
                            fileListSnapshots.append(snapshot)
                        } else {
                            missingFileLists.insert(key)
                        }
                    }
                    guard let snapshot = fileListCache[key] else {
                        if missingFileLists.contains(key) {
                            if var use = missingFileListUses[key] {
                                use.count += 1
                                missingFileListUses[key] = use
                            } else {
                                missingFileListUses[key] = (target.name, list, 1)
                            }
                        }
                        continue
                    }
                    guard snapshot.entries.count <= Self.maximumExpandedScriptFileListEntries - expandedFileListEntries,
                        snapshot.entryBytes <= Self.maximumExpandedScriptFileListBytes - expandedFileListBytes
                    else {
                        throw SwiftPodsError(
                            "Expanded script file lists exceed the install work budget", file: snapshot.requested.path)
                    }
                    expandedFileListEntries += snapshot.entries.count
                    expandedFileListBytes += snapshot.entryBytes
                    targetFileLists[list] = snapshot.entries
                }
                var projectFileLists = fileListsByTarget[path] ?? [:]
                projectFileLists[target.name] = targetFileLists
                fileListsByTarget[path] = projectFileLists
            }
        }
        for (_, use) in missingFileListUses.sorted(by: { $0.key < $1.key }) {
            let repeated = use.count == 1 ? "" : " (referenced \(use.count) times across targets)"
            notes.append(
                "\(use.target): file list \(use.declaration) is read when installing and was not found, "
                    + "so its files are not declared\(repeated)")
        }

        var freshnessFiles = manifest.files.map { file in
            (path: Paths.relative(from: directory, to: URL(fileURLWithPath: file.path)), contents: file.contents)
        }
        if let freshnessLockContents {
            freshnessFiles.append((path: SwiftPodsLock.fileName, contents: freshnessLockContents))
        }
        freshnessFiles.append(contentsOf: fileListSnapshots.map { ($0.freshnessPath, $0.contents) })
        scriptFiles[TargetScripts.signatureFile] = freshnessFiles.map { file in
            let digest = SHA256.hash(data: file.contents).map { String(format: "%02x", $0) }.joined()
            return digest + "  " + file.path
        }.joined(separator: "\n") + "\n"
        let freshnessPaths = freshnessFiles.map(\.path)
        var scriptLocations: [String: [String: TargetScripts.Locations]] = [:]
        // Targets that embed a framework target of the Podfile embed its dynamic frameworks; they need not be in the Podfile.
        for path in projectPaths {
            let projectDirectory = projects[path]!.sourceRoot
            func locate(_ name: String) -> (URL, TargetScripts.Locations) {
                let targetDirectory = scriptsDirectory.appendingPathComponent(projectFolders[path]!)
                    .appendingPathComponent(targetFolders[path]?[name] ?? folder(name))
                let locations = TargetScripts.Locations(
                    generated: Paths.relative(from: projectDirectory, to: generated), podfile: Paths.relative(from: projectDirectory, to: directory),
                    target: Paths.relative(from: projectDirectory, to: targetDirectory))
                scriptLocations[path, default: [:]][name] = locations
                return (targetDirectory, locations)
            }
            for target in targetsByProject[path]! {
                let (targetDirectory, locations) = locate(target.name)
                let resources = binaryEntries.filter { target.binaries.contains($0.binary.name) }.flatMap { entry in
                    entry.resources.map {
                        Paths.relative(
                            from: projectDirectory, to: binaryDirectory.appendingPathComponent(BinaryPackage.resourcePath(entry.binary.name, $0)))
                    }
                }
                let fileLists = fileListsByTarget[path]?[target.name] ?? [:]
                let files = TargetScripts.files(
                    scripts: target.scriptPhases, resources: resources, embedsFrameworks: embedders[path]!.contains(target.name),
                    signed: freshnessPaths,
                    fileLists: fileLists, packageModules: packageModulesByTarget[path]?[target.name] ?? [],
                    compileOnlyPackages: compileOnlyTargets[path]!.contains(target.name), paths: locations)
                for (relative, text) in files {
                    scriptFiles[Paths.relative(from: scriptsDirectory, to: targetDirectory.appendingPathComponent(relative))] = text
                }
            }
            let declared = Set(targetsByProject[path]!.map(\.name))
            for name in embedders[path]! where !declared.contains(name) {
                let (targetDirectory, locations) = locate(name)
                let files = TargetScripts.files(scripts: [], resources: [], embedsFrameworks: true, signed: [], fileLists: [:], paths: locations)
                for (relative, text) in files where relative.hasPrefix(TargetScripts.Phase.finish.file + ".") {
                    scriptFiles[Paths.relative(from: scriptsDirectory, to: targetDirectory.appendingPathComponent(relative))] = text
                }
            }
        }
        try stage(TargetScripts.directoryName, scriptFiles)

        var report = InstallReport()
        report.binaries = usesBinaries ? manifest.binaries.map(\.name) : []
        report.notes = notes
        for path in projectPaths {
            var project = projects[path]!
            let projectDirectory = project.sourceRoot
            let relative = Paths.relative(from: projectDirectory, to: dependencyDirectory)
            // A file reference to the package folder rather than an XCLocalSwiftPackageReference: Xcode 26.2 crashes
            // resolving a graph that shrinks, as Firebase's does, when the project holds the latter.
            let package = ProjectPlan.PackageReference(key: "package:local:" + relative, object: [
                "isa": "PBXFileReference", "lastKnownFileType": "wrapper", "name": .string(DependencyPackage.directoryName),
                "path": .string(relative), "sourceTree": "SOURCE_ROOT",
            ])
            func phasePlan(_ phase: TargetScripts.Phase, _ target: String) -> ProjectPlan.PhasePlan {
                let locations = scriptLocations[path]![target]!
                return ProjectPlan.PhasePlan(
                    name: phase.rawValue, script: TargetScripts.phaseScript(phase, paths: locations),
                    inputFileLists: [TargetScripts.fileList(phase, outputs: false, paths: locations)],
                    outputFileLists: [TargetScripts.fileList(phase, outputs: true, paths: locations)], position: phase.position)
            }
            let targets = targetsByProject[path]!
            var packagesByIdentity: [String: ProjectPlan.PackageReference] = [:]
            var plan = ProjectPlan()
            plan.packages = [package]
            if usesBinaries {
                // Xcode 26.2 also needs a folder reference for the binary package reached through the generated
                // dependency container. Leaving that local package implicit can crash dependency-group updates.
                let relative = Paths.relative(from: projectDirectory, to: binaryDirectory)
                plan.packages.append(.init(key: "package:local:" + relative, object: [
                    "isa": "PBXFileReference", "lastKnownFileType": "wrapper",
                    "name": .string(BinaryPackage.directoryName), "path": .string(relative), "sourceTree": "SOURCE_ROOT",
                ]))
            }
            for declared in usedPackages where targets.contains(where: { $0.products.contains { $0.package == declared.identity } }) {
                switch declared.location {
                case .remote(let url):
                    let key = "package:" + PackageLocation.canonical(url)
                    let reference = ProjectPlan.PackageReference(key: key, object: [
                        "isa": "XCRemoteSwiftPackageReference", "repositoryURL": .string(url),
                        "requirement": Self.requirement(declared.requirement!),
                    ])
                    packagesByIdentity[declared.identity] = reference
                    plan.packages.append(reference)
                case .local(let declaredPath):
                    let relative = Paths.relative(
                        from: projectDirectory, to: directory.appendingPathComponent(declaredPath))
                    let key = "package:local:" + relative
                    let reference = ProjectPlan.PackageReference(key: key, object: [
                        "isa": "PBXFileReference", "lastKnownFileType": "wrapper",
                        "name": .string(declared.name), "path": .string(relative), "sourceTree": "SOURCE_ROOT",
                    ])
                    packagesByIdentity[declared.identity] = reference
                    plan.packages.append(reference)
                    plan.managedLocalProducts.formUnion(targets.flatMap { $0.products.filter { $0.package == declared.identity }.map(\.product) })
                }
            }
            for target in targets {
                let base = productBase(target, path)
                let staticLibrary = project.nativeTargets.contains {
                    $0.name == target.name && $0.productType == "com.apple.product-type.library.static"
                }
                // An empty binary container has no code for a static archive. Keep its build dependency,
                // avoiding libtool warnings about its empty object when all SDK uses are compile-only.
                let linkContainer = !staticLibrary || !target.binaries.isEmpty
                    || (!target.products.isEmpty && !compileOnlyTargets[path]!.contains(target.name))
                var products = [ProjectPlan.Product(package: package, name: DependencyPackage.productName(base), link: linkContainer)]
                for product in target.products {
                    guard let dependencyPackage = packagesByIdentity[product.package] else {
                        throw SwiftPodsError("Target `\(target.name)` references unknown package `\(product.package)`")
                    }
                    products.append(.init(package: dependencyPackage, name: product.product, link: product.link))
                }
                plan.targets.append(.init(
                    name: target.name, products: products, phases: TargetScripts.Phase.allCases.map { phasePlan($0, target.name) },
                    settingsFile: Paths.relative(from: projectDirectory, to: settingsFiles[path]![target.name]!),
                    hasSettings: !target.settings.isEmpty || !(packageModulesByTarget[path]?[target.name] ?? []).isEmpty
                        || applicationRuntimeSearchPaths[path]?[target.name] != nil || compileOnlyTargets[path]!.contains(target.name)))
            }
            let declared = Set(targets.map(\.name))
            for name in embedders[path]! where !declared.contains(name) {
                let settingsFile = settingsFiles[path]?[name].map { Paths.relative(from: projectDirectory, to: $0) }
                plan.targets.append(.init(
                    name: name, products: [], phases: [phasePlan(.finish, name)],
                    settingsFile: settingsFile, hasSettings: settingsFile != nil))
            }
            let changes = try ProjectIntegration.apply(
                plan, to: &project, adopt: options.adopt, migrateLegacyCrashlyticsPaths: true)
            projects[path] = project
            report.projects.append(.init(project: path, changes: changes))
        }

        try workspaceLock.verifyIdentity()
        try Self.verifyManifestFiles(manifest)
        try Self.verifyScriptFileLists(
            fileListSnapshots, workspaceDirectory: directory, workspaceDescriptor: fileListWorkspaceDescriptor,
            allowExternal: options.allowExternalFileLists)

        // Publish all mutable workspace files as one recoverable transaction. Generated trees displaced by swaps stay
        // in staging and each written project retains an exact CAS rollback snapshot until every late validation passes.
        var generatedMutations: [GeneratedMutation] = []
        var projectRollbacks: [ProjectRollback] = []
        var packageResolvedRollbacks: [PackageResolvedRollback] = []
        var projectFinalStates: [(
            path: String, file: URL, directory: RetainedProjectDirectory,
            expected: TransactionFileSnapshot
        )] = []
        var packageResolvedFinalStates: [(
            path: String, project: URL, directory: RetainedProjectDirectory,
            expected: PackageResolved.PathSnapshot
        )] = []
        let transactionLockPolicy: InstallTransactionJournal.LockPolicy = resolvedLock.isEmpty
            ? .ignore : (options.deployment ? .preserve : .replace)
        let transactionJournal = try InstallTransactionJournal.begin(
            directory: directory, workspaceDescriptor: workspaceLock.duplicateDirectoryDescriptor(),
            generatedRoot: generatedRoot.url, stagingName: staging.name, lockFile: lockFile,
            lockPolicy: transactionLockPolicy,
            plannedLock: transactionLockPolicy == .replace ? freshnessLockContents : nil)
        var commitRecordingStarted = false
        func resolvePackages(_ arguments: [String], project: XcodeProject, directory: RetainedProjectDirectory) throws {
            var resolutionError: (any Error)?
            do {
                try runPackageResolver(arguments, project: project, directory: directory)
            } catch {
                resolutionError = error
            }
            // Even a failing resolver may have created legitimate derived state. First authenticate every managed
            // member and durably record the complete new tree; cleanup never blindly ignores .swiftpm or .build.
            try transactionJournal.confirmResolverGeneratedMetadata()
            generatedMutations = try generatedMutations.map { try generatedRoot.acceptingResolverMetadata($0) }
            if let resolutionError { throw resolutionError }
        }
        do {
            try generatedRoot.verifyIdentity()
            try validateGeneratedRoot(generatedRoot)
            try generatedRoot.verifyIdentity()
            for name in staged {
                try transactionJournal.prepareGenerated(.publish, name: name)
                try transactionJournal.verifyReadyForWorkspaceMutation()
                generatedMutations.append(try generatedRoot.publish(name, from: staging))
                try transactionJournal.synchronizeGeneratedMutation()
            }
            for name in obsolete {
                try transactionJournal.prepareGenerated(.withdraw, name: name)
                try transactionJournal.verifyReadyForWorkspaceMutation()
                if let mutation = try generatedRoot.withdraw(name, to: staging) {
                    generatedMutations.append(mutation)
                    try transactionJournal.synchronizeGeneratedMutation()
                }
            }
            try generatedRoot.verifyIdentity()
            for path in projectPaths {
                let projectFile = projects[path]!.path.appendingPathComponent("project.pbxproj")
                let projectDirectory = projectDirectories[path]!
                try validateProject(projects[path]!.path, mustBeContained: manifestProjectPaths.contains(path))
                try projects[path]!.verifyDirectoryPathBinding()
                generatedMutationHook?(.beforeProjectTransactionSnapshot(path))
                let original = try Self.transactionSnapshot(
                    projectFile, in: projectDirectory.descriptor)
                let desired = Data(projects[path]!.serialized().utf8)
                try transactionJournal.prepareProject(
                    file: projectFile, projectDescriptor: projectDirectory.descriptor, desired: desired)
                try transactionJournal.verifyReadyForWorkspaceMutation()
                generatedMutationHook?(.beforeProjectSave(path))
                var rollbackRecorded = false
                do {
                    if try projects[path]!.save() {
                        let installed = try Self.transactionSnapshot(
                            projectFile, in: projectDirectory.descriptor)
                        guard installed.data == desired else {
                            throw SwiftPodsError("The installed Xcode project does not match the prepared transaction", file: projectFile.path)
                        }
                        projectRollbacks.append(.init(
                            file: projectFile, directory: projectDirectory,
                            original: original, installed: installed))
                        rollbackRecorded = true
                        projectFinalStates.append((path, projectFile, projectDirectory, installed))
                        try transactionJournal.confirmProject(
                            file: projectFile, projectDescriptor: projectDirectory.descriptor)
                    } else {
                        let unchanged = try Self.transactionSnapshot(
                            projectFile, in: projectDirectory.descriptor)
                        guard unchanged == original, unchanged.data == desired else {
                            throw SwiftPodsError(
                                "The unchanged Xcode project no longer matches the prepared transaction",
                                file: projectFile.path)
                        }
                        projectFinalStates.append((path, projectFile, projectDirectory, unchanged))
                        try transactionJournal.confirmProject(
                            file: projectFile, projectDescriptor: projectDirectory.descriptor)
                    }
                } catch {
                    // save() can report a late durability/cleanup error after its atomic replacement. If its exact
                    // prepared bytes are now installed, make them eligible for the common CAS rollback below.
                    if !rollbackRecorded,
                        let installed = try? Self.transactionSnapshot(
                            projectFile, in: projectDirectory.descriptor),
                        installed != original, installed.data == desired
                    {
                        projectRollbacks.append(.init(
                            file: projectFile, directory: projectDirectory,
                            original: original, installed: installed))
                    }
                    throw error
                }
            }
            try generatedRoot.verifyIdentity()

            if options.deployment {
                for path in projectPaths {
                    let used = Set(targetsByProject[path]!.flatMap { $0.products.map(\.package) })
                    let declaredPackages = manifest.packages.filter { used.contains($0.identity) }
                    guard !declaredPackages.isEmpty else { continue }
                    let projectURL = projects[path]!.path
                    let projectDirectory = projectDirectories[path]!
                    let file = PackageResolved.location(project: projectURL)
                    guard let originalDeploymentSnapshot = deploymentSnapshots[path] else {
                        throw SwiftPodsError("Package.resolved was not validated before integration", file: file.path)
                    }
                    try PackageResolved.validateResolverPath(
                        project: projectURL, projectDescriptor: projectDirectory.descriptor)
                    // Project integration atomically replaces project.pbxproj and therefore legitimately advances the
                    // `.xcodeproj` directory ctime. Re-anchor and revalidate the complete frozen snapshot immediately
                    // before Xcode so that only Xcode/concurrent changes are compared below.
                    let before = try PackageResolved.snapshotAfterProjectWrite(
                        originalDeploymentSnapshot, project: projectURL,
                        projectDescriptor: projectDirectory.descriptor)
                    let frozenPackages = declaredPackages.filter { $0.requirement != nil }
                    let frozenProblems = try PackageResolved(snapshot: before, file: file).problems(for: frozenPackages)
                    if !frozenProblems.isEmpty {
                        throw SwiftPodsError(
                            "Package.resolved changed before frozen validation:\n  "
                                + frozenProblems.joined(separator: "\n  "), file: file.path)
                    }
                    try transactionJournal.preparePackage(
                        project: projectURL, projectDescriptor: projectDirectory.descriptor,
                        original: before)
                    try transactionJournal.verifyReadyForWorkspaceMutation()
                    var resolverError: (any Error)?
                    do {
                        try workspaceLock.verifyIdentity()
                        try Self.verifyManifestFiles(manifest)
                        try Self.verifyScriptFileLists(
                            fileListSnapshots, workspaceDirectory: directory,
                            workspaceDescriptor: fileListWorkspaceDescriptor,
                            allowExternal: options.allowExternalFileLists)
                        try resolvePackages(
                            [
                                "xcodebuild", "-resolvePackageDependencies", "-disableAutomaticPackageResolution",
                                "-onlyUsePackageVersionsFromResolvedFile", "-skipPackageUpdates",
                            ], project: projects[path]!, directory: projectDirectory)
                    } catch {
                        resolverError = error
                    }
                    let after: PackageResolved.PathSnapshot
                    do {
                        after = try PackageResolved.currentSnapshot(
                            project: projectURL, projectDescriptor: projectDirectory.descriptor)
                    } catch {
                        throw SwiftPodsError(
                            "Xcode replaced or removed part of the Package.resolved path during frozen deployment validation",
                            file: file.path,
                            hint: "Restore the committed Package.resolved; deployment validation must not update it")
                    }
                    guard before == after else {
                        do {
                            try PackageResolved.restore(
                                before, project: projectURL,
                                projectDescriptor: projectDirectory.descriptor, replacing: after)
                        } catch {
                            throw SwiftPodsError(
                                "Xcode modified Package.resolved and its original bytes could not be safely restored: \(error)",
                                file: file.path,
                                hint: "A concurrent edit was preserved; review Package.resolved before retrying")
                        }
                        throw SwiftPodsError(
                            "Xcode modified Package.resolved during frozen deployment validation; SwiftPods restored it",
                            file: file.path,
                            hint: "Deployment validation must not update the committed Package.resolved")
                    }
                    try transactionJournal.confirmPackage(
                        project: projectURL, projectDescriptor: projectDirectory.descriptor,
                        installed: after)
                    if let resolverError { throw resolverError }
                    let problems = try PackageResolved(snapshot: after, file: file).problems(for: frozenPackages)
                    if !problems.isEmpty {
                        throw SwiftPodsError(
                            "Package.resolved does not satisfy the Podfile:\n  " + problems.joined(separator: "\n  "), file: file.path)
                    }
                    packageResolvedFinalStates.append((path, projectURL, projectDirectory, after))
                }
            } else if options.resolve {
                for path in projectPaths {
                    let projectURL = projects[path]!.path
                    let projectDirectory = projectDirectories[path]!
                    try PackageResolved.validateResolverPath(
                        project: projectURL, projectDescriptor: projectDirectory.descriptor)
                    // `currentSnapshot` represents a missing directory suffix. Do not discard that state: Xcode may
                    // create the whole workspace path and then fail, and the common transaction must remove it again.
                    let beforeResolve = try PackageResolved.currentSnapshot(
                        project: projectURL, projectDescriptor: projectDirectory.descriptor)
                    try transactionJournal.preparePackage(
                        project: projectURL, projectDescriptor: projectDirectory.descriptor,
                        original: beforeResolve)
                    try transactionJournal.verifyReadyForWorkspaceMutation()
                    var recordedResolveMutation = false
                    do {
                        try workspaceLock.verifyIdentity()
                        try Self.verifyManifestFiles(manifest)
                        try Self.verifyScriptFileLists(
                            fileListSnapshots, workspaceDirectory: directory,
                            workspaceDescriptor: fileListWorkspaceDescriptor,
                            allowExternal: options.allowExternalFileLists)
                        try resolvePackages(
                            ["xcodebuild", "-resolvePackageDependencies"],
                            project: projects[path]!, directory: projectDirectory)
                        let used = Set(targetsByProject[path]!.flatMap { $0.products.map(\.package) })
                        let packages = manifest.packages.filter { used.contains($0.identity) && $0.requirement != nil }
                        let file = PackageResolved.location(project: projectURL)
                        let resolved = try PackageResolved.snapshot(
                            project: projectURL, projectDescriptor: projectDirectory.descriptor)
                        try transactionJournal.confirmPackage(
                            project: projectURL, projectDescriptor: projectDirectory.descriptor,
                            installed: resolved)
                        packageResolvedFinalStates.append((path, projectURL, projectDirectory, resolved))
                        if beforeResolve != resolved {
                            packageResolvedRollbacks.append(.init(
                                project: projectURL, directory: projectDirectory,
                                original: beforeResolve, installed: resolved))
                            recordedResolveMutation = true
                        }
                        let problems = try PackageResolved(snapshot: resolved, file: file).problems(for: packages)
                        if !problems.isEmpty {
                            throw SwiftPodsError(
                                "Xcode resolved versions the Podfile does not allow:\n  "
                                    + problems.joined(separator: "\n  "), file: file.path)
                        }
                    } catch {
                        let resolutionFailure = error
                        if !recordedResolveMutation {
                            let afterResolve: PackageResolved.PathSnapshot
                            do {
                                afterResolve = try PackageResolved.currentSnapshot(
                                    project: projectURL, projectDescriptor: projectDirectory.descriptor)
                            } catch {
                                throw SwiftPodsError(
                                    "Package resolution failed and its Package.resolved path cannot be safely snapshotted: \(resolutionFailure)",
                                    file: PackageResolved.location(project: projectURL).path,
                                    hint: "The path inspection also failed: \(error). Review the workspace before retrying")
                            }
                            if beforeResolve != afterResolve {
                                packageResolvedRollbacks.append(.init(
                                    project: projectURL, directory: projectDirectory,
                                    original: beforeResolve, installed: afterResolve))
                            }
                            try transactionJournal.confirmPackage(
                                project: projectURL, projectDescriptor: projectDirectory.descriptor,
                                installed: afterResolve)
                        }
                        throw resolutionFailure
                    }
                }
            }
            for state in projectFinalStates {
                try projects[state.path]!.verifyDirectoryPathBinding()
                guard try Self.transactionSnapshot(
                    state.file, in: state.directory.descriptor) == state.expected
                else {
                    throw SwiftPodsError(
                        "The Xcode project changed before transaction commit",
                        file: state.file.path,
                        hint: "A concurrent edit was preserved; review the project before retrying")
                }
            }
            for state in packageResolvedFinalStates {
                try projects[state.path]!.verifyDirectoryPathBinding()
                try PackageResolved.verifyUnchanged(
                    state.expected, project: state.project,
                    projectDescriptor: state.directory.descriptor)
            }
            try transactionJournal.verifyFinalStates(projectDescriptors: Dictionary(
                uniqueKeysWithValues: projectPaths.map {
                    (projects[$0]!.path.path, projectDirectories[$0]!.descriptor)
                }))
            for mutation in generatedMutations {
                try generatedRoot.verifyCommitted(mutation, staging: staging)
            }
            if options.deployment, !resolvedLock.isEmpty {
                try SwiftPodsLock.verifyUnchanged(at: lockFile, since: lockRead.replacementState())
            }
            try workspaceLock.verifyIdentity()
            try Self.verifyManifestFiles(manifest)
            try Self.verifyScriptFileLists(
                fileListSnapshots, workspaceDirectory: directory,
                workspaceDescriptor: fileListWorkspaceDescriptor,
                allowExternal: options.allowExternalFileLists)
            // The lock is the final security-relevant write. It is optional for explicit-only Podfiles, created when
            // absent, and intentionally never required to be committed.
            if !options.deployment, !resolvedLock.isEmpty {
                try transactionJournal.prepareCommit()
                try transactionJournal.verifyReadyForWorkspaceMutation()
                // From this point recovery, not ordinary rollback, owns classification: the lock writer may have
                // installed the planned bytes even when a later validation/cleanup reports an error.
                commitRecordingStarted = true
                try resolvedLock.write(
                    to: lockFile, replacing: lockRead.replacementState(),
                    _temporaryName: transactionJournal.lockTemporaryName,
                    _cleanupDirectoryName: transactionJournal.lockCleanupDirectoryName,
                    _beforeFinalPathCheck: {
                        generatedMutationHook?(.beforeLockFinalPathCheck)
                        try lockWriteHook?(.beforeFinalPathCheck)
                    },
                    _beforeCleanup: {
                        generatedMutationHook?(.beforeLockCleanup)
                        try lockWriteHook?(.beforeCleanup)
                    })
            }
            // Once commit recording begins, an uncertain journal fsync must never send execution through ordinary
            // rollback: startup recovery will classify the durable phase (and the final lock, when present) safely.
            commitRecordingStarted = true
            try transactionJournal.markCommitted()
        } catch {
            if commitRecordingStarted {
                cleanStagingOnExit = false
                throw SwiftPodsError(
                    "Install reached its commit boundary but could not durably finish the transaction journal: \(error)",
                    hint: "Run SwiftPods again to complete descriptor-checked transaction recovery")
            }
            var rollbackFailures: [String] = []
            for rollback in packageResolvedRollbacks.reversed() {
                do {
                    try PackageResolved.restore(
                        rollback.original, project: rollback.project,
                        projectDescriptor: rollback.directory.descriptor,
                        replacing: rollback.installed)
                } catch {
                    rollbackFailures.append("\(PackageResolved.location(project: rollback.project).path): \(error)")
                }
            }
            for rollback in projectRollbacks.reversed() {
                do {
                    try Self.restoreTransactionFile(
                        rollback.original, at: rollback.file, in: rollback.directory.descriptor,
                        replacing: rollback.installed)
                } catch {
                    rollbackFailures.append("\(rollback.file.path): \(error)")
                }
            }
            for mutation in generatedMutations.reversed() {
                do {
                    switch mutation {
                    case .published(let name, let installed, let displaced):
                        try generatedRoot.rollbackPublished(
                            name, installed: installed, displaced: displaced, staging: staging)
                    case .withdrawn(let name, let displaced):
                        try generatedRoot.rollbackWithdrawn(
                            name, displaced: displaced, staging: staging)
                    }
                } catch {
                    rollbackFailures.append("generated transaction: \(error)")
                }
            }
            if rollbackFailures.isEmpty {
                do {
                    try transactionJournal.finishRolledBack()
                    cleanStagingOnExit = false
                } catch {
                    cleanStagingOnExit = false
                    rollbackFailures.append("durable transaction recovery: \(error)")
                }
            }
            if !rollbackFailures.isEmpty {
                // Preserve displaced trees for manual recovery instead of deleting the evidence in the defer above.
                cleanStagingOnExit = false
                throw SwiftPodsError(
                    "Install failed and its workspace rollback was incomplete: \(error)",
                    hint: rollbackFailures.joined(separator: "\n"))
            }
            throw error
        }
        do {
            // Recheck immediately before cleanup as well. The lock write above is the commit point, so a late
            // non-cooperating replacement is preserved and reported as housekeeping instead of being rolled back or
            // recursively deleted from transaction staging.
            try transactionJournal.finishCommitted(_beforeStagingCleanup: {
                generatedMutationHook?(.afterStagingCleanupVerification)
            })
            cleanStagingOnExit = false
        } catch {
            cleanStagingOnExit = false
            // All user-visible files have committed. A marked private staging directory is recoverable housekeeping,
            // not a reason to report a failed install after the rollback point has been discarded.
            report.notes.append("SwiftPods could not remove a completed transaction staging directory: \(error)")
        }
        return report
    }

    /// Removes everything SwiftPods added to the projects and the generated directory; with `cocoapods`,
    /// also a CocoaPods or SwiftPods 0.1 integration.
    public func deintegrate(cocoapods: Bool = false) throws -> InstallReport {
        let workspaceLock = try WorkspaceLock(directory: directory)
        defer { withExtendedLifetime(workspaceLock) {} }
        let generatedRoot: GeneratedRoot?
        if try Self.entryType(at: generated) != nil {
            generatedMutationHook?(.beforeGeneratedRootOpen)
            let root = try GeneratedRoot(
                workspaceLock: workspaceLock, name: Self.generatedDirectory, create: false,
                mutationHook: generatedMutationHook)
            try root.verifyIdentity()
            try validateGeneratedRoot(root, allowLegacy: true)
            try root.verifyIdentity()
            generatedRoot = root
        } else {
            generatedRoot = nil
        }
        let projectWorkspaceDescriptor = try workspaceLock.duplicateDirectoryDescriptor()
        defer { close(projectWorkspaceDescriptor) }
        var paths = Set(try Self.workspaceProjectNames(in: projectWorkspaceDescriptor))
        let parsedManifest = try? manifest(offline: true)
        let manifestProjectPaths = Set(parsedManifest?.targets.compactMap(\.project) ?? [])
        paths.formUnion(manifestProjectPaths)
        if let project { paths.insert(Paths.relative(from: directory, to: project)) }
        var projects: [(path: String, project: XcodeProject, changes: [ProjectChange], workspace: URL?)] = []
        var projectIdentities: [String: String] = [:]
        do {
            // Prepare every project before the first write. A parse or integration failure therefore cannot leave an
            // earlier project partially deintegrated.
            for path in paths.sorted() {
                let projectURL = directory.appendingPathComponent(path)
                try validateProject(projectURL, mustBeContained: manifestProjectPaths.contains(path))
                let identity = try Self.fileIdentity(at: projectURL)
                if let existing = projectIdentities[identity] {
                    throw SwiftPodsError("Project paths \(existing) and \(path) refer to the same Xcode project")
                }
                projectIdentities[identity] = path
                var value: XcodeProject
                if PackageLocation.isSafeRelativePath(path) {
                    value = try XcodeProject(
                        path: projectURL, relativePath: path,
                        relativeToDirectoryDescriptor: projectWorkspaceDescriptor)
                } else {
                    value = try XcodeProject(path: projectURL)
                }
                var changes = try ProjectIntegration.apply(ProjectPlan(), to: &value, adopt: false)
                let workspace: URL?
                if cocoapods {
                    changes += try CocoaPodsIntegration.remove(from: &value)
                    workspace = value.path.deletingPathExtension().appendingPathExtension("xcworkspace")
                } else {
                    workspace = nil
                }
                projects.append((path, value, changes, workspace))
            }
        } catch { throw SwiftPodsError.wrap(error) }

        let projectDirectories = try projects.map { try RetainedProjectDirectory($0.project) }

        // `parsedManifest` supplied project paths and containment requirements above. Authenticate those exact bytes
        // again at the first write boundary, just as install does, rather than deintegrating from a stale policy.
        generatedMutationHook?(.beforeDeintegrationMutation)
        if let parsedManifest { try Self.verifyManifestFiles(parsedManifest) }
        let staging: GeneratedStaging?
        do { staging = try generatedRoot?.makeStaging() } catch { throw SwiftPodsError.wrap(error) }
        var generatedMutations: [GeneratedMutation] = []
        var workspaceMutations: [CocoaPodsIntegration.WorkspaceMutation] = []
        var projectRollbacks: [ProjectRollback] = []
        var projectFinalStates: [(
            index: Int, file: URL, directory: RetainedProjectDirectory,
            expected: TransactionFileSnapshot
        )] = []
        do {
            if let generatedRoot, let staging {
                for name in [
                    BinaryPackage.directoryName, DependencyPackage.directoryName,
                    TargetScripts.directoryName, "Settings",
                ] {
                    if let mutation = try generatedRoot.withdraw(name, to: staging) {
                        generatedMutations.append(mutation)
                    }
                }
            }

            // Workspace XML is committed before projects so a later project failure exercises the same common rollback
            // path; each mutation verifies its own installed inode and bytes before it can be reversed.
            for index in projects.indices {
                guard let workspace = projects[index].workspace else { continue }
                let relativeWorkspacePath = PackageLocation.isSafeRelativePath(projects[index].path)
                    ? (projects[index].path as NSString).deletingPathExtension + ".xcworkspace"
                    : nil
                if let mutation = try CocoaPodsIntegration.removePodsProjectRecoverably(
                    fromWorkspace: workspace,
                    relativeToWorkspaceRoot: relativeWorkspacePath == nil ? nil : projectWorkspaceDescriptor,
                    relativeWorkspacePath: relativeWorkspacePath)
                {
                    workspaceMutations.append(mutation)
                    projects[index].changes.append(ProjectChange(
                        kind: .removed, subject: "Pods/Pods.xcodeproj from " + workspace.lastPathComponent))
                    generatedMutationHook?(.afterDeintegratedWorkspace(projects[index].path))
                }
            }

            for index in projects.indices {
                let path = projects[index].path
                let projectFile = projects[index].project.file
                let projectDirectory = projectDirectories[index]
                try validateProject(
                    projects[index].project.path, mustBeContained: manifestProjectPaths.contains(path))
                try projects[index].project.verifyDirectoryPathBinding()
                let original = try Self.transactionSnapshot(
                    projectFile, in: projectDirectory.descriptor)
                let desired = Data(projects[index].project.serialized().utf8)
                var rollbackRecorded = false
                do {
                    if try projects[index].project.save() {
                        let installed = try Self.transactionSnapshot(
                            projectFile, in: projectDirectory.descriptor)
                        guard installed.data == desired else {
                            throw SwiftPodsError(
                                "The deintegrated Xcode project does not match the prepared transaction",
                                file: projectFile.path)
                        }
                        projectRollbacks.append(.init(
                            file: projectFile, directory: projectDirectory,
                            original: original, installed: installed))
                        rollbackRecorded = true
                        projectFinalStates.append((index, projectFile, projectDirectory, installed))
                    } else {
                        let unchanged = try Self.transactionSnapshot(
                            projectFile, in: projectDirectory.descriptor)
                        guard unchanged == original, unchanged.data == desired else {
                            throw SwiftPodsError(
                                "The unchanged Xcode project no longer matches the prepared deintegration",
                                file: projectFile.path)
                        }
                        projectFinalStates.append((index, projectFile, projectDirectory, unchanged))
                    }
                } catch {
                    if !rollbackRecorded,
                        let installed = try? Self.transactionSnapshot(
                            projectFile, in: projectDirectory.descriptor),
                        installed != original, installed.data == desired
                    {
                        projectRollbacks.append(.init(
                            file: projectFile, directory: projectDirectory,
                            original: original, installed: installed))
                    }
                    throw error
                }
                generatedMutationHook?(.afterDeintegratedProjectSave(path))
            }
            for state in projectFinalStates {
                try projects[state.index].project.verifyDirectoryPathBinding()
                guard try Self.transactionSnapshot(
                    state.file, in: state.directory.descriptor) == state.expected
                else {
                    throw SwiftPodsError(
                        "An Xcode project changed before deintegration committed", file: state.file.path)
                }
            }
            for mutation in workspaceMutations { try mutation.verifyInstalled() }
            if let generatedRoot, let staging {
                for mutation in generatedMutations {
                    try generatedRoot.verifyCommitted(mutation, staging: staging)
                }
            }
            // A change after the first check must enter the common rollback path before the transaction is accepted.
            generatedMutationHook?(.beforeDeintegrationCommit)
            if let parsedManifest { try Self.verifyManifestFiles(parsedManifest) }
        } catch {
            let failure = error
            var rollbackFailures: [String] = []
            for rollback in projectRollbacks.reversed() {
                do {
                    try Self.restoreTransactionFile(
                        rollback.original, at: rollback.file, in: rollback.directory.descriptor,
                        replacing: rollback.installed)
                } catch {
                    rollbackFailures.append("\(rollback.file.path): \(error)")
                }
            }
            for mutation in workspaceMutations.reversed() {
                do { try mutation.rollback() } catch {
                    rollbackFailures.append("CocoaPods workspace: \(error)")
                }
            }
            if let generatedRoot, let staging {
                for mutation in generatedMutations.reversed() {
                    do {
                        switch mutation {
                        case .published(let name, let installed, let displaced):
                            try generatedRoot.rollbackPublished(
                                name, installed: installed, displaced: displaced, staging: staging)
                        case .withdrawn(let name, let displaced):
                            try generatedRoot.rollbackWithdrawn(
                                name, displaced: displaced, staging: staging)
                        }
                    } catch {
                        rollbackFailures.append("generated deintegration: \(error)")
                    }
                }
                if rollbackFailures.isEmpty { try? staging.cleanup() }
                else { staging.preserveEvidence() }
            }
            if !rollbackFailures.isEmpty {
                throw SwiftPodsError(
                    "Deintegration failed and its workspace rollback was incomplete: \(failure)",
                    hint: rollbackFailures.joined(separator: "\n"))
            }
            throw SwiftPodsError.wrap(failure)
        }

        var report = InstallReport(projects: projects.map {
            .init(project: $0.path, changes: $0.changes)
        })
        if let generatedRoot, let staging {
            do {
                for mutation in generatedMutations {
                    try generatedRoot.verifyCommitted(mutation, staging: staging)
                }
                try staging.cleanup()
                try generatedRoot.removeManagedChildren()
                try generatedRoot.remove(Self.ownershipFile)
                try generatedRoot.removeRootIfEmpty(removingMarker: false)
            } catch {
                staging.preserveEvidence()
                report.notes.append("SwiftPods could not finish generated deintegration housekeeping: \(error)")
            }
        }
        return report
    }

    static func requirement(_ requirement: Requirement) -> PBXValue {
        switch requirement {
        case .exact(let version): ["kind": "exactVersion", "version": .string(version.description)]
        case .upToNextMajor(let version): ["kind": "upToNextMajorVersion", "minimumVersion": .string(version.description)]
        case .upToNextMinor(let version): ["kind": "upToNextMinorVersion", "minimumVersion": .string(version.description)]
        case .range(let lower, let upper):
            ["kind": "versionRange", "minimumVersion": .string(lower.description), "maximumVersion": .string(upper.description)]
        case .branch(let branch): ["kind": "branch", "branch": .string(branch)]
        case .revision(let revision): ["kind": "revision", "revision": .string(revision)]
        }
    }

    static func xcconfig(
        _ settings: [BuildSetting], runtimeSearchPaths: String? = nil, packageModuleBridge: Bool = false,
        compileOnlyPackages: Bool = false
    ) -> String {
        var lines = ["// Generated by SwiftPods from the Podfile. Do not edit."]
        if let runtimeSearchPaths {
            lines.append("LD_RUNPATH_SEARCH_PATHS = \(runtimeSearchPaths)")
        }
        for setting in settings {
            if let configurations = setting.configurations {
                lines += configurations.map { "\(setting.key)[config=\($0)] = \(setting.value)" }
            } else {
                lines.append("\(setting.key) = \(setting.value)")
            }
        }
        if packageModuleBridge || compileOnlyPackages {
            lines.append("HEADER_SEARCH_PATHS = $(inherited) \(TargetScripts.packageModuleSearchPath)")
        }
        if compileOnlyPackages {
            let arguments = TargetScripts.packageCompilerArguments
            lines.append("USE_RECURSIVE_SCRIPT_INPUTS_IN_SCRIPT_PHASES = YES")
            lines.append("OTHER_CFLAGS = $(inherited) \(arguments)")
            lines.append("OTHER_CPLUSPLUSFLAGS = $(inherited) \(arguments)")
            lines.append("OTHER_SWIFT_FLAGS = $(inherited) -Xcc \(arguments)")
            lines.append("FRAMEWORK_SEARCH_PATHS = $(inherited) $(BUILT_PRODUCTS_DIR)/PackageFrameworks")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The platform family controls the relative layout of an application's executable and Frameworks directory.
    private static func platformName(of target: String, declared: Platform?, in project: XcodeProject) -> PlatformName? {
        if let declared { return declared.name }
        var settings: [String: PBXValue] = [:]
        let owners = (project.nativeTargets.first { $0.name == target }.map { [$0.id] } ?? []) + [project.rootID]
        for owner in owners {
            for id in project.configurations(of: owner).values.sorted() {
                for (key, value) in project[id]?["buildSettings"]?.dictionary ?? [:] where settings[key] == nil {
                    settings[key] = value
                }
            }
        }
        let platforms: [(PlatformName, String, String)] = [
            (.ios, "iphoneos", "IPHONEOS_DEPLOYMENT_TARGET"), (.macos, "macosx", "MACOSX_DEPLOYMENT_TARGET"),
            (.tvos, "appletvos", "TVOS_DEPLOYMENT_TARGET"), (.watchos, "watchos", "WATCHOS_DEPLOYMENT_TARGET"),
            (.visionos, "xros", "XROS_DEPLOYMENT_TARGET"),
        ]
        if let sdk = settings["SDKROOT"]?.string, let platform = platforms.first(where: { $0.1 == sdk }) {
            return platform.0
        }
        return platforms.first(where: { settings[$0.2] != nil })?.0
    }

    /// Whether `directory` holds exactly the `expected` files by relative path; hidden files, such as Xcode's
    /// `.swiftpm`, are not SwiftPods'. Other files, such as build products written into a generated package, make
    /// the tree differ without being read, so staging replaces them like any other stale content.
    private static func generatedTree(at directory: URL, matches expected: [String: Data]) throws -> Bool {
        guard let type = try entryType(at: directory) else { return expected.isEmpty }
        guard type == S_IFDIR else { throw SwiftPodsError("Generated path is not a directory: \(directory.path)") }
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles],
            errorHandler: { _, error in enumerationError = error; return false })
        else { throw SwiftPodsError("Cannot inspect generated directory \(directory.path)") }
        var matches = true
        var matched = 0
        var entries = 0
        for case let url as URL in enumerator {
            entries += 1
            guard entries <= maximumGeneratedEntries else {
                throw SwiftPodsError("Generated directory contains more than \(maximumGeneratedEntries) entries")
            }
            let relative = Paths.relative(from: directory, to: url)
            guard isSafeGeneratedPath(relative) else {
                throw SwiftPodsError("Refusing unsafe path inside the generated directory: \(url.path)")
            }
            let type = try entryType(at: url)
            guard type == S_IFDIR || type == S_IFREG else {
                throw SwiftPodsError("Refusing symbolic link or special file inside the generated directory: \(url.path)")
            }
            guard type == S_IFREG, matches else { continue }
            guard let contents = expected[relative], try generatedFile(at: url, matches: contents) else {
                matches = false
                continue
            }
            matched += 1
        }
        if let enumerationError { throw SwiftPodsError("Cannot inspect generated directory \(directory.path): \(enumerationError)") }
        return matches && matched == expected.count
    }

    /// Reads at most the expected size, so the comparison stays within the limits of the staged output.
    private static func generatedFile(at url: URL, matches contents: Data) throws -> Bool {
        let descriptor = url.path.withCString { open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK) }
        guard descriptor >= 0 else {
            throw SwiftPodsError("Cannot safely read generated file: \(String(cString: strerror(errno)))", file: url.path)
        }
        var information = stat()
        guard fstat(descriptor, &information) == 0, information.st_size == contents.count else {
            close(descriptor)
            return false
        }
        return try readBoundedRegularData(
            descriptor, maximumBytes: contents.count, kind: "Generated file", file: url.path) == contents
    }

    private static func isSafeGeneratedPath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), path.utf8.count <= 16 * 1_024 else {
            return false
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return components.count <= maximumGeneratedDepth
            && components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private func ensureGeneratedRoot(workspaceLock: WorkspaceLock) throws -> GeneratedRoot {
        let root = try GeneratedRoot(
            workspaceLock: workspaceLock, name: Self.generatedDirectory, create: true,
            mutationHook: generatedMutationHook)
        if let marker = try root.status(named: Self.ownershipFile) {
            guard marker.st_mode & S_IFMT == S_IFREG,
                (try? root.readText(named: Self.ownershipFile, maximumBytes: 1_024, kind: "Ownership marker")) == Self.ownership
            else {
                throw SwiftPodsError("\(generated.appendingPathComponent(Self.ownershipFile).path) is not a valid SwiftPods ownership marker")
            }
        } else {
            try root.verifyIdentity()
            guard try Self.isLegacyGeneratedRoot(root) else {
                throw SwiftPodsError(
                    "Refusing to manage non-SwiftPods directory \(generated.path)",
                    hint: "Move it away, or run `swiftpods deintegrate` with the SwiftPods version that created it")
            }
            try root.validateManagedChildren()
            try root.verifyIdentity()
            try root.writeExclusive(Data(Self.ownership.utf8), named: Self.ownershipFile)
        }
        try root.verifyIdentity()
        try validateGeneratedRoot(root)
        try root.verifyIdentity()
        return root
    }

    private func validateGeneratedRoot(_ root: GeneratedRoot, allowLegacy: Bool = false) throws {
        try root.verifyIdentity()
        if let marker = try root.status(named: Self.ownershipFile), marker.st_mode & S_IFMT == S_IFREG,
            (try? root.readText(named: Self.ownershipFile, maximumBytes: 1_024, kind: "Ownership marker")) == Self.ownership
        {
            try root.validateManagedChildren()
            return
        }
        guard allowLegacy, try Self.isLegacyGeneratedRoot(root) else {
            throw SwiftPodsError("Refusing to remove a generated directory without a valid SwiftPods ownership marker: \(generated.path)")
        }
        try root.validateManagedChildren()
    }

    private func validateProject(_ url: URL, mustBeContained: Bool) throws {
        if mustBeContained, !PackageLocation.isPath(url.path, containedIn: directory.path) {
            throw SwiftPodsError("Refusing Xcode project outside the Podfile directory: \(url.path)")
        }
        guard try Self.entryType(at: url) == S_IFDIR else {
            throw SwiftPodsError("No regular Xcode project at \(url.path)")
        }
        let file = url.appendingPathComponent("project.pbxproj")
        guard try Self.entryType(at: file) == S_IFREG else {
            throw SwiftPodsError("Xcode project file must be a regular file", file: file.path)
        }
    }

    private static func isLegacyGeneratedRoot(_ root: GeneratedRoot) throws -> Bool {
        try root.verifyIdentity()
        let children = try GeneratedRoot.names(in: root.descriptor)
        if children.isEmpty { return true }
        let managed = Set([
            BinaryPackage.directoryName, DependencyPackage.directoryName, TargetScripts.directoryName, "Settings",
        ])
        guard children.allSatisfy(managed.contains), children.contains(DependencyPackage.directoryName) else {
            return false
        }
        let packageDirectories = [DependencyPackage.directoryName]
            + (children.contains(BinaryPackage.directoryName) ? [BinaryPackage.directoryName] : [])
        return packageDirectories.allSatisfy { name in
            let directory = name.withCString {
                openat(root.descriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            }
            guard directory >= 0 else { return false }
            defer { close(directory) }
            let file = "Package.swift".withCString {
                openat(directory, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            }
            guard file >= 0 else { return false }
            defer { close(file) }
            guard let text = try? GeneratedRoot.readText(
                file, maximumBytes: 8 * 1_024 * 1_024, kind: "Generated manifest")
            else { return false }
            let lines = text.components(separatedBy: .newlines)
            return lines.count >= 2 && lines[0].hasPrefix("// swift-tools-version: ")
                && lines[1] == "// Generated by SwiftPods from the Podfile. Do not edit."
        }
    }

    private static func entryType(at url: URL) throws -> mode_t? {
        var information = stat()
        if lstat(url.path, &information) == 0 { return information.st_mode & S_IFMT }
        if errno == ENOENT { return nil }
        throw SwiftPodsError("Cannot inspect \(url.path): \(String(cString: strerror(errno)))")
    }

    private static func fileIdentity(at url: URL) throws -> String {
        var information = stat()
        guard stat(url.path, &information) == 0 else {
            throw SwiftPodsError("Cannot inspect \(url.path): \(String(cString: strerror(errno)))")
        }
        return "\(information.st_dev):\(information.st_ino)"
    }

    /// Reads a Podfile-declared xcfilelist from the locked workspace inode. Paths inside the workspace never pass
    /// through a pathname reopen: every component is opened with `openat`/`O_NOFOLLOW` and retained until after the
    /// bytes are read. External paths require an explicit install option, are canonicalized once, and then receive
    /// the same descriptor walk from `/`.
    private static func readScriptFileList(
        _ requested: URL, workspaceDirectory: URL, workspaceDescriptor: Int32, allowExternal: Bool
    ) throws -> ScriptFileListSnapshot? {
        let candidate = requested.standardizedFileURL
        guard let contents = try readScriptFileListData(
            candidate, workspaceDirectory: workspaceDirectory, workspaceDescriptor: workspaceDescriptor,
            allowExternal: allowExternal)
        else { return nil }
        let parsed = try parseScriptFileList(contents, file: candidate.path)
        let workspace = workspaceDirectory.standardizedFileURL
        let workspaceComponents = workspace.pathComponents
        let candidateComponents = candidate.pathComponents
        let contained = candidateComponents.count > workspaceComponents.count
            && candidateComponents.prefix(workspaceComponents.count).elementsEqual(workspaceComponents)
        return ScriptFileListSnapshot(
            requested: candidate,
            freshnessPath: contained ? Paths.relative(from: workspace, to: candidate) : candidate.path,
            contents: contents, entries: parsed.entries, entryBytes: parsed.bytes)
    }

    private static func verifyScriptFileLists(
        _ snapshots: [ScriptFileListSnapshot], workspaceDirectory: URL, workspaceDescriptor: Int32,
        allowExternal: Bool
    ) throws {
        for snapshot in snapshots {
            guard let current = try readScriptFileListData(
                snapshot.requested, workspaceDirectory: workspaceDirectory, workspaceDescriptor: workspaceDescriptor,
                allowExternal: allowExternal), current == snapshot.contents
            else {
                throw SwiftPodsError(
                    "Script file list changed after it was read", file: snapshot.requested.path,
                    hint: "Retry after the process modifying the file list has finished")
            }
        }
    }

    private static func readScriptFileListData(
        _ requested: URL, workspaceDirectory: URL, workspaceDescriptor: Int32, allowExternal: Bool
    ) throws -> Data? {
        let workspace = workspaceDirectory.standardizedFileURL
        let candidate = requested.standardizedFileURL
        let workspaceComponents = workspace.pathComponents
        let candidateComponents = candidate.pathComponents
        let contained = candidateComponents.count > workspaceComponents.count
            && candidateComponents.prefix(workspaceComponents.count).elementsEqual(workspaceComponents)
        if contained {
            return try readAnchoredFileList(
                components: Array(candidateComponents.dropFirst(workspaceComponents.count)),
                rootDescriptor: workspaceDescriptor, diagnosticPath: candidate.path)
        }
        guard allowExternal else {
            throw SwiftPodsError(
                "Refusing to read script file list outside the Podfile directory",
                file: candidate.path,
                hint: "Move the list into the workspace or pass --allow-external-file-lists to trust external lists")
        }

        var initial = stat()
        if candidate.path.withCString({ lstat($0, &initial) }) != 0 {
            let problem = errno
            if problem == ENOENT { return nil }
            throw SwiftPodsError(
                "Cannot safely read file list: \(String(cString: strerror(problem)))", file: candidate.path)
        }
        guard initial.st_mode & S_IFMT == S_IFREG else {
            throw SwiftPodsError("File list must be a non-symlink regular file", file: candidate.path)
        }
        guard let pointer = candidate.path.withCString({ realpath($0, nil) }) else {
            throw SwiftPodsError(
                "Cannot safely read file list: \(String(cString: strerror(errno)))", file: candidate.path)
        }
        defer { free(pointer) }
        // Do not call standardizedFileURL here: Foundation rewrites `/private/var` back to the `/var` symlink on
        // macOS, which would defeat the no-follow component walk below.
        let canonical = URL(fileURLWithPath: String(cString: pointer))
        let root = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard root >= 0 else {
            throw SwiftPodsError("Cannot safely open the filesystem root for an external file list")
        }
        defer { close(root) }
        guard let data = try readAnchoredFileList(
            components: Array(canonical.pathComponents.dropFirst()), rootDescriptor: root,
            diagnosticPath: candidate.path)
        else { throw SwiftPodsError("External file list changed while it was opened", file: candidate.path) }
        var final = stat()
        guard candidate.path.withCString({ lstat($0, &final) }) == 0,
            sameFileSnapshot(initial, final), final.st_mode & S_IFMT == S_IFREG
        else { throw SwiftPodsError("External file list changed while it was read", file: candidate.path) }
        return data
    }

    private static func readAnchoredFileList(
        components: [String], rootDescriptor: Int32, diagnosticPath: String
    ) throws -> Data? {
        guard (1...256).contains(components.count), components.allSatisfy({
            !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\")
                && !$0.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        }) else { throw SwiftPodsError("File list path has unsafe or excessive components", file: diagnosticPath) }
        let root = fcntl(rootDescriptor, F_DUPFD_CLOEXEC, STDERR_FILENO + 1)
        guard root >= 0 else { throw SwiftPodsError("Cannot duplicate the file-list root descriptor") }
        var descriptors = [root]
        var edges: [(parent: Int32, name: String, child: Int32)] = []
        defer { for descriptor in descriptors.reversed() { close(descriptor) } }

        for component in components.dropLast() {
            let parent = descriptors.last!
            let child = component.withCString {
                openat(parent, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            }
            if child < 0 {
                let problem = errno
                if problem == ENOENT { return nil }
                throw SwiftPodsError(
                    "Cannot safely read file list directory `\(component)`: \(String(cString: strerror(problem)))",
                    file: diagnosticPath)
            }
            var opened = stat()
            var linked = stat()
            guard fstat(child, &opened) == 0, opened.st_mode & S_IFMT == S_IFDIR,
                component.withCString({ fstatat(parent, $0, &linked, AT_SYMLINK_NOFOLLOW) }) == 0,
                linked.st_mode & S_IFMT == S_IFDIR, sameFileObject(opened, linked)
            else {
                close(child)
                throw SwiftPodsError("File list directory changed while it was opened", file: diagnosticPath)
            }
            descriptors.append(child)
            edges.append((parent, component, child))
        }

        let name = components.last!
        let parent = descriptors.last!
        let file = name.withCString {
            openat(parent, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        if file < 0 {
            let problem = errno
            if problem == ENOENT { return nil }
            throw SwiftPodsError(
                "Cannot safely read file list: \(String(cString: strerror(problem)))", file: diagnosticPath)
        }
        descriptors.append(file)
        var openedFile = stat()
        var linkedFile = stat()
        guard fstat(file, &openedFile) == 0, openedFile.st_mode & S_IFMT == S_IFREG,
            name.withCString({ fstatat(parent, $0, &linkedFile, AT_SYMLINK_NOFOLLOW) }) == 0,
            linkedFile.st_mode & S_IFMT == S_IFREG, sameFileSnapshot(openedFile, linkedFile)
        else { throw SwiftPodsError("File list changed while it was opened", file: diagnosticPath) }
        let duplicate = fcntl(file, F_DUPFD_CLOEXEC, STDERR_FILENO + 1)
        guard duplicate >= 0 else { throw SwiftPodsError("Cannot duplicate the opened file list", file: diagnosticPath) }
        let data = try readBoundedRegularData(
            duplicate, maximumBytes: maximumScriptFileListBytes, kind: "File list", file: diagnosticPath)

        var finalFile = stat()
        var finalLinkedFile = stat()
        guard fstat(file, &finalFile) == 0, sameFileSnapshot(openedFile, finalFile),
            name.withCString({ fstatat(parent, $0, &finalLinkedFile, AT_SYMLINK_NOFOLLOW) }) == 0,
            sameFileSnapshot(openedFile, finalLinkedFile)
        else { throw SwiftPodsError("File list path changed while it was read", file: diagnosticPath) }
        for edge in edges.reversed() {
            var opened = stat()
            var linked = stat()
            guard fstat(edge.child, &opened) == 0,
                edge.name.withCString({ fstatat(edge.parent, $0, &linked, AT_SYMLINK_NOFOLLOW) }) == 0,
                sameFileObject(opened, linked)
            else { throw SwiftPodsError("File list directory changed while it was read", file: diagnosticPath) }
        }
        return data
    }

    private static func parseScriptFileList(_ data: Data, file: String) throws -> (entries: [String], bytes: Int) {
        var entries: [String] = []
        var entryBytes = 0
        var physicalLines = 0

        func appendLine(_ range: Range<Int>) throws {
            guard physicalLines < maximumScriptFileListPhysicalLines else {
                throw SwiftPodsError(
                    "File list contains more than \(maximumScriptFileListPhysicalLines) physical lines", file: file)
            }
            physicalLines += 1
            guard range.count <= maximumScriptFileListLineBytes else {
                throw SwiftPodsError(
                    "File list contains a line over \(maximumScriptFileListLineBytes) bytes", file: file)
            }
            // Empty physical lines still consume the line budget, but need no allocation or UTF-8 decoding.
            guard !range.isEmpty else { return }
            guard let line = String(data: Data(data[range]), encoding: .utf8) else {
                throw SwiftPodsError("File list must be valid UTF-8", file: file)
            }
            let entry = line.trimmingCharacters(in: .whitespaces)
            guard !entry.isEmpty, !entry.hasPrefix("#") else { return }
            let bytes = entry.utf8.count
            guard bytes <= 4_096,
                !entry.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            else {
                throw SwiftPodsError(
                    "File list contains a control character or an entry over 4096 bytes", file: file)
            }
            guard entries.count < maximumScriptFileListEntries else {
                throw SwiftPodsError(
                    "File list contains more than \(maximumScriptFileListEntries) entries", file: file)
            }
            entries.append(entry)
            entryBytes += bytes + 1
        }

        var lineStart = 0
        var index = 0
        while index < data.count {
            let byte = data[index]
            guard index - lineStart <= maximumScriptFileListLineBytes else {
                throw SwiftPodsError(
                    "File list contains a line over \(maximumScriptFileListLineBytes) bytes", file: file)
            }
            if byte == 0x0A || byte == 0x0D {
                try appendLine(lineStart..<index)
                index += 1
                if byte == 0x0D, index < data.count, data[index] == 0x0A { index += 1 }
                lineStart = index
            } else {
                index += 1
            }
        }
        // A trailing newline terminates the preceding physical line; it does not create another one.
        if lineStart < data.count { try appendLine(lineStart..<data.count) }
        return (entries, entryBytes)
    }

    private static func sameFileObject(_ left: stat, _ right: stat) -> Bool {
        left.st_dev == right.st_dev && left.st_ino == right.st_ino && left.st_mode == right.st_mode
            && left.st_nlink == right.st_nlink && left.st_uid == right.st_uid && left.st_gid == right.st_gid
    }

    private static func sameFileSnapshot(_ left: stat, _ right: stat) -> Bool {
        sameFileObject(left, right) && left.st_size == right.st_size
            && left.st_mtimespec.tv_sec == right.st_mtimespec.tv_sec
            && left.st_mtimespec.tv_nsec == right.st_mtimespec.tv_nsec
            && left.st_ctimespec.tv_sec == right.st_ctimespec.tv_sec
            && left.st_ctimespec.tv_nsec == right.st_ctimespec.tv_nsec
    }

    /// Consumes and closes `descriptor`.
    private static func readBoundedRegularData(
        _ descriptor: Int32, maximumBytes: Int, kind: String, file: String
    ) throws -> Data {
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var information = stat()
        guard fstat(descriptor, &information) == 0, information.st_mode & S_IFMT == S_IFREG,
            information.st_size >= 0, information.st_size <= maximumBytes
        else { throw SwiftPodsError("\(kind) must be a regular file no larger than \(maximumBytes) bytes", file: file) }
        var data = Data()
        while let chunk = try handle.read(upToCount: min(1 << 20, maximumBytes + 1 - data.count)), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= maximumBytes else {
                throw SwiftPodsError("\(kind) exceeds the \(maximumBytes)-byte limit", file: file)
            }
        }
        var finalInformation = stat()
        guard fstat(descriptor, &finalInformation) == 0,
            finalInformation.st_dev == information.st_dev, finalInformation.st_ino == information.st_ino,
            finalInformation.st_mode == information.st_mode, finalInformation.st_nlink == information.st_nlink,
            finalInformation.st_size == information.st_size,
            finalInformation.st_mtimespec.tv_sec == information.st_mtimespec.tv_sec,
            finalInformation.st_mtimespec.tv_nsec == information.st_mtimespec.tv_nsec,
            finalInformation.st_ctimespec.tv_sec == information.st_ctimespec.tv_sec,
            finalInformation.st_ctimespec.tv_nsec == information.st_ctimespec.tv_nsec,
            data.count == Int(information.st_size)
        else { throw SwiftPodsError("\(kind) changed while it was being read", file: file) }
        return data
    }

    private static func privateStagingDirectory() throws -> URL {
        let base = FileManager.default.temporaryDirectory.standardizedFileURL
        var template = Array(base.appendingPathComponent("swiftpods-generated.XXXXXX").path.utf8CString)
        let created = template.withUnsafeMutableBufferPointer { buffer in mkdtemp(buffer.baseAddress) }
        guard created != nil else {
            throw SwiftPodsError("Cannot create private generated staging directory: \(String(cString: strerror(errno)))")
        }
        let path = String(
            decoding: template.lazy.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) },
            as: UTF8.self)
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        let descriptor = directory.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else {
            try? FileManager.default.removeItem(at: directory)
            throw SwiftPodsError("Cannot open private generated staging directory")
        }
        do {
            try GeneratedRoot.secureCreatedDescriptor(
                descriptor, mode: 0o700, kind: "Private generated staging directory")
            close(descriptor)
        } catch {
            close(descriptor)
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        var status = stat()
        guard directory.path.withCString({ lstat($0, &status) }) == 0,
            status.st_mode & S_IFMT == S_IFDIR, status.st_uid == geteuid(), status.st_mode & 0o077 == 0
        else {
            try? FileManager.default.removeItem(at: directory)
            throw SwiftPodsError("Private generated staging directory has unsafe ownership or permissions")
        }
        return directory
    }

    /// A reversible, filesystem-safe component. Common ASCII names keep their existing spelling.
    private static func pathComponent(_ text: String) -> String {
        let text = text.precomposedStringWithCanonicalMapping
        if text.isEmpty { return "%00" }
        let safe = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_. ".utf8)
        let encoded = text.utf8.enumerated().map { index, byte in
            safe.contains(byte) && !(index == 0 && byte == 0x2E)
                ? String(UnicodeScalar(byte)) : String(format: "%%%02X", byte)
        }.joined()
        return encoded.isEmpty || encoded == "." || encoded == ".." ? text.utf8.map { String(format: "%%%02X", $0) }.joined() : encoded
    }

    private static func fileSystemKey(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.lowercased()
    }

    private static func shortDigest(_ text: String) -> String {
        SHA256.hash(data: Data(text.precomposedStringWithCanonicalMapping.utf8)).prefix(6)
            .map { String(format: "%02x", $0) }.joined()
    }

    /// The platform a target builds for: the Podfile's, or the deployment target in the project's build settings.
    static func platform(of target: Target, in project: XcodeProject) -> Platform? {
        if let platform = target.platform, platform.deploymentTarget != nil { return platform }
        var settings: [String: PBXValue] = [:]
        let owners = (project.nativeTargets.first { $0.name == target.name }.map { [$0.id] } ?? []) + [project.rootID]
        for owner in owners {
            for id in project.configurations(of: owner).values.sorted() {
                for (key, value) in project[id]?["buildSettings"]?.dictionary ?? [:] where settings[key] == nil { settings[key] = value }
            }
        }
        let platforms: [(PlatformName, String, String)] = [
            (.ios, "iphoneos", "IPHONEOS_DEPLOYMENT_TARGET"), (.macos, "macosx", "MACOSX_DEPLOYMENT_TARGET"),
            (.tvos, "appletvos", "TVOS_DEPLOYMENT_TARGET"), (.watchos, "watchos", "WATCHOS_DEPLOYMENT_TARGET"),
            (.visionos, "xros", "XROS_DEPLOYMENT_TARGET"),
        ]
        let sdk = settings["SDKROOT"]?.string
        guard let (name, _, key) = platforms.first(where: { $0.0 == target.platform?.name || ($0.1 == sdk && target.platform == nil) }),
            let version = settings[key]?.string, Version(version) != nil
        else { return target.platform }
        return Platform(name: name, deploymentTarget: version)
    }

}
