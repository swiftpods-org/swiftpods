import CryptoKit
import Darwin
import Foundation
import SwiftPodsSecurity

/// A write-ahead record for the workspace transaction. The ordinary in-process rollback remains the fast path; this
/// journal retains enough descriptor/CAS evidence to finish that rollback after a crash, SIGKILL, or power loss.
final class InstallTransactionJournal {
    static let directoryName = ".swiftpods-transaction"
    private static let manifestName = "journal.json"
    private static let schema = 2
    // Recovery decodes this into both Foundation objects and Codable values. Keep the raw input well below a size
    // that could cause unbounded memory amplification even when every individual structural count is valid.
    private static let maximumManifestBytes = 64 * 1_024 * 1_024
    private static let maximumManifestStringBytes = 1 * 1_024 * 1_024
    private static let maximumManifestAggregateStringBytes = 24 * 1_024 * 1_024
    private static let maximumProjectBytes = 32 * 1_024 * 1_024
    private static let maximumTreeDepth = 64
    // 50k entries in one generated package (100k across all before/after snapshots) is already orders of magnitude
    // above a normal install.  At up to 16 JSON values per TreeMember, two million values leaves structural headroom
    // without reviving the former 22-million-token CPU/RAM amplification budget.
    private static let maximumTreeEntries = 50_000
    private static let maximumManifestTreeEntries = 100_000
    private static let maximumManifestAttributes = 16_384
    private static let maximumManifestJSONValues = 2_000_000
    private static let maximumGeneratedRecords = 2_048
    private static let maximumProjectRecords = 128
    private static let maximumPackageRecords = 128
    private static let maximumJournalEntries = 512
    private static let maximumRecoveryNanoseconds: UInt64 = 5 * 60 * 1_000_000_000

    private final class RecoveryDeadline {
        private let expiresAt: UInt64

        init() throws {
            let now = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
            let (expiresAt, overflow) = now.addingReportingOverflow(maximumRecoveryNanoseconds)
            guard !overflow else { throw SwiftPodsError("Cannot establish a bounded transaction recovery deadline") }
            self.expiresAt = expiresAt
        }

        func check() throws {
            guard clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) <= expiresAt else {
                throw SwiftPodsError(
                    "SwiftPods transaction recovery exceeded its 5 minute safety deadline; evidence was preserved")
            }
        }
    }

    enum LockPolicy: String, Codable, Equatable {
        /// No catalog metadata was consumed. The lock pathname is unrelated user state and is never inspected.
        case ignore
        /// Deployment consumed an existing catalog lock and must preserve that exact file.
        case preserve
        /// A normal catalog-backed install publishes the newly resolved lock at the commit boundary.
        case replace
    }

    enum Phase: String, Codable, Equatable {
        case active
        case committing
        case committed
        case rollingBack
        case committedCleaning
    }

    struct DirectoryToken: Codable, Equatable {
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

    struct EntryToken: Codable, Equatable {
        let device: UInt64
        let inode: UInt64
        let mode: UInt32
        let links: UInt64
        let owner: UInt32
        let group: UInt32
        let flags: UInt32
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
            flags = status.st_flags
            size = status.st_size
            modifiedSeconds = Int64(status.st_mtimespec.tv_sec)
            modifiedNanoseconds = Int64(status.st_mtimespec.tv_nsec)
            changedSeconds = Int64(status.st_ctimespec.tv_sec)
            changedNanoseconds = Int64(status.st_ctimespec.tv_nsec)
        }

        func representsAfterRename(_ other: Self) -> Bool {
            device == other.device && inode == other.inode && mode == other.mode
                && links == other.links && owner == other.owner && group == other.group
                && flags == other.flags && size == other.size
                && modifiedSeconds == other.modifiedSeconds
                && modifiedNanoseconds == other.modifiedNanoseconds
        }

        func hasEquivalentMetadata(to other: Self) -> Bool {
            mode == other.mode && owner == other.owner && group == other.group
                && flags == other.flags && size == other.size
                && modifiedSeconds == other.modifiedSeconds
                && modifiedNanoseconds == other.modifiedNanoseconds
        }

        /// Removing children necessarily changes link count, size, mtime, and ctime. Cleanup progress may relax only
        /// those directory fields; the object, type/mode, owner, group, and flags remain authenticated.
        func isSameDirectoryObject(as other: Self) -> Bool {
            device == other.device && inode == other.inode && mode == other.mode
                && owner == other.owner && group == other.group && flags == other.flags
                && mode & UInt32(S_IFMT) == UInt32(S_IFDIR)
        }
    }

    struct FileToken: Codable, Equatable {
        let entry: EntryToken
        let sha256: String
        let securitySHA256: String

        func representsAfterRename(_ other: Self) -> Bool {
            entry.representsAfterRename(other.entry)
                && sha256 == other.sha256 && securitySHA256 == other.securitySHA256
        }

        func isEquivalent(to other: Self) -> Bool {
            entry.hasEquivalentMetadata(to: other.entry)
                && sha256 == other.sha256 && securitySHA256 == other.securitySHA256
        }
    }

    struct TreeMember: Codable, Equatable {
        let entry: EntryToken
        let payloadSHA256: String?
        let securitySHA256: String?
    }

    struct TreeToken: Codable, Equatable {
        let members: [String: TreeMember]

        func preservesManagedMembers(of other: Self) -> Bool {
            let managed = members.filter { !GeneratedPackageMetadata.contains($0.key) }
            let previous = other.members.filter { !GeneratedPackageMetadata.contains($0.key) }
            guard Set(managed.keys) == Set(previous.keys) else { return false }
            return managed.allSatisfy { path, member in
                guard let before = previous[path], member.payloadSHA256 == before.payloadSHA256,
                    member.securitySHA256 == before.securitySHA256
                else { return false }
                return path.isEmpty
                    ? member.entry.isSameDirectoryObject(as: before.entry) : member.entry == before.entry
            } && GeneratedPackageMetadata.directories.allSatisfy { path in
                guard let root = members[path] else { return true }
                return root.entry.mode & UInt32(S_IFMT) == UInt32(S_IFDIR)
                    && root.entry.owner == geteuid()
            }
        }

        func representsAfterRename(_ other: Self) -> Bool {
            guard Set(members.keys) == Set(other.members.keys) else { return false }
            for (path, member) in members {
                guard let previous = other.members[path],
                    member.payloadSHA256 == previous.payloadSHA256,
                    member.securitySHA256 == previous.securitySHA256,
                    path.isEmpty
                        ? member.entry.representsAfterRename(previous.entry)
                        : member.entry == previous.entry
                else { return false }
            }
            return true
        }
    }

    struct ProjectRecord: Codable, Equatable {
        let file: String
        let parent: DirectoryToken
        let original: FileToken
        let desiredSHA256: String
        let backupName: String?
        let recoveryName: String?
        var backup: FileToken?
        var installed: FileToken?
    }

    struct PackageRecord: Codable, Equatable {
        let project: String
        let original: PackageResolved.DurableState
        let backupName: String?
        let originalFile: FileToken?
        let recoveryID: String
        var backup: FileToken?
        var installed: PackageResolved.DurableState?
        var recoveryStarted: Bool
    }

    struct GeneratedRecord: Codable, Equatable {
        enum Kind: String, Codable, Equatable {
            case publish
            case withdraw
        }

        let kind: Kind
        let name: String
        let rootBefore: TreeToken?
        // Also the exact rollback-staging state after an authorized resolver metadata update.
        var stagingBefore: TreeToken?
    }

    struct LockRecord: Codable, Equatable {
        let policy: LockPolicy
        let original: FileToken?
        let plannedSHA256: String?
        let temporaryName: String?
        let cleanupDirectoryName: String?
    }

    struct Manifest: Codable {
        let schema: Int
        let transactionID: String
        var phase: Phase
        let workspace: DirectoryToken
        let generatedRootName: String
        let generatedRoot: DirectoryToken
        let stagingName: String
        let staging: DirectoryToken
        // Expected rollback staging; advanced together with stagingBefore for resolver-owned metadata only.
        var initialStaging: [String: TreeToken]
        let lock: LockRecord
        var generated: [GeneratedRecord]
        var projects: [ProjectRecord]
        var packages: [PackageRecord]
    }

    private let directory: URL
    private let workspaceDescriptor: Int32
    private let journalDescriptor: Int32
    private let journalIdentity: DirectoryToken
    private let recoveryDeadline: RecoveryDeadline?
    private var manifest: Manifest
    private var finished = false

    deinit {
        close(journalDescriptor)
        close(workspaceDescriptor)
    }

    static func begin(
        directory: URL, workspaceDescriptor: Int32, generatedRoot: URL, stagingName: String,
        lockFile: URL, lockPolicy: LockPolicy = .ignore, plannedLock: Data?
    ) throws -> InstallTransactionJournal {
        var ownsWorkspaceDescriptor = true
        var ownedJournalDescriptor: Int32 = -1
        do {
            try requireWorkspace(workspaceDescriptor, at: directory)
            let generatedRootName = generatedRoot.lastPathComponent
            try requireComponent(generatedRootName)
            // Everything that the transaction may have to remove must be removable before the first durable journal
            // pathname is created.  In particular, COPYFILE metadata must never turn the new journal into residue.
            try preflightGeneratedStaging(generatedRoot: generatedRoot, stagingName: stagingName)
            let lockName = lockFile.lastPathComponent
            try requireComponent(lockName)
            if lockPolicy == .replace,
                let existingLock = try captureOptionalFile(
                    named: lockName, in: workspaceDescriptor, maximumBytes: SwiftPodsLock.maximumJournalBytes,
                    diagnostic: lockFile)
            {
                try requireRollbackSafe(existingLock.entry.flags, kind: "SwiftPods.lock")
            }
            guard directoryName.withCString({
                mkdirat(workspaceDescriptor, $0, 0o700)
            }) == 0 else {
                throw SwiftPodsError(
                    errno == EEXIST
                        ? "An unfinished SwiftPods transaction requires recovery"
                        : "Cannot create the SwiftPods transaction journal: \(String(cString: strerror(errno)))")
            }
            let journal = directoryName.withCString {
                openat(workspaceDescriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            }
            guard journal >= 0 else {
                throw SwiftPodsError("Cannot open the SwiftPods transaction journal")
            }
            ownedJournalDescriptor = journal
            try securePrivateDirectory(journal, kind: "SwiftPods transaction journal")
            let journalIdentity = try boundJournalIdentity(
                descriptor: journal, workspaceDescriptor: workspaceDescriptor)
            // Persist the journal directory entry before any workspace mutation can be made recoverable through it.
            // journal.json itself is synchronized by persist(); its parent is this already durable directory.
            guard fsync(workspaceDescriptor) == 0 else {
                throw SwiftPodsError("Cannot synchronize the SwiftPods transaction journal directory")
            }

            let generated = try openDirectory(generatedRoot, kind: "generated root")
            defer { close(generated) }
            let staging = stagingName.withCString {
                openat(generated, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            }
            guard staging >= 0 else {
                throw SwiftPodsError("Cannot open generated transaction staging for journaling")
            }
            defer { close(staging) }
            try securePrivateDirectory(staging, kind: "generated transaction staging")
            try synchronizeTree(in: staging)
            guard fsync(generated) == 0 else {
                throw SwiftPodsError("Cannot synchronize generated staging publication")
            }
            let workspaceStatus = try directoryStatus(workspaceDescriptor, kind: "workspace")
            let generatedStatus = try directoryStatus(generated, kind: "generated root")
            let stagingStatus = try directoryStatus(staging, kind: "generated transaction staging")
            let initialStaging = try captureChildren(in: staging)
            let lock: FileToken?
            switch lockPolicy {
            case .ignore:
                lock = nil
            case .preserve, .replace:
                lock = try captureOptionalFile(
                    named: lockName, in: workspaceDescriptor, maximumBytes: SwiftPodsLock.maximumJournalBytes,
                    diagnostic: lockFile)
            }
            guard (lockPolicy == .replace) == (plannedLock != nil) else {
                throw SwiftPodsError("SwiftPods transaction lock policy is inconsistent")
            }
            let transactionID = UUID().uuidString
            let value = Manifest(
                schema: schema, transactionID: transactionID, phase: .active,
                workspace: .init(workspaceStatus),
                generatedRootName: generatedRootName, generatedRoot: .init(generatedStatus), stagingName: stagingName,
                staging: .init(stagingStatus), initialStaging: initialStaging,
                lock: LockRecord(
                    policy: lockPolicy, original: lock, plannedSHA256: plannedLock.map(sha256),
                    temporaryName: lockPolicy == .replace ? ".\(lockName).tmp-\(UUID().uuidString)" : nil,
                    cleanupDirectoryName: lockPolicy == .replace
                        ? ".swiftpods-lock-journal-\(UUID().uuidString)" : nil),
                generated: [], projects: [], packages: [])
            let result = InstallTransactionJournal(
                directory: directory, workspaceDescriptor: workspaceDescriptor,
                journalDescriptor: journal, journalIdentity: journalIdentity,
                recoveryDeadline: nil, manifest: value)
            ownsWorkspaceDescriptor = false
            ownedJournalDescriptor = -1
            try result.persist()
            // persist() synchronizes journal.json and the private journal directory. Repeat the workspace barrier so
            // the journal directory entry itself is durably linked before the caller performs its first mutation.
            guard fsync(result.workspaceDescriptor) == 0 else {
                throw SwiftPodsError("Cannot synchronize the durable SwiftPods transaction journal")
            }
            return result
        } catch {
            if ownedJournalDescriptor >= 0 { close(ownedJournalDescriptor) }
            if ownsWorkspaceDescriptor { close(workspaceDescriptor) }
            throw error
        }
    }

    static func recover(
        directory: URL, workspaceDescriptor: Int32,
        _packageRecoveryHook: ((URL, String) throws -> Void)? = nil
    ) throws {
        var ownsWorkspaceDescriptor = true
        var ownedJournalDescriptor: Int32 = -1
        do {
            let deadline = try RecoveryDeadline()
            try requireWorkspace(workspaceDescriptor, at: directory)
            try deadline.check()
            var linked = stat()
            let found = directoryName.withCString {
                fstatat(workspaceDescriptor, $0, &linked, AT_SYMLINK_NOFOLLOW)
            }
            if found != 0, errno == ENOENT {
                close(workspaceDescriptor)
                ownsWorkspaceDescriptor = false
                return
            }
            guard found == 0, linked.st_mode & S_IFMT == S_IFDIR else {
                throw SwiftPodsError("The SwiftPods transaction journal is not a real directory")
            }
            let journal = directoryName.withCString {
                openat(workspaceDescriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            }
            guard journal >= 0 else {
                throw SwiftPodsError("Cannot safely open the SwiftPods transaction journal")
            }
            ownedJournalDescriptor = journal
            try securePrivateDirectory(journal, kind: "SwiftPods transaction journal")
            let journalIdentity = try boundJournalIdentity(
                descriptor: journal, workspaceDescriptor: workspaceDescriptor)
            var journalNames = try names(
                in: journal, maximum: maximumJournalEntries, deadline: deadline)
            if journalNames.isEmpty {
                try verifyJournalPathBinding(
                    descriptor: journal, identity: journalIdentity,
                    workspaceDescriptor: workspaceDescriptor)
                guard directoryName.withCString({
                    unlinkat(workspaceDescriptor, $0, AT_REMOVEDIR)
                }) == 0, fsync(workspaceDescriptor) == 0 else {
                    throw SwiftPodsError("Cannot finish removing an empty SwiftPods transaction journal")
                }
                close(journal)
                ownedJournalDescriptor = -1
                close(workspaceDescriptor)
                ownsWorkspaceDescriptor = false
                return
            }
            let diagnosticRoot = directory.appendingPathComponent(directoryName)
            var decoded: Manifest
            if journalNames.contains(manifestName) {
                let data = try readFile(
                    named: manifestName, in: journal, maximumBytes: maximumManifestBytes,
                    diagnostic: diagnosticRoot.appendingPathComponent(manifestName)).data
                decoded = try decodeManifest(data, deadline: deadline)
                let updateName = journalUpdateName(transactionID: decoded.transactionID)
                if journalNames.contains(updateName) {
                    let updateData = try readFile(
                        named: updateName, in: journal, maximumBytes: maximumManifestBytes,
                        diagnostic: diagnosticRoot.appendingPathComponent(updateName)).data
                    let update = try decodeManifest(updateData, deadline: deadline)
                    guard isSuccessor(update, of: decoded) else {
                        throw SwiftPodsError(
                            "SwiftPods transaction journal update is not a valid successor; recovery evidence was preserved")
                    }
                    try verifyJournalPathBinding(
                        descriptor: journal, identity: journalIdentity,
                        workspaceDescriptor: workspaceDescriptor)
                    guard updateName.withCString({ source in
                        manifestName.withCString { renameat(journal, source, journal, $0) }
                    }) == 0, fsync(journal) == 0 else {
                        throw SwiftPodsError("Cannot publish the durable SwiftPods transaction journal update")
                    }
                    try verifyJournalPathBinding(
                        descriptor: journal, identity: journalIdentity,
                        workspaceDescriptor: workspaceDescriptor)
                    decoded = update
                    journalNames.removeAll { $0 == updateName }
                }
            } else {
                // A crash during the very first persist can leave only the fsynced, self-identifying update. Promote
                // that one exact transaction name; similarly named or additional entries remain untouched as evidence.
                guard journalNames.count == 1, let updateName = journalNames.first,
                    let transactionID = transactionID(fromJournalUpdateName: updateName)
                else {
                    throw SwiftPodsError(
                        "SwiftPods transaction journal is missing its manifest; recovery evidence was preserved")
                }
                let updateData = try readFile(
                    named: updateName, in: journal, maximumBytes: maximumManifestBytes,
                    diagnostic: diagnosticRoot.appendingPathComponent(updateName)).data
                decoded = try decodeManifest(updateData, deadline: deadline)
                guard decoded.transactionID == transactionID else {
                    throw SwiftPodsError(
                        "SwiftPods transaction journal update has the wrong identity; recovery evidence was preserved")
                }
                try verifyJournalPathBinding(
                    descriptor: journal, identity: journalIdentity,
                    workspaceDescriptor: workspaceDescriptor)
                guard updateName.withCString({ source in
                    manifestName.withCString { renameat(journal, source, journal, $0) }
                }) == 0, fsync(journal) == 0 else {
                    throw SwiftPodsError("Cannot publish the initial SwiftPods transaction journal")
                }
                try verifyJournalPathBinding(
                    descriptor: journal, identity: journalIdentity,
                    workspaceDescriptor: workspaceDescriptor)
                journalNames = [manifestName]
            }
            let allowedNames = Set(
                [manifestName]
                    + decoded.projects.compactMap(\.backupName)
                    + decoded.packages.compactMap(\.backupName))
            guard Set(journalNames).isSubset(of: allowedNames) else {
                throw SwiftPodsError("SwiftPods transaction journal contains unknown recovery evidence")
            }
            let result = InstallTransactionJournal(
                directory: directory, workspaceDescriptor: workspaceDescriptor,
                journalDescriptor: journal, journalIdentity: journalIdentity,
                recoveryDeadline: deadline, manifest: decoded)
            ownsWorkspaceDescriptor = false
            ownedJournalDescriptor = -1
            try result.recover(_packageRecoveryHook: _packageRecoveryHook)
        } catch {
            if ownedJournalDescriptor >= 0 { close(ownedJournalDescriptor) }
            if ownsWorkspaceDescriptor { close(workspaceDescriptor) }
            throw error
        }
    }

    private init(
        directory: URL, workspaceDescriptor: Int32, journalDescriptor: Int32,
        journalIdentity: DirectoryToken, recoveryDeadline: RecoveryDeadline?, manifest: Manifest
    ) {
        self.directory = directory
        self.workspaceDescriptor = workspaceDescriptor
        self.journalDescriptor = journalDescriptor
        self.journalIdentity = journalIdentity
        self.recoveryDeadline = recoveryDeadline
        self.manifest = manifest
    }

    var lockTemporaryName: String? { manifest.lock.temporaryName }
    var lockCleanupDirectoryName: String? { manifest.lock.cleanupDirectoryName }

    /// The caller invokes this at the last descriptor-anchored boundary before changing workspace state.  It cannot
    /// make a hostile same-UID rename impossible, but it closes the unbounded gap between journal persistence and a
    /// later mutation and ensures every normal mutation path is paired with the still-linked journal inode.
    func verifyReadyForWorkspaceMutation() throws {
        guard (manifest.phase == .active || manifest.phase == .committing), !finished else {
            throw SwiftPodsError("SwiftPods transaction journal is not ready for a workspace mutation")
        }
        try verifyJournalPathBinding()
    }

    func prepareGenerated(_ kind: GeneratedRecord.Kind, name: String) throws {
        try requireActive()
        try Self.requireComponent(name)
        guard !manifest.generated.contains(where: { $0.name == name }) else {
            throw SwiftPodsError("Generated transaction entry was prepared more than once: \(name)")
        }
        let descriptors = try generatedDescriptors(requiresStaging: true)
        defer {
            close(descriptors.staging!)
            close(descriptors.root)
        }
        try Self.requireRollbackSafeDirectory(descriptors.root, kind: "generated root")
        try Self.requireRollbackSafeDirectory(descriptors.staging!, kind: "generated staging")
        let root = try Self.captureTree(named: name, in: descriptors.root)
        let staging = try Self.captureTree(named: name, in: descriptors.staging!)
        if kind == .publish, staging == nil {
            throw SwiftPodsError("Generated publication has no staged source: \(name)")
        }
        if kind == .withdraw, staging != nil {
            throw SwiftPodsError("Generated withdrawal staging is not empty: \(name)")
        }
        manifest.generated.append(
            GeneratedRecord(kind: kind, name: name, rootBefore: root, stagingBefore: staging))
        try persist()
    }

    /// Xcode owns derived package metadata, but never Package.swift, sources or binary payloads. Advance the complete
    /// rollback/commit snapshots only at this explicit resolver boundary, retaining exact cleanup protection. A crash
    /// before persistence leaves the old token in place and therefore preserves the changed tree as evidence.
    func confirmResolverGeneratedMetadata() throws {
        try requireActive()
        let descriptors = try generatedDescriptors(requiresStaging: true)
        defer {
            close(descriptors.staging!)
            close(descriptors.root)
        }
        var updates: [Int: TreeToken] = [:]
        for (index, record) in manifest.generated.enumerated() {
            guard record.kind == .publish, GeneratedPackageMetadata.isPackage(record.name) else { continue }
            guard let before = record.stagingBefore,
                let current = try Self.captureTree(named: record.name, in: descriptors.root),
                current.preservesManagedMembers(of: before),
                Self.treeMatches(try Self.captureTree(named: record.name, in: descriptors.staging!), record.rootBefore)
            else { throw SwiftPodsError("Resolver changed managed generated package contents: \(record.name)") }
            updates[index] = current
        }
        guard !updates.isEmpty else { return }
        try Self.synchronizeTree(in: descriptors.root)
        for (index, current) in updates {
            manifest.generated[index].stagingBefore = current
            manifest.initialStaging[manifest.generated[index].name] = current
        }
        try persist()
    }

    /// Completes the durability half of a cross-directory generated-tree rename. Both directory entries must be on
    /// stable storage before any later project/lock state can advance toward commit.
    func synchronizeGeneratedMutation() throws {
        try requireActive()
        let descriptors = try generatedDescriptors(requiresStaging: true)
        defer {
            close(descriptors.staging!)
            close(descriptors.root)
        }
        guard fsync(descriptors.staging!) == 0, fsync(descriptors.root) == 0 else {
            throw SwiftPodsError("Cannot synchronize generated transaction publication")
        }
        try generatedDescriptorsIdentityCheck(root: descriptors.root, staging: descriptors.staging!)
    }

    func prepareProject(file: URL, projectDescriptor: Int32? = nil, desired: Data) throws {
        try requireActive()
        guard !manifest.projects.contains(where: { $0.file == file.path }) else {
            throw SwiftPodsError("Xcode project transaction entry was prepared more than once", file: file.path)
        }
        let opened = try Self.openParent(
            of: file, retainedDescriptor: projectDescriptor,
            kind: "Xcode project transaction file")
        defer { close(opened.descriptor) }
        try Self.requireRollbackSafeDirectory(opened.descriptor, kind: "Xcode project parent")
        let original = try Self.readFile(
            named: opened.name, in: opened.descriptor, maximumBytes: Self.maximumProjectBytes,
            diagnostic: file).token
        try Self.requireRollbackSafe(original.entry.flags, kind: "Xcode project file")
        let desiredSHA256 = Self.sha256(desired)
        let needsBackup = original.sha256 != desiredSHA256
        let backupName = needsBackup ? "project-\(UUID().uuidString).backup" : nil
        let recoveryName = needsBackup ? ".\(opened.name).swiftpods-recovery-\(UUID().uuidString)" : nil
        let index = manifest.projects.count
        manifest.projects.append(
            ProjectRecord(
                file: file.path, parent: opened.token, original: original,
                desiredSHA256: desiredSHA256, backupName: backupName, recoveryName: recoveryName,
                backup: nil, installed: nil))
        try persist()
        guard let backupName else { return }
        let backup = try copyToJournal(
            source: opened.name, sourceParent: opened.descriptor, destination: backupName,
            maximumBytes: Self.maximumProjectBytes, diagnostic: file)
        guard backup.isEquivalent(to: original) else {
            throw SwiftPodsError("Durable Xcode project backup does not match its source", file: file.path)
        }
        manifest.projects[index].backup = backup
        try persist()
    }

    func confirmProject(file: URL, projectDescriptor: Int32? = nil) throws {
        try requireActive()
        guard let index = manifest.projects.firstIndex(where: { $0.file == file.path }) else {
            throw SwiftPodsError("Xcode project transaction entry was not prepared", file: file.path)
        }
        let record = manifest.projects[index]
        let opened = try Self.openParent(
            of: file, retainedDescriptor: projectDescriptor,
            kind: "Xcode project transaction file")
        defer { close(opened.descriptor) }
        guard opened.token == record.parent else {
            throw SwiftPodsError("Xcode project parent changed during the transaction", file: file.path)
        }
        let installed = try Self.readFile(
            named: opened.name, in: opened.descriptor, maximumBytes: Self.maximumProjectBytes,
            diagnostic: file).token
        guard installed.sha256 == record.desiredSHA256 else {
            throw SwiftPodsError("Installed Xcode project bytes do not match the prepared transaction", file: file.path)
        }
        manifest.projects[index].installed = installed
        try persist()
    }

    func preparePackage(
        project: URL, projectDescriptor: Int32? = nil, original: PackageResolved.PathSnapshot
    ) throws {
        try requireActive()
        guard !manifest.packages.contains(where: { $0.project == project.path }) else {
            throw SwiftPodsError("Package.resolved transaction entry was prepared more than once", file: project.path)
        }
        let file = PackageResolved.location(project: project)
        try PackageResolved.requireRollbackSafe(original, file: file)
        guard try PackageResolved.currentSnapshot(
            project: project, projectDescriptor: projectDescriptor) == original
        else {
            throw SwiftPodsError(
                "Package.resolved changed before durable transaction preparation",
                file: PackageResolved.location(project: project).path)
        }
        let durable = PackageResolved.durableState(of: original)
        var source: (descriptor: Int32, name: String)?
        var originalFile: FileToken?
        defer { if let source { close(source.descriptor) } }
        if original.data != nil {
            let descriptor = try PackageResolved.duplicateResolvedParent(
                project: project, projectDescriptor: projectDescriptor, matching: original)
            do {
                _ = try Self.directoryStatus(
                    descriptor, kind: "Package.resolved transaction file parent")
            } catch {
                close(descriptor)
                throw error
            }
            source = (descriptor, "Package.resolved")
            originalFile = try Self.readFile(
                named: source!.name, in: source!.descriptor, maximumBytes: SwiftPodsLock.maximumJournalBytes,
                diagnostic: file).token
        }
        let backupName = originalFile == nil ? nil : "package-\(UUID().uuidString).backup"
        let index = manifest.packages.count
        manifest.packages.append(
            PackageRecord(
                project: project.path, original: durable, backupName: backupName,
                originalFile: originalFile, recoveryID: UUID().uuidString,
                backup: nil, installed: nil, recoveryStarted: false))
        try persist()
        if let source, let originalFile, let backupName {
            let backup = try copyToJournal(
                source: source.name, sourceParent: source.descriptor, destination: backupName,
                maximumBytes: SwiftPodsLock.maximumJournalBytes, diagnostic: file)
            guard backup.isEquivalent(to: originalFile) else {
                throw SwiftPodsError("Durable Package.resolved backup does not match its source", file: file.path)
            }
            manifest.packages[index].backup = backup
            try persist()
        }
        guard try PackageResolved.currentSnapshot(
            project: project, projectDescriptor: projectDescriptor) == original
        else {
            throw SwiftPodsError(
                "Package.resolved changed while its durable backup was created", file: file.path)
        }
    }

    func confirmPackage(
        project: URL, projectDescriptor: Int32? = nil, installed: PackageResolved.PathSnapshot
    ) throws {
        try requireActive()
        guard let index = manifest.packages.firstIndex(where: { $0.project == project.path }) else {
            throw SwiftPodsError("Package.resolved transaction entry was not prepared", file: project.path)
        }
        guard try PackageResolved.currentSnapshot(
            project: project, projectDescriptor: projectDescriptor) == installed
        else {
            throw SwiftPodsError(
                "Package.resolved changed before durable transaction confirmation",
                file: PackageResolved.location(project: project).path)
        }
        try PackageResolved.synchronize(
            installed, project: project, projectDescriptor: projectDescriptor)
        guard try PackageResolved.currentSnapshot(
            project: project, projectDescriptor: projectDescriptor) == installed
        else {
            throw SwiftPodsError(
                "Package.resolved changed after durable transaction synchronization",
                file: PackageResolved.location(project: project).path)
        }
        manifest.packages[index].installed = PackageResolved.durableState(of: installed)
        try persist()
    }

    func verifyFinalStates(projectDescriptors: [String: Int32]) throws {
        try requireActive()
        for record in manifest.projects {
            guard let installed = record.installed else {
                throw SwiftPodsError("Xcode project transaction was not durably confirmed", file: record.file)
            }
            let file = URL(fileURLWithPath: record.file)
            let projectPath = file.deletingLastPathComponent().path
            guard let descriptor = projectDescriptors[projectPath] else {
                throw SwiftPodsError("Xcode project transaction lost its retained directory", file: record.file)
            }
            let current = try Self.readFile(
                named: file.lastPathComponent, in: descriptor,
                maximumBytes: Self.maximumProjectBytes, diagnostic: file).token
            var parentStatus = stat()
            guard fstat(descriptor, &parentStatus) == 0,
                DirectoryToken(parentStatus) == record.parent, current == installed
            else {
                throw SwiftPodsError("Xcode project changed before durable transaction commit", file: record.file)
            }
        }
        for record in manifest.packages {
            guard let installed = record.installed else {
                throw SwiftPodsError(
                    "Package.resolved transaction was not durably confirmed",
                    file: PackageResolved.location(project: URL(fileURLWithPath: record.project)).path)
            }
            let project = URL(fileURLWithPath: record.project)
            guard let descriptor = projectDescriptors[project.path] else {
                throw SwiftPodsError(
                    "Package.resolved transaction lost its retained project directory",
                    file: PackageResolved.location(project: project).path)
            }
            guard PackageResolved.matches(
                try PackageResolved.currentSnapshot(project: project, projectDescriptor: descriptor),
                durable: installed)
            else {
                throw SwiftPodsError(
                    "Package.resolved changed before durable transaction commit",
                    file: PackageResolved.location(project: project).path)
            }
        }
        try verifyGeneratedCommitted()
    }

    func prepareCommit() throws {
        try requireActive()
        guard manifest.lock.policy == .replace, manifest.lock.plannedSHA256 != nil,
            manifest.lock.temporaryName != nil
        else {
            throw SwiftPodsError("A lock-less transaction has no separate committing phase")
        }
        manifest.phase = .committing
        try persist()
    }

    func markCommitted() throws {
        guard manifest.phase == .active || manifest.phase == .committing else {
            throw SwiftPodsError("SwiftPods transaction is already committed")
        }
        manifest.phase = .committed
        try persist()
    }

    func finishRolledBack() throws {
        try verifyJournalPathBinding()
        if manifest.phase == .committing {
            guard manifest.lock.policy == .replace else {
                throw SwiftPodsError("Only a lock-replacing transaction may enter the committing phase")
            }
            let current = try Self.captureOptionalFile(
                named: SwiftPodsLock.fileName, in: workspaceDescriptor,
                maximumBytes: SwiftPodsLock.maximumJournalBytes,
                diagnostic: directory.appendingPathComponent(SwiftPodsLock.fileName))
            if !Self.fileMatches(current, manifest.lock.original),
                let planned = manifest.lock.plannedSHA256, current?.sha256 == planned
            {
                throw SwiftPodsError(
                    "SwiftPods.lock reached the planned commit state; recovery evidence was preserved",
                    file: directory.appendingPathComponent(SwiftPodsLock.fileName).path)
            }
            manifest.phase = .active
            try persist()
        }
        guard manifest.phase == .active else {
            throw SwiftPodsError("Cannot finish a committed SwiftPods rollback")
        }
        try recoverActive()
    }

    func finishCommitted(_beforeStagingCleanup: (() throws -> Void)? = nil) throws {
        try verifyJournalPathBinding()
        guard manifest.phase == .committed else {
            throw SwiftPodsError("Cannot finish an uncommitted SwiftPods transaction")
        }
        try recoverCommitted(_beforeStagingCleanup: _beforeStagingCleanup)
    }

    private func recover(_packageRecoveryHook: ((URL, String) throws -> Void)? = nil) throws {
        try recoveryDeadline?.check()
        try verifyJournalPathBinding()
        guard DirectoryToken(try Self.directoryStatus(workspaceDescriptor, kind: "workspace")) == manifest.workspace else {
            throw SwiftPodsError("The workspace no longer matches its SwiftPods recovery journal")
        }
        switch manifest.phase {
        case .active:
            try recoverActive(_packageRecoveryHook: _packageRecoveryHook)
        case .committing:
            guard manifest.lock.policy == .replace else {
                throw SwiftPodsError("SwiftPods transaction has an inconsistent committing phase")
            }
            let current = try Self.captureOptionalFile(
                named: SwiftPodsLock.fileName, in: workspaceDescriptor,
                maximumBytes: SwiftPodsLock.maximumJournalBytes,
                diagnostic: directory.appendingPathComponent(SwiftPodsLock.fileName))
            if let planned = manifest.lock.plannedSHA256, current?.sha256 == planned {
                manifest.phase = .committed
                try persist()
                try recoverCommitted()
            } else if Self.fileMatches(current, manifest.lock.original) {
                manifest.phase = .active
                try persist()
                try recoverActive(_packageRecoveryHook: _packageRecoveryHook)
            } else {
                // The lock writer uses an atomic CAS and never writes partial bytes. An unknown third state belongs to
                // a non-cooperating writer; preserve it and roll back only files whose exact journal tokens still match.
                manifest.phase = .active
                try persist()
                try recoverActive(_packageRecoveryHook: _packageRecoveryHook)
            }
        case .committed:
            try recoverCommitted()
        case .rollingBack:
            try recoverActiveCleanup()
        case .committedCleaning:
            try recoverCommittedCleanup()
        }
    }

    private func recoverActive(_packageRecoveryHook: ((URL, String) throws -> Void)? = nil) throws {
        try recoveryDeadline?.check()
        if manifest.generated.isEmpty, manifest.projects.isEmpty, manifest.packages.isEmpty {
            let descriptors = try generatedDescriptors(requiresStaging: false)
            let stagingIsMissing = descriptors.staging == nil
            if let staging = descriptors.staging { close(staging) }
            close(descriptors.root)
            if stagingIsMissing {
                try cleanupLockTemporary()
                try cleanupJournal()
                return
            }
        }
        for index in manifest.packages.indices.reversed() {
            try recoveryDeadline?.check()
            try recoverPackage(at: index, _packageRecoveryHook: _packageRecoveryHook)
        }
        for record in manifest.projects.reversed() {
            try recoveryDeadline?.check()
            try recoverProject(record)
        }
        for record in manifest.generated.reversed() {
            try recoveryDeadline?.check()
            try recoverGenerated(record)
        }
        try verifyOriginalStates(allowsCleanupProgress: false)
        manifest.phase = .rollingBack
        try persist()
        try recoverActiveCleanup()
    }

    private func recoverActiveCleanup() throws {
        try recoveryDeadline?.check()
        guard manifest.phase == .rollingBack else {
            throw SwiftPodsError("SwiftPods transaction is not in rollback cleanup")
        }
        try verifyOriginalStates(allowsCleanupProgress: true)
        try cleanupStaging(expected: manifest.initialStaging, allowsMissing: true)
        try cleanupProjectRecoveryFiles(committed: false)
        try cleanupLockTemporary()
        try cleanupJournal()
    }

    private func recoverCommitted(_beforeStagingCleanup: (() throws -> Void)? = nil) throws {
        try recoveryDeadline?.check()
        try verifyCommittedStates(allowsMissingStaging: false)
        manifest.phase = .committedCleaning
        try persist()
        try _beforeStagingCleanup?()
        try recoverCommittedCleanup()
    }

    private func recoverCommittedCleanup() throws {
        try recoveryDeadline?.check()
        guard manifest.phase == .committedCleaning else {
            throw SwiftPodsError("SwiftPods transaction is not in committed cleanup")
        }
        try verifyCommittedStates(allowsMissingStaging: true)
        try cleanupStaging(expected: committedStaging(), allowsMissing: true)
        try cleanupProjectRecoveryFiles(committed: true)
        try cleanupLockTemporary()
        try cleanupJournal()
    }

    private func requireActive() throws {
        guard manifest.phase == .active, !finished else {
            throw SwiftPodsError("SwiftPods transaction journal is not active")
        }
        try verifyJournalPathBinding()
    }

    private func recoverProject(_ record: ProjectRecord) throws {
        try verifyJournalPathBinding()
        let file = URL(fileURLWithPath: record.file)
        let opened = try Self.openParent(of: file, kind: "Xcode project recovery file")
        defer { close(opened.descriptor) }
        guard opened.token == record.parent else {
            throw SwiftPodsError("Xcode project recovery parent changed; evidence was preserved", file: record.file)
        }
        let current = try Self.readFile(
            named: opened.name, in: opened.descriptor, maximumBytes: Self.maximumProjectBytes,
            diagnostic: file).token
        if current.isEquivalent(to: record.original) {
            try cleanupProjectRecoveryFile(record, parent: opened.descriptor, expectedCurrent: current)
            return
        }
        guard current.sha256 == record.desiredSHA256, let backupName = record.backupName,
            let recoveryName = record.recoveryName
        else {
            throw SwiftPodsError(
                "Xcode project has an unknown state after an interrupted transaction; recovery evidence was preserved",
                file: record.file)
        }
        let backup = try validatedBackup(
            named: backupName, recorded: record.backup, original: record.original,
            maximumBytes: Self.maximumProjectBytes, diagnostic: file)
        var recovery = try Self.captureOptionalFile(
            named: recoveryName, in: opened.descriptor, maximumBytes: Self.maximumProjectBytes,
            diagnostic: file.deletingLastPathComponent().appendingPathComponent(recoveryName))
        if recovery == nil {
            recovery = try copyFile(
                source: backupName, sourceParent: journalDescriptor,
                destination: recoveryName, destinationParent: opened.descriptor,
                maximumBytes: Self.maximumProjectBytes, diagnostic: file)
        }
        guard let recovery, recovery.isEquivalent(to: backup), recovery.isEquivalent(to: record.original) else {
            throw SwiftPodsError(
                "Xcode project recovery source changed; evidence was preserved", file: record.file)
        }
        let currentAgain = try Self.readFile(
            named: opened.name, in: opened.descriptor, maximumBytes: Self.maximumProjectBytes,
            diagnostic: file).token
        let recoveryAgain = try Self.readFile(
            named: recoveryName, in: opened.descriptor, maximumBytes: Self.maximumProjectBytes,
            diagnostic: file.deletingLastPathComponent().appendingPathComponent(recoveryName)).token
        guard currentAgain == current, recoveryAgain == recovery else {
            throw SwiftPodsError("Xcode project changed during crash recovery; evidence was preserved", file: record.file)
        }
        guard recoveryName.withCString({ source in
            opened.name.withCString {
                renameatx_np(opened.descriptor, source, opened.descriptor, $0, UInt32(RENAME_SWAP))
            }
        }) == 0 else {
            throw SwiftPodsError("Cannot atomically restore the Xcode project after an interrupted transaction", file: record.file)
        }
        guard fsync(opened.descriptor) == 0 else {
            throw SwiftPodsError("Cannot synchronize Xcode project crash recovery", file: record.file)
        }
        let restored = try Self.readFile(
            named: opened.name, in: opened.descriptor, maximumBytes: Self.maximumProjectBytes,
            diagnostic: file).token
        let displaced = try Self.readFile(
            named: recoveryName, in: opened.descriptor, maximumBytes: Self.maximumProjectBytes,
            diagnostic: file.deletingLastPathComponent().appendingPathComponent(recoveryName)).token
        guard restored.isEquivalent(to: record.original), displaced.representsAfterRename(current) else {
            throw SwiftPodsError(
                "Xcode project changed during crash recovery; both entries were preserved", file: record.file)
        }
        try cleanupProjectRecoveryFile(record, parent: opened.descriptor, expectedCurrent: restored)
    }

    private func cleanupProjectRecoveryFile(
        _ record: ProjectRecord, parent: Int32, expectedCurrent: FileToken
    ) throws {
        guard let recoveryName = record.recoveryName else { return }
        guard let token = try Self.captureOptionalFile(
            named: recoveryName, in: parent, maximumBytes: Self.maximumProjectBytes,
            diagnostic: URL(fileURLWithPath: record.file).deletingLastPathComponent()
                .appendingPathComponent(recoveryName))
        else { return }
        let allowed = token.isEquivalent(to: record.original)
            || token.sha256 == record.desiredSHA256
            || record.installed.map { token.isEquivalent(to: $0) || token.representsAfterRename($0) } == true
        guard allowed else {
            throw SwiftPodsError(
                "Xcode project recovery entry has unknown contents; evidence was preserved",
                file: URL(fileURLWithPath: record.file).deletingLastPathComponent()
                    .appendingPathComponent(recoveryName).path)
        }
        let file = URL(fileURLWithPath: record.file)
        let current = try Self.readFile(
            named: file.lastPathComponent, in: parent, maximumBytes: Self.maximumProjectBytes,
            diagnostic: file).token
        guard current == expectedCurrent else {
            throw SwiftPodsError("Xcode project changed before recovery cleanup", file: record.file)
        }
        let immediatelyBefore = try Self.readFile(
            named: recoveryName, in: parent, maximumBytes: Self.maximumProjectBytes,
            diagnostic: file.deletingLastPathComponent().appendingPathComponent(recoveryName)).token
        guard immediatelyBefore == token,
            recoveryName.withCString({ unlinkat(parent, $0, 0) }) == 0,
            fsync(parent) == 0
        else {
            throw SwiftPodsError("Cannot safely remove Xcode project recovery evidence", file: record.file)
        }
    }

    private func recoverPackage(
        at index: Int, _packageRecoveryHook: ((URL, String) throws -> Void)? = nil
    ) throws {
        try verifyJournalPathBinding()
        var record = manifest.packages[index]
        let project = URL(fileURLWithPath: record.project)
        let file = PackageResolved.location(project: project)
        let current = try PackageResolved.currentSnapshot(project: project)
        if PackageResolved.representsOriginal(current, durable: record.original), !record.recoveryStarted {
            return
        }
        guard let installed = record.installed else {
            throw SwiftPodsError(
                "Package.resolved has an unknown state after an interrupted resolver; recovery evidence was preserved",
                file: file.path)
        }
        if !record.recoveryStarted {
            guard PackageResolved.matches(current, durable: installed) else {
                throw SwiftPodsError(
                    "Package.resolved has an unknown state after an interrupted resolver; recovery evidence was preserved",
                    file: file.path)
            }
            manifest.packages[index].recoveryStarted = true
            try persist()
            record = manifest.packages[index]
        }
        try _packageRecoveryHook?(project, record.recoveryID)
        var backupDescriptor: Int32?
        if let backupName = record.backupName, let originalFile = record.originalFile {
            _ = try validatedBackup(
                named: backupName, recorded: record.backup, original: originalFile,
                maximumBytes: SwiftPodsLock.maximumJournalBytes, diagnostic: file)
            let descriptor = backupName.withCString {
                openat(journalDescriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            }
            guard descriptor >= 0 else {
                throw SwiftPodsError("Cannot open durable Package.resolved recovery backup", file: file.path)
            }
            backupDescriptor = descriptor
        }
        defer { if let backupDescriptor { close(backupDescriptor) } }
        try PackageResolved.recoverJournaled(
            durable: record.original, installed: installed, backupDescriptor: backupDescriptor,
            project: project, recoveryID: record.recoveryID, allowsProgress: record.recoveryStarted)
        guard PackageResolved.representsOriginal(
            try PackageResolved.currentSnapshot(project: project), durable: record.original)
        else {
            throw SwiftPodsError("Package.resolved crash recovery did not restore its original state", file: file.path)
        }
    }

    private func verifyOriginalStates(allowsCleanupProgress: Bool) throws {
        for record in manifest.projects {
            try recoveryDeadline?.check()
            let current = try Self.fileToken(
                at: URL(fileURLWithPath: record.file), maximumBytes: Self.maximumProjectBytes)
            guard current.parent == record.parent, current.file.isEquivalent(to: record.original) else {
                throw SwiftPodsError("Xcode project rollback is incomplete", file: record.file)
            }
        }
        for record in manifest.packages {
            try recoveryDeadline?.check()
            let project = URL(fileURLWithPath: record.project)
            guard PackageResolved.representsOriginal(
                try PackageResolved.currentSnapshot(project: project), durable: record.original)
            else {
                throw SwiftPodsError(
                    "Package.resolved rollback is incomplete",
                    file: PackageResolved.location(project: project).path)
            }
        }
        try verifyGeneratedOriginal(allowsCleanupProgress: allowsCleanupProgress)
    }

    private func verifyCommittedStates(allowsMissingStaging: Bool) throws {
        for record in manifest.projects {
            try recoveryDeadline?.check()
            guard let installed = record.installed else {
                throw SwiftPodsError("Committed Xcode project state is missing from recovery journal", file: record.file)
            }
            let current = try Self.fileToken(
                at: URL(fileURLWithPath: record.file), maximumBytes: Self.maximumProjectBytes)
            guard current.parent == record.parent, current.file == installed else {
                throw SwiftPodsError(
                    "Committed Xcode project changed before crash-recovery cleanup", file: record.file)
            }
        }
        for record in manifest.packages {
            try recoveryDeadline?.check()
            guard let installed = record.installed else {
                throw SwiftPodsError("Committed Package.resolved state is missing from recovery journal")
            }
            let project = URL(fileURLWithPath: record.project)
            guard PackageResolved.matches(
                try PackageResolved.currentSnapshot(project: project), durable: installed)
            else {
                throw SwiftPodsError(
                    "Committed Package.resolved changed before crash-recovery cleanup",
                    file: PackageResolved.location(project: project).path)
            }
        }
        try verifyGeneratedCommitted(allowsMissingStaging: allowsMissingStaging)
        switch manifest.lock.policy {
        case .ignore:
            break
        case .replace:
            let currentLock = try Self.captureOptionalFile(
                named: SwiftPodsLock.fileName, in: workspaceDescriptor,
                maximumBytes: SwiftPodsLock.maximumJournalBytes,
                diagnostic: directory.appendingPathComponent(SwiftPodsLock.fileName))
            guard let planned = manifest.lock.plannedSHA256 else {
                throw SwiftPodsError("Committed SwiftPods transaction has no planned lock digest")
            }
            guard currentLock?.sha256 == planned else {
                throw SwiftPodsError(
                    "Committed SwiftPods.lock changed before crash-recovery cleanup",
                    file: directory.appendingPathComponent(SwiftPodsLock.fileName).path)
            }
        case .preserve:
            let currentLock = try Self.captureOptionalFile(
                named: SwiftPodsLock.fileName, in: workspaceDescriptor,
                maximumBytes: SwiftPodsLock.maximumJournalBytes,
                diagnostic: directory.appendingPathComponent(SwiftPodsLock.fileName))
            guard Self.fileMatches(currentLock, manifest.lock.original) else {
                throw SwiftPodsError(
                    "SwiftPods.lock changed during a deployment transaction",
                    file: directory.appendingPathComponent(SwiftPodsLock.fileName).path)
            }
        }
    }

    private func cleanupProjectRecoveryFiles(committed: Bool) throws {
        try verifyJournalPathBinding()
        for record in manifest.projects {
            try recoveryDeadline?.check()
            let file = URL(fileURLWithPath: record.file)
            let opened = try Self.openParent(of: file, kind: "Xcode project recovery file")
            defer { close(opened.descriptor) }
            guard opened.token == record.parent else {
                throw SwiftPodsError("Xcode project recovery parent changed", file: record.file)
            }
            let current = try Self.readFile(
                named: opened.name, in: opened.descriptor, maximumBytes: Self.maximumProjectBytes,
                diagnostic: file).token
            if committed {
                guard let installed = record.installed, current == installed else {
                    throw SwiftPodsError("Committed Xcode project changed during cleanup", file: record.file)
                }
            } else {
                guard current.isEquivalent(to: record.original) else {
                    throw SwiftPodsError("Xcode project rollback changed during cleanup", file: record.file)
                }
            }
            try cleanupProjectRecoveryFile(record, parent: opened.descriptor, expectedCurrent: current)
        }
    }

    private func recoverGenerated(_ record: GeneratedRecord) throws {
        try verifyJournalPathBinding()
        let descriptors = try generatedDescriptors(requiresStaging: true)
        defer {
            close(descriptors.staging!)
            close(descriptors.root)
        }
        let root = try Self.captureTree(
            named: record.name, in: descriptors.root, deadline: recoveryDeadline)
        let staging = try Self.captureTree(
            named: record.name, in: descriptors.staging!, deadline: recoveryDeadline)
        if Self.treeMatches(root, record.rootBefore), Self.treeMatches(staging, record.stagingBefore) {
            return
        }
        if manifest.phase == .rollingBack, Self.treeMatches(root, record.rootBefore),
            try Self.isTreeCleanupProgress(
                named: record.name, in: descriptors.staging!, expected: record.stagingBefore,
                deadline: recoveryDeadline)
        {
            return
        }
        switch record.kind {
        case .publish:
            guard Self.treeMatches(root, record.stagingBefore), Self.treeMatches(staging, record.rootBefore) else {
                throw SwiftPodsError(
                    "Generated path has an unknown state after interrupted publication; evidence was preserved: \(record.name)")
            }
            let result = record.name.withCString { rootName in
                record.name.withCString { stagingName in
                    if record.rootBefore == nil {
                        return renameatx_np(
                            descriptors.root, rootName, descriptors.staging!, stagingName, UInt32(RENAME_EXCL))
                    }
                    return renameatx_np(
                        descriptors.root, rootName, descriptors.staging!, stagingName, UInt32(RENAME_SWAP))
                }
            }
            guard result == 0 else {
                throw SwiftPodsError("Cannot roll back interrupted generated publication: \(record.name)")
            }
        case .withdraw:
            guard root == nil, Self.treeMatches(staging, record.rootBefore), record.stagingBefore == nil else {
                throw SwiftPodsError(
                    "Generated path has an unknown state after interrupted withdrawal; evidence was preserved: \(record.name)")
            }
            guard record.name.withCString({ stagingName in
                record.name.withCString {
                    renameatx_np(descriptors.staging!, stagingName, descriptors.root, $0, UInt32(RENAME_EXCL))
                }
            }) == 0 else {
                throw SwiftPodsError("Cannot roll back interrupted generated withdrawal: \(record.name)")
            }
        }
        guard fsync(descriptors.root) == 0, fsync(descriptors.staging!) == 0 else {
            throw SwiftPodsError("Cannot synchronize generated crash recovery: \(record.name)")
        }
        let restoredRoot = try Self.captureTree(
            named: record.name, in: descriptors.root, deadline: recoveryDeadline)
        let restoredStaging = try Self.captureTree(
            named: record.name, in: descriptors.staging!, deadline: recoveryDeadline)
        guard Self.treeMatches(restoredRoot, record.rootBefore),
            Self.treeMatches(restoredStaging, record.stagingBefore)
        else {
            throw SwiftPodsError("Generated path changed during crash recovery; evidence was preserved: \(record.name)")
        }
    }

    private func verifyGeneratedOriginal(allowsCleanupProgress: Bool) throws {
        let descriptors = try generatedDescriptors(requiresStaging: !allowsCleanupProgress)
        defer {
            if let staging = descriptors.staging { close(staging) }
            close(descriptors.root)
        }
        for record in manifest.generated {
            try recoveryDeadline?.check()
            guard Self.treeMatches(
                    try Self.captureTree(
                        named: record.name, in: descriptors.root, deadline: recoveryDeadline), record.rootBefore)
            else { throw SwiftPodsError("Generated rollback is incomplete: \(record.name)") }
        }
        if allowsCleanupProgress {
            if let staging = descriptors.staging {
                try Self.validateStagingCleanupProgress(
                    in: staging, expected: manifest.initialStaging, deadline: recoveryDeadline)
            }
        } else {
            let current = try Self.captureChildren(in: descriptors.staging!)
            guard Self.treesMatch(current, manifest.initialStaging) else {
                throw SwiftPodsError("Generated rollback staging changed before cleanup")
            }
        }
    }

    private func verifyGeneratedCommitted(allowsMissingStaging: Bool = false) throws {
        let descriptors = try generatedDescriptors(requiresStaging: !allowsMissingStaging)
        defer {
            if let staging = descriptors.staging { close(staging) }
            close(descriptors.root)
        }
        var expected = manifest.initialStaging
        for record in manifest.generated {
            try recoveryDeadline?.check()
            switch record.kind {
            case .publish:
                expected[record.name] = record.rootBefore
            case .withdraw:
                expected[record.name] = record.rootBefore
            }
            let expectedRoot: TreeToken?
            switch record.kind {
            case .publish: expectedRoot = record.stagingBefore
            case .withdraw: expectedRoot = nil
            }
            guard Self.treeMatches(
                try Self.captureTree(
                    named: record.name, in: descriptors.root, deadline: recoveryDeadline), expectedRoot)
            else { throw SwiftPodsError("Generated committed state changed: \(record.name)") }
            if !allowsMissingStaging, let staging = descriptors.staging {
                guard Self.treeMatches(
                    try Self.captureTree(
                        named: record.name, in: staging, deadline: recoveryDeadline), expected[record.name])
                else { throw SwiftPodsError("Generated committed staging changed: \(record.name)") }
            }
        }
    }

    private func committedStaging() -> [String: TreeToken] {
        var result = manifest.initialStaging
        for record in manifest.generated { result[record.name] = record.rootBefore }
        return result
    }

    private func generatedDescriptors(requiresStaging: Bool) throws -> (root: Int32, staging: Int32?) {
        let root = manifest.generatedRootName.withCString {
            openat(workspaceDescriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard root >= 0 else { throw SwiftPodsError("Cannot open generated root for transaction recovery") }
        do {
            guard DirectoryToken(try Self.directoryStatus(root, kind: "generated root")) == manifest.generatedRoot else {
                throw SwiftPodsError("Generated root changed since the transaction journal was created")
            }
            var linked = stat()
            guard manifest.generatedRootName.withCString({
                fstatat(workspaceDescriptor, $0, &linked, AT_SYMLINK_NOFOLLOW)
            }) == 0, DirectoryToken(linked) == manifest.generatedRoot else {
                throw SwiftPodsError("Generated root pathname changed since the transaction journal was created")
            }
            let staging = manifest.stagingName.withCString {
                openat(root, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            }
            if staging < 0 {
                if !requiresStaging, errno == ENOENT { return (root, nil) }
                throw SwiftPodsError("Generated transaction staging disappeared; recovery evidence was preserved")
            }
            do {
                guard DirectoryToken(try Self.directoryStatus(staging, kind: "generated transaction staging"))
                    == manifest.staging
                else { throw SwiftPodsError("Generated transaction staging was replaced") }
                try Self.securePrivateDirectory(staging, kind: "generated transaction staging")
                return (root, staging)
            } catch {
                close(staging)
                throw error
            }
        } catch {
            close(root)
            throw error
        }
    }

    private func generatedDescriptorsIdentityCheck(root: Int32, staging: Int32) throws {
        guard DirectoryToken(try Self.directoryStatus(root, kind: "generated root")) == manifest.generatedRoot,
            DirectoryToken(try Self.directoryStatus(staging, kind: "generated transaction staging")) == manifest.staging
        else { throw SwiftPodsError("Generated transaction directories changed while synchronized") }
        var linkedRoot = stat()
        var linkedStaging = stat()
        guard manifest.generatedRootName.withCString({
                fstatat(workspaceDescriptor, $0, &linkedRoot, AT_SYMLINK_NOFOLLOW)
            }) == 0,
            DirectoryToken(linkedRoot) == manifest.generatedRoot,
            manifest.stagingName.withCString({
                fstatat(root, $0, &linkedStaging, AT_SYMLINK_NOFOLLOW)
            }) == 0,
            DirectoryToken(linkedStaging) == manifest.staging
        else { throw SwiftPodsError("Generated transaction pathnames changed while synchronized") }
    }

    private func cleanupStaging(expected: [String: TreeToken], allowsMissing: Bool) throws {
        try recoveryDeadline?.check()
        try verifyJournalPathBinding()
        let descriptors = try generatedDescriptors(requiresStaging: !allowsMissing)
        defer {
            if let staging = descriptors.staging { close(staging) }
            close(descriptors.root)
        }
        guard let staging = descriptors.staging else {
            guard fsync(descriptors.root) == 0 else {
                throw SwiftPodsError("Cannot synchronize completed generated transaction staging removal")
            }
            return
        }
        try Self.validateStagingCleanupProgress(
            in: staging, expected: expected, deadline: recoveryDeadline)
        for name in try Self.names(in: staging, deadline: recoveryDeadline) {
            try recoveryDeadline?.check()
            guard let tree = expected[name] else {
                throw SwiftPodsError("Generated transaction staging contains unknown recovery entries")
            }
            try Self.removeTreeProgress(
                named: name, in: staging, expected: tree, deadline: recoveryDeadline)
        }
        guard try Self.names(in: staging, deadline: recoveryDeadline).isEmpty, fsync(staging) == 0,
            manifest.stagingName.withCString({ unlinkat(descriptors.root, $0, AT_REMOVEDIR) }) == 0,
            fsync(descriptors.root) == 0
        else { throw SwiftPodsError("Cannot remove completed generated transaction staging") }
    }

    private func cleanupJournal() throws {
        try verifyJournalPathBinding()
        for record in manifest.projects {
            try recoveryDeadline?.check()
            if let backupName = record.backupName {
                try removeBackup(
                    named: backupName, recorded: record.backup, original: record.original,
                    maximumBytes: Self.maximumProjectBytes,
                    diagnostic: URL(fileURLWithPath: record.file))
            }
        }
        for record in manifest.packages {
            try recoveryDeadline?.check()
            if let backupName = record.backupName, let original = record.originalFile {
                try removeBackup(
                    named: backupName, recorded: record.backup, original: original,
                    maximumBytes: SwiftPodsLock.maximumJournalBytes,
                    diagnostic: PackageResolved.location(project: URL(fileURLWithPath: record.project)))
            }
        }
        guard try Self.names(in: journalDescriptor, deadline: recoveryDeadline) == [Self.manifestName] else {
            throw SwiftPodsError("SwiftPods transaction journal contains unknown recovery evidence")
        }
        try verifyJournalPathBinding()
        guard Self.manifestName.withCString({ unlinkat(journalDescriptor, $0, 0) }) == 0,
            fsync(journalDescriptor) == 0
        else { throw SwiftPodsError("Cannot empty the completed SwiftPods transaction journal") }
        // A same-UID process can rename the opened directory and put another empty directory at the old pathname.
        // Never let the final rmdir target anything except the inode whose contents were just authenticated.
        try verifyJournalPathBinding()
        guard Self.directoryName.withCString({ unlinkat(workspaceDescriptor, $0, AT_REMOVEDIR) }) == 0,
            fsync(workspaceDescriptor) == 0
        else { throw SwiftPodsError("Cannot remove the completed SwiftPods transaction journal") }
        finished = true
    }

    private func cleanupLockTemporary() throws {
        try verifyJournalPathBinding()
        guard manifest.lock.policy == .replace, let name = manifest.lock.temporaryName,
            let cleanupDirectoryName = manifest.lock.cleanupDirectoryName
        else { return }
        try Self.requireLockTemporaryName(name)
        let diagnostic = directory.appendingPathComponent(name)
        if let token = try Self.captureOptionalFile(
            named: name, in: workspaceDescriptor, maximumBytes: SwiftPodsLock.maximumJournalBytes,
            diagnostic: diagnostic)
        {
            try validateLockResidue(token, diagnostic: diagnostic)
            let immediatelyBefore = try Self.readFile(
                named: name, in: workspaceDescriptor, maximumBytes: SwiftPodsLock.maximumJournalBytes,
                diagnostic: diagnostic).token
            guard immediatelyBefore == token,
                name.withCString({ unlinkat(workspaceDescriptor, $0, 0) }) == 0,
                fsync(workspaceDescriptor) == 0
            else {
                throw SwiftPodsError("Cannot safely remove SwiftPods.lock transaction residue", file: diagnostic.path)
            }
        }
        try cleanupLockQuarantine(named: cleanupDirectoryName)
    }

    private func validateLockResidue(_ token: FileToken, diagnostic: URL) throws {
        let matchesOriginal = Self.fileMatches(token, manifest.lock.original)
        let matchesPlanned = manifest.lock.plannedSHA256.map { token.sha256 == $0 } == true
        guard matchesOriginal || matchesPlanned else {
            throw SwiftPodsError(
                "SwiftPods.lock transaction residue has unknown contents; evidence was preserved",
                file: diagnostic.path)
        }
    }

    private func cleanupLockQuarantine(named name: String) throws {
        try Self.requireLockCleanupDirectoryName(name)
        var linked = stat()
        let found = name.withCString { fstatat(workspaceDescriptor, $0, &linked, AT_SYMLINK_NOFOLLOW) }
        if found != 0, errno == ENOENT { return }
        guard found == 0, linked.st_mode & S_IFMT == S_IFDIR else {
            throw SwiftPodsError("SwiftPods.lock cleanup pathname is not its recorded directory")
        }
        let descriptor = name.withCString {
            openat(workspaceDescriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else { throw SwiftPodsError("Cannot open SwiftPods.lock cleanup directory") }
        defer { close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0, opened.st_dev == linked.st_dev,
            opened.st_ino == linked.st_ino, opened.st_uid == geteuid(), opened.st_mode & 0o077 == 0,
            try Self.securityDigest(descriptor) == Self.securityDigestWithoutACLAndAttributes
        else { throw SwiftPodsError("SwiftPods.lock cleanup directory changed; evidence was preserved") }
        let names = try Self.names(in: descriptor, maximum: 2, deadline: recoveryDeadline)
        guard names.isEmpty || names == ["displaced"] else {
            throw SwiftPodsError("SwiftPods.lock cleanup directory contains unknown evidence")
        }
        if names == ["displaced"] {
            let diagnostic = directory.appendingPathComponent(name).appendingPathComponent("displaced")
            let token = try Self.readFile(
                named: "displaced", in: descriptor, maximumBytes: SwiftPodsLock.maximumJournalBytes,
                diagnostic: diagnostic).token
            try validateLockResidue(token, diagnostic: diagnostic)
            let immediatelyBefore = try Self.readFile(
                named: "displaced", in: descriptor, maximumBytes: SwiftPodsLock.maximumJournalBytes,
                diagnostic: diagnostic).token
            guard immediatelyBefore == token,
                "displaced".withCString({ unlinkat(descriptor, $0, 0) }) == 0,
                fsync(descriptor) == 0
            else { throw SwiftPodsError("Cannot safely remove quarantined SwiftPods.lock residue") }
        }
        var finalLinked = stat()
        guard try Self.names(in: descriptor, maximum: 1, deadline: recoveryDeadline).isEmpty,
            name.withCString({ fstatat(workspaceDescriptor, $0, &finalLinked, AT_SYMLINK_NOFOLLOW) }) == 0,
            finalLinked.st_dev == opened.st_dev, finalLinked.st_ino == opened.st_ino,
            name.withCString({ unlinkat(workspaceDescriptor, $0, AT_REMOVEDIR) }) == 0,
            fsync(workspaceDescriptor) == 0
        else { throw SwiftPodsError("Cannot remove completed SwiftPods.lock cleanup directory") }
    }

    private func removeBackup(
        named name: String, recorded: FileToken?, original: FileToken,
        maximumBytes: Int, diagnostic: URL
    ) throws {
        guard let token = try Self.captureOptionalFile(
            named: name, in: journalDescriptor, maximumBytes: maximumBytes,
            diagnostic: directory.appendingPathComponent(Self.directoryName).appendingPathComponent(name))
        else { return }
        // A crash during copy can leave the exact manifest-recorded backup name before its completed token is
        // persisted. It lives in the authenticated 0700 journal and cannot have been used for a later mutation, so a
        // bounded regular partial is cleanup progress rather than permanent poison. Once a token was recorded, exact
        // completed bytes/metadata remain mandatory.
        guard recorded == nil || (token == recorded && token.isEquivalent(to: original)) else {
            throw SwiftPodsError("Durable transaction backup changed; evidence was preserved", file: diagnostic.path)
        }
        let immediatelyBefore = try Self.readFile(
            named: name, in: journalDescriptor, maximumBytes: maximumBytes,
            diagnostic: directory.appendingPathComponent(Self.directoryName).appendingPathComponent(name)).token
        guard immediatelyBefore == token, name.withCString({ unlinkat(journalDescriptor, $0, 0) }) == 0,
            fsync(journalDescriptor) == 0
        else { throw SwiftPodsError("Cannot safely remove durable transaction backup", file: diagnostic.path) }
    }

    private func validatedBackup(
        named name: String, recorded: FileToken?, original: FileToken,
        maximumBytes: Int, diagnostic: URL
    ) throws -> FileToken {
        guard let token = try Self.captureOptionalFile(
            named: name, in: journalDescriptor, maximumBytes: maximumBytes,
            diagnostic: directory.appendingPathComponent(Self.directoryName).appendingPathComponent(name)),
            (recorded == nil || token == recorded), token.isEquivalent(to: original)
        else {
            throw SwiftPodsError("Durable transaction backup is missing or changed", file: diagnostic.path)
        }
        return token
    }

    private func persist() throws {
        try verifyJournalPathBinding()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(manifest)
        guard data.count <= Self.maximumManifestBytes else {
            throw SwiftPodsError("The SwiftPods transaction journal exceeds its safety limit")
        }
        // Never publish bytes that startup recovery would reject under its stricter pre-Foundation budgets.
        try Self.preflightManifest(data, deadline: nil, maximumInspectedBytes: nil)
        let temporary = Self.journalUpdateName(transactionID: manifest.transactionID)
        let descriptor = temporary.withCString {
            openat(journalDescriptor, $0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        }
        guard descriptor >= 0 else { throw SwiftPodsError("Cannot create the transaction journal update") }
        var removeTemporary = true
        defer {
            close(descriptor)
            if removeTemporary { _ = temporary.withCString { unlinkat(journalDescriptor, $0, 0) } }
        }
        try Self.writeAll(data, to: descriptor)
        guard fsync(descriptor) == 0 else { throw SwiftPodsError("Cannot synchronize the transaction journal") }
        let result = temporary.withCString { source in
            Self.manifestName.withCString { destination in
                renameat(journalDescriptor, source, journalDescriptor, destination)
            }
        }
        guard result == 0, fsync(journalDescriptor) == 0 else {
            throw SwiftPodsError("Cannot publish the transaction journal update")
        }
        try verifyJournalPathBinding()
        removeTemporary = false
    }

    private func copyToJournal(
        source: String, sourceParent: Int32, destination: String,
        maximumBytes: Int, diagnostic: URL
    ) throws -> FileToken {
        let result = try copyFile(
            source: source, sourceParent: sourceParent, destination: destination,
            destinationParent: journalDescriptor, maximumBytes: maximumBytes, diagnostic: diagnostic)
        guard fsync(journalDescriptor) == 0 else {
            throw SwiftPodsError("Cannot synchronize durable transaction backup", file: diagnostic.path)
        }
        return result
    }

    private func copyFile(
        source: String, sourceParent: Int32, destination: String, destinationParent: Int32,
        maximumBytes: Int, diagnostic: URL
    ) throws -> FileToken {
        try Self.requireComponent(source)
        try Self.requireComponent(destination)
        let input = source.withCString {
            openat(sourceParent, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard input >= 0 else { throw SwiftPodsError("Cannot open transaction backup source", file: diagnostic.path) }
        defer { close(input) }
        var inputStatus = stat()
        guard fstat(input, &inputStatus) == 0, inputStatus.st_mode & S_IFMT == S_IFREG,
            inputStatus.st_size >= 0, inputStatus.st_size <= Int64(maximumBytes)
        else { throw SwiftPodsError("Transaction backup source is not a bounded regular file", file: diagnostic.path) }
        try Self.requireRollbackSafe(inputStatus.st_flags, kind: "transaction backup source")
        let output = destination.withCString {
            openat(destinationParent, $0, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        }
        guard output >= 0 else { throw SwiftPodsError("Cannot create durable transaction backup", file: diagnostic.path) }
        var removeOutput = true
        defer {
            if removeOutput { _ = fchflags(output, 0) }
            close(output)
            if removeOutput { _ = destination.withCString { unlinkat(destinationParent, $0, 0) } }
        }
        var sourceTimes = [inputStatus.st_atimespec, inputStatus.st_mtimespec]
        guard fcopyfile(input, output, nil, copyfile_flags_t(COPYFILE_DATA)) == 0,
            fchown(output, inputStatus.st_uid, inputStatus.st_gid) == 0,
            fchmod(output, inputStatus.st_mode & 0o7777) == 0
        else {
            throw SwiftPodsError("Cannot copy durable transaction backup", file: diagnostic.path)
        }
        do {
            try BoundedFileSecurityMetadata.copy(from: input, to: output)
        } catch {
            throw SwiftPodsError(
                "Cannot copy bounded transaction backup security metadata: \(error)", file: diagnostic.path)
        }
        guard futimens(output, &sourceTimes) == 0,
            fchflags(output, inputStatus.st_flags) == 0,
            fsync(output) == 0 else {
            throw SwiftPodsError("Cannot copy durable transaction backup", file: diagnostic.path)
        }
        var sourceAfter = stat()
        guard fstat(input, &sourceAfter) == 0, EntryToken(sourceAfter) == EntryToken(inputStatus) else {
            throw SwiftPodsError("Transaction backup source changed while copied", file: diagnostic.path)
        }
        let copied = try Self.readFile(
            named: destination, in: destinationParent, maximumBytes: maximumBytes,
            diagnostic: diagnostic.deletingLastPathComponent().appendingPathComponent(destination)).token
        removeOutput = false
        return copied
    }

    private static func openParent(
        of file: URL, retainedDescriptor: Int32? = nil, kind: String
    ) throws -> (descriptor: Int32, name: String, token: DirectoryToken) {
        let name = file.lastPathComponent
        try requireComponent(name)
        if let retainedDescriptor {
            let descriptor = duplicateCloseOnExec(retainedDescriptor, minimum: STDERR_FILENO + 1)
            guard descriptor >= 0 else {
                throw SwiftPodsError("Cannot duplicate the retained \(kind) parent", file: file.path)
            }
            do {
                let status = try directoryStatus(descriptor, kind: kind + " parent")
                return (descriptor, name, DirectoryToken(status))
            } catch {
                close(descriptor)
                throw error
            }
        }
        let parentURL = file.deletingLastPathComponent()
        let descriptor = parentURL.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else { throw SwiftPodsError("Cannot safely open the \(kind) parent", file: file.path) }
        do {
            let status = try directoryStatus(descriptor, kind: kind + " parent")
            let reopened = parentURL.path.withCString {
                open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            }
            guard reopened >= 0 else {
                throw SwiftPodsError("The \(kind) parent moved while it was opened", file: file.path)
            }
            defer { close(reopened) }
            guard DirectoryToken(try directoryStatus(reopened, kind: kind + " parent")) == DirectoryToken(status) else {
                throw SwiftPodsError("The \(kind) parent changed while it was opened", file: file.path)
            }
            return (descriptor, name, DirectoryToken(status))
        } catch {
            close(descriptor)
            throw error
        }
    }

    private static func fileToken(
        at file: URL, maximumBytes: Int
    ) throws -> (parent: DirectoryToken, file: FileToken) {
        let opened = try openParent(of: file, kind: "transaction file")
        defer { close(opened.descriptor) }
        let token = try readFile(
            named: opened.name, in: opened.descriptor, maximumBytes: maximumBytes,
            diagnostic: file).token
        return (opened.token, token)
    }

    private static func fileMatches(_ current: FileToken?, _ expected: FileToken?) -> Bool {
        switch (current, expected) {
        case (nil, nil): return true
        case (let current?, let expected?):
            return current == expected || current.representsAfterRename(expected) || current.isEquivalent(to: expected)
        default: return false
        }
    }

    private static func treeMatches(_ current: TreeToken?, _ expected: TreeToken?) -> Bool {
        switch (current, expected) {
        case (nil, nil): return true
        case (let current?, let expected?): return current == expected || current.representsAfterRename(expected)
        default: return false
        }
    }

    /// A successful in-process rollback returns published top-level trees to staging with `rename`, which legitimately
    /// advances only their root ctime. Require the same complete name set and authenticate every tree with the same
    /// post-rename rule used by crash recovery; descendants and payload/security digests remain exact.
    private static func treesMatch(_ current: [String: TreeToken], _ expected: [String: TreeToken]) -> Bool {
        guard Set(current.keys) == Set(expected.keys) else { return false }
        return current.allSatisfy { name, tree in treeMatches(tree, expected[name]) }
    }

    private static func validateStagingCleanupProgress(
        in descriptor: Int32, expected: [String: TreeToken], deadline: RecoveryDeadline? = nil
    ) throws {
        let currentNames = try names(in: descriptor, deadline: deadline)
        guard Set(currentNames).isSubset(of: Set(expected.keys)) else {
            throw SwiftPodsError("Generated transaction staging contains unknown recovery entries")
        }
        for name in currentNames {
            try deadline?.check()
            guard let tree = expected[name],
                try isTreeCleanupProgress(
                    named: name, in: descriptor, expected: tree, deadline: deadline)
            else {
                throw SwiftPodsError(
                    "Generated transaction staging entry changed; evidence was preserved: \(name)")
            }
        }
    }

    private static func isTreeCleanupProgress(
        named name: String, in parent: Int32, expected: TreeToken?,
        deadline: RecoveryDeadline? = nil
    ) throws -> Bool {
        guard let expected else {
            var linked = stat()
            let found = name.withCString { fstatat(parent, $0, &linked, AT_SYMLINK_NOFOLLOW) }
            return found != 0 && errno == ENOENT
        }
        guard expected.members[""] != nil else { return false }
        return try isMemberCleanupProgress(
            named: name, relative: "", in: parent, expected: expected.members,
            deadline: deadline)
    }

    private static func isMemberCleanupProgress(
        named name: String, relative: String, in parent: Int32, expected: [String: TreeMember],
        deadline: RecoveryDeadline?
    ) throws -> Bool {
        try deadline?.check()
        guard let member = expected[relative] else { return false }
        var linked = stat()
        let found = name.withCString { fstatat(parent, $0, &linked, AT_SYMLINK_NOFOLLOW) }
        if found != 0, errno == ENOENT { return true }
        guard found == 0 else { throw SwiftPodsError("Cannot inspect generated staging cleanup progress") }
        let actual = EntryToken(linked)
        switch linked.st_mode & S_IFMT {
        case S_IFDIR:
            guard actual.isSameDirectoryObject(as: member.entry) else { return false }
            let descriptor = name.withCString {
                openat(parent, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            }
            guard descriptor >= 0 else { throw SwiftPodsError("Cannot open generated staging cleanup directory") }
            defer { close(descriptor) }
            var opened = stat()
            guard fstat(descriptor, &opened) == 0,
                EntryToken(opened).isSameDirectoryObject(as: member.entry),
                try securityDigest(descriptor) == member.securitySHA256
            else { return false }
            let prefix = relative.isEmpty ? "" : relative + "/"
            let expectedChildren = Set(expected.keys.compactMap { path -> String? in
                guard path != relative, path.hasPrefix(prefix) else { return nil }
                let suffix = String(path.dropFirst(prefix.count))
                return !suffix.isEmpty && !suffix.contains("/") ? suffix : nil
            })
            let currentChildren = try names(in: descriptor, deadline: deadline)
            guard Set(currentChildren).isSubset(of: expectedChildren) else { return false }
            for child in currentChildren {
                let childRelative = relative.isEmpty ? child : relative + "/" + child
                guard try isMemberCleanupProgress(
                    named: child, relative: childRelative, in: descriptor, expected: expected,
                    deadline: deadline)
                else { return false }
            }
            var final = stat()
            var finalLinked = stat()
            guard fstat(descriptor, &final) == 0,
                EntryToken(final).isSameDirectoryObject(as: member.entry),
                name.withCString({ fstatat(parent, $0, &finalLinked, AT_SYMLINK_NOFOLLOW) }) == 0,
                EntryToken(finalLinked).isSameDirectoryObject(as: EntryToken(final))
            else { return false }
            return true
        case S_IFREG:
            let value = try streamedFileToken(
                named: name, in: parent,
                diagnostic: URL(fileURLWithPath: relative.isEmpty ? name : relative), deadline: deadline)
            let entryMatches = relative.isEmpty
                ? value.entry.representsAfterRename(member.entry) : value.entry == member.entry
            return entryMatches && value.sha256 == member.payloadSHA256
                && value.securitySHA256 == member.securitySHA256
        case S_IFLNK:
            let entryMatches = relative.isEmpty
                ? actual.representsAfterRename(member.entry) : actual == member.entry
            guard entryMatches else { return false }
            var target = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
            let count = name.withCString { readlinkat(parent, $0, &target, target.count) }
            guard count >= 0, count < target.count else { return false }
            return sha256(Data(target.prefix(Int(count)).map { UInt8(bitPattern: $0) })) == member.payloadSHA256
        default:
            return false
        }
    }

    private static func removeTreeProgress(
        named name: String, in parent: Int32, expected: TreeToken,
        deadline: RecoveryDeadline? = nil
    ) throws {
        guard expected.members[""] != nil else {
            throw SwiftPodsError("Generated recovery manifest has no root entry")
        }
        try removeMemberProgress(
            named: name, relative: "", in: parent, expected: expected.members, deadline: deadline)
    }

    private static func removeMemberProgress(
        named name: String, relative: String, in parent: Int32, expected: [String: TreeMember],
        deadline: RecoveryDeadline?
    ) throws {
        try deadline?.check()
        guard let member = expected[relative] else {
            throw SwiftPodsError("Generated recovery manifest is incomplete")
        }
        var linked = stat()
        let found = name.withCString { fstatat(parent, $0, &linked, AT_SYMLINK_NOFOLLOW) }
        if found != 0, errno == ENOENT { return }
        guard found == 0 else { throw SwiftPodsError("Cannot inspect generated recovery cleanup progress") }
        switch linked.st_mode & S_IFMT {
        case S_IFDIR:
            guard EntryToken(linked).isSameDirectoryObject(as: member.entry) else {
                throw SwiftPodsError("Generated recovery directory changed during cleanup: \(relative)")
            }
            let descriptor = name.withCString {
                openat(parent, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            }
            guard descriptor >= 0 else {
                throw SwiftPodsError("Cannot open generated recovery directory during cleanup: \(relative)")
            }
            defer { close(descriptor) }
            var opened = stat()
            guard fstat(descriptor, &opened) == 0,
                EntryToken(opened).isSameDirectoryObject(as: member.entry),
                try securityDigest(descriptor) == member.securitySHA256
            else { throw SwiftPodsError("Generated recovery directory metadata changed: \(relative)") }
            let prefix = relative.isEmpty ? "" : relative + "/"
            let expectedChildren = Set(expected.keys.compactMap { path -> String? in
                guard path != relative, path.hasPrefix(prefix) else { return nil }
                let suffix = String(path.dropFirst(prefix.count))
                return !suffix.isEmpty && !suffix.contains("/") ? suffix : nil
            })
            let currentChildren = try names(in: descriptor, deadline: deadline)
            guard Set(currentChildren).isSubset(of: expectedChildren) else {
                throw SwiftPodsError("Generated recovery directory gained an unknown entry: \(relative)")
            }
            for child in currentChildren.sorted() {
                let childRelative = relative.isEmpty ? child : relative + "/" + child
                try removeMemberProgress(
                    named: child, relative: childRelative, in: descriptor, expected: expected,
                    deadline: deadline)
            }
            guard try names(in: descriptor, deadline: deadline).isEmpty, fsync(descriptor) == 0 else {
                throw SwiftPodsError("Cannot synchronize generated recovery directory cleanup: \(relative)")
            }
            var final = stat()
            var finalLinked = stat()
            guard fstat(descriptor, &final) == 0,
                EntryToken(final).isSameDirectoryObject(as: member.entry),
                name.withCString({ fstatat(parent, $0, &finalLinked, AT_SYMLINK_NOFOLLOW) }) == 0,
                EntryToken(finalLinked).isSameDirectoryObject(as: EntryToken(final)),
                name.withCString({ unlinkat(parent, $0, AT_REMOVEDIR) }) == 0,
                fsync(parent) == 0
            else { throw SwiftPodsError("Cannot remove generated recovery directory: \(relative)") }
        case S_IFREG:
            let value = try streamedFileToken(
                named: name, in: parent,
                diagnostic: URL(fileURLWithPath: relative.isEmpty ? name : relative), deadline: deadline)
            let entryMatches = relative.isEmpty
                ? value.entry.representsAfterRename(member.entry) : value.entry == member.entry
            guard entryMatches, value.sha256 == member.payloadSHA256,
                value.securitySHA256 == member.securitySHA256
            else { throw SwiftPodsError("Generated recovery file changed during cleanup: \(relative)") }
            let immediatelyBefore = try streamedFileToken(
                named: name, in: parent,
                diagnostic: URL(fileURLWithPath: relative.isEmpty ? name : relative), deadline: deadline)
            guard immediatelyBefore == value, name.withCString({ unlinkat(parent, $0, 0) }) == 0,
                fsync(parent) == 0
            else { throw SwiftPodsError("Cannot safely remove generated recovery file: \(relative)") }
        case S_IFLNK:
            let actual = EntryToken(linked)
            let entryMatches = relative.isEmpty
                ? actual.representsAfterRename(member.entry) : actual == member.entry
            var target = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
            let count = name.withCString { readlinkat(parent, $0, &target, target.count) }
            guard entryMatches, count >= 0, count < target.count,
                sha256(Data(target.prefix(Int(count)).map { UInt8(bitPattern: $0) })) == member.payloadSHA256
            else { throw SwiftPodsError("Generated recovery symbolic link changed: \(relative)") }
            var final = stat()
            guard name.withCString({ fstatat(parent, $0, &final, AT_SYMLINK_NOFOLLOW) }) == 0,
                EntryToken(final) == actual, name.withCString({ unlinkat(parent, $0, 0) }) == 0,
                fsync(parent) == 0
            else { throw SwiftPodsError("Cannot safely remove generated recovery symbolic link: \(relative)") }
        default:
            throw SwiftPodsError("Generated recovery tree contains a special file")
        }
    }

    private static func removeTree(named name: String, in parent: Int32, expected: TreeToken) throws {
        try requireComponent(name)
        guard expected.members[""] != nil else {
            throw SwiftPodsError("Generated recovery manifest has no root entry")
        }
        try removeMember(named: name, relative: "", in: parent, expected: expected.members)
    }

    private static func removeMember(
        named name: String, relative: String, in parent: Int32,
        expected: [String: TreeMember]
    ) throws {
        guard let member = expected[relative] else {
            throw SwiftPodsError("Generated recovery manifest is incomplete")
        }
        var linked = stat()
        guard name.withCString({ fstatat(parent, $0, &linked, AT_SYMLINK_NOFOLLOW) }) == 0,
            EntryToken(linked) == member.entry
        else { throw SwiftPodsError("Generated recovery entry changed during cleanup: \(relative)") }
        switch linked.st_mode & S_IFMT {
        case S_IFDIR:
            let descriptor = name.withCString {
                openat(parent, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            }
            guard descriptor >= 0 else {
                throw SwiftPodsError("Cannot open generated recovery directory during cleanup: \(relative)")
            }
            defer { close(descriptor) }
            guard try securityDigest(descriptor) == member.securitySHA256 else {
                throw SwiftPodsError("Generated recovery directory metadata changed during cleanup: \(relative)")
            }
            let prefix = relative.isEmpty ? "" : relative + "/"
            let directChildren = expected.keys.compactMap { path -> String? in
                guard path.hasPrefix(prefix), path != relative else { return nil }
                let suffix = String(path.dropFirst(prefix.count))
                return suffix.contains("/") ? nil : suffix
            }.sorted()
            guard try names(in: descriptor) == directChildren else {
                throw SwiftPodsError("Generated recovery directory gained an unknown entry: \(relative)")
            }
            for child in directChildren {
                let childRelative = relative.isEmpty ? child : relative + "/" + child
                try removeMember(
                    named: child, relative: childRelative, in: descriptor,
                    expected: expected)
            }
            guard try names(in: descriptor).isEmpty,
                name.withCString({ unlinkat(parent, $0, AT_REMOVEDIR) }) == 0
            else { throw SwiftPodsError("Cannot remove generated recovery directory: \(relative)") }
        case S_IFREG:
            let value = try streamedFileToken(
                named: name, in: parent,
                diagnostic: URL(fileURLWithPath: relative.isEmpty ? name : relative))
            guard value.entry == member.entry, value.sha256 == member.payloadSHA256,
                value.securitySHA256 == member.securitySHA256,
                name.withCString({ unlinkat(parent, $0, 0) }) == 0
            else { throw SwiftPodsError("Cannot safely remove generated recovery file: \(relative)") }
        case S_IFLNK:
            var target = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
            let count = name.withCString { readlinkat(parent, $0, &target, target.count) }
            guard count >= 0, count < target.count,
                sha256(Data(target.prefix(Int(count)).map { UInt8(bitPattern: $0) })) == member.payloadSHA256
            else { throw SwiftPodsError("Generated recovery symbolic link changed: \(relative)") }
            var immediatelyBefore = stat()
            guard name.withCString({ fstatat(parent, $0, &immediatelyBefore, AT_SYMLINK_NOFOLLOW) }) == 0,
                EntryToken(immediatelyBefore) == member.entry,
                name.withCString({ unlinkat(parent, $0, 0) }) == 0
            else { throw SwiftPodsError("Cannot safely remove generated recovery symbolic link: \(relative)") }
        default:
            throw SwiftPodsError("Generated recovery tree contains a special file")
        }
    }

    private static func requireRollbackSafe(_ flags: UInt32, kind: String) throws {
        do { try RollbackFileFlags.requireRemovable(flags, kind: kind) } catch {
            throw SwiftPodsError("Cannot start a recoverable install: \(error)")
        }
    }

    private static func requireRollbackSafeDirectory(_ descriptor: Int32, kind: String) throws {
        let status = try directoryStatus(descriptor, kind: kind)
        try requireRollbackSafe(status.st_flags, kind: kind)
    }

    /// A read-only walk used before `.swiftpods-transaction` is created.  The later authenticated capture repeats all
    /// identities; this first pass exists solely to ensure rollback will never inherit an undeletable tree.
    private static func preflightGeneratedStaging(generatedRoot: URL, stagingName: String) throws {
        try requireComponent(stagingName)
        let root = try openDirectory(generatedRoot, kind: "generated root")
        defer { close(root) }
        try requireRollbackSafeDirectory(root, kind: "generated root")
        let staging = stagingName.withCString {
            openat(root, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard staging >= 0 else {
            throw SwiftPodsError("Cannot safely open generated transaction staging before journaling")
        }
        defer { close(staging) }
        var entries = 0
        try requireRollbackSafeTree(in: staging, depth: 0, entries: &entries)
    }

    private static func requireRollbackSafeTree(
        in descriptor: Int32, depth: Int, entries: inout Int
    ) throws {
        guard depth <= maximumTreeDepth else {
            throw SwiftPodsError("Generated transaction staging is nested too deeply")
        }
        try requireRollbackSafeDirectory(descriptor, kind: "generated transaction staging")
        for name in try names(in: descriptor) {
            entries += 1
            guard entries <= maximumTreeEntries else {
                throw SwiftPodsError("Generated transaction staging contains too many entries")
            }
            var linked = stat()
            guard name.withCString({ fstatat(descriptor, $0, &linked, AT_SYMLINK_NOFOLLOW) }) == 0 else {
                throw SwiftPodsError("Generated transaction staging changed during flag validation")
            }
            try requireRollbackSafe(linked.st_flags, kind: "generated transaction staging entry")
            switch linked.st_mode & S_IFMT {
            case S_IFDIR:
                let child = name.withCString {
                    openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
                }
                guard child >= 0 else {
                    throw SwiftPodsError("Cannot open generated transaction staging during flag validation")
                }
                do {
                    defer { close(child) }
                    var opened = stat()
                    guard fstat(child, &opened) == 0, EntryToken(opened) == EntryToken(linked) else {
                        throw SwiftPodsError("Generated transaction staging changed during flag validation")
                    }
                    try requireRollbackSafeTree(in: child, depth: depth + 1, entries: &entries)
                    var final = stat()
                    guard fstat(child, &final) == 0, EntryToken(final) == EntryToken(opened) else {
                        throw SwiftPodsError("Generated transaction staging changed during flag validation")
                    }
                }
            case S_IFREG, S_IFLNK:
                break
            default:
                throw SwiftPodsError("Generated transaction staging contains a special file")
            }
        }
    }

    private static func boundJournalIdentity(
        descriptor: Int32, workspaceDescriptor: Int32
    ) throws -> DirectoryToken {
        let opened = try directoryStatus(descriptor, kind: "SwiftPods transaction journal")
        try requireRollbackSafe(opened.st_flags, kind: "SwiftPods transaction journal")
        let identity = DirectoryToken(opened)
        try verifyJournalPathBinding(
            descriptor: descriptor, identity: identity, workspaceDescriptor: workspaceDescriptor)
        return identity
    }

    private static func verifyJournalPathBinding(
        descriptor: Int32, identity: DirectoryToken, workspaceDescriptor: Int32
    ) throws {
        var opened = stat()
        var linked = stat()
        guard fstat(descriptor, &opened) == 0, opened.st_mode & S_IFMT == S_IFDIR,
            directoryName.withCString({
                fstatat(workspaceDescriptor, $0, &linked, AT_SYMLINK_NOFOLLOW)
            }) == 0,
            linked.st_mode & S_IFMT == S_IFDIR,
            opened.st_flags & RollbackFileFlags.prohibited == 0,
            linked.st_flags & RollbackFileFlags.prohibited == 0,
            DirectoryToken(opened) == identity, DirectoryToken(linked) == identity
        else {
            throw SwiftPodsError("The SwiftPods transaction journal pathname changed; recovery evidence was preserved")
        }
    }

    private func verifyJournalPathBinding() throws {
        try Self.verifyJournalPathBinding(
            descriptor: journalDescriptor, identity: journalIdentity,
            workspaceDescriptor: workspaceDescriptor)
    }

    private static func requireWorkspace(_ descriptor: Int32, at directory: URL) throws {
        let status = try directoryStatus(descriptor, kind: "workspace")
        let reopened = directory.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard reopened >= 0 else { throw SwiftPodsError("The locked workspace path moved before journaling") }
        defer { close(reopened) }
        let linked = try directoryStatus(reopened, kind: "workspace")
        guard DirectoryToken(status) == DirectoryToken(linked) else {
            throw SwiftPodsError("The locked workspace path changed before journaling")
        }
    }

    private static func directoryStatus(_ descriptor: Int32, kind: String) throws -> stat {
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFDIR else {
            throw SwiftPodsError("Cannot inspect the \(kind)")
        }
        return status
    }

    private static func openDirectory(_ url: URL, kind: String) throws -> Int32 {
        let descriptor = url.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else { throw SwiftPodsError("Cannot safely open the \(kind): \(url.path)") }
        return descriptor
    }

    private static func securePrivateDirectory(_ descriptor: Int32, kind: String) throws {
        guard fchmod(descriptor, 0o700) == 0 else {
            throw SwiftPodsError("Cannot secure the \(kind)")
        }
        if let emptyACL = acl_init(0) {
            errno = 0
            let result = acl_set_fd_np(descriptor, emptyACL, ACL_TYPE_EXTENDED)
            let failure = errno
            acl_free(UnsafeMutableRawPointer(emptyACL))
            guard result == 0 || failure == ENOTSUP || failure == EOPNOTSUPP else {
                throw SwiftPodsError("Cannot clear inherited access controls on the \(kind)")
            }
        } else {
            throw SwiftPodsError("Cannot allocate access controls for the \(kind)")
        }
        let status = try directoryStatus(descriptor, kind: kind)
        guard status.st_uid == geteuid(), status.st_mode & 0o077 == 0 else {
            throw SwiftPodsError("The \(kind) is not private")
        }
        guard try securityDigest(descriptor) == securityDigestWithoutACLAndAttributes else {
            throw SwiftPodsError("The \(kind) retains inherited access controls")
        }
    }

    private static var securityDigestWithoutACLAndAttributes: String {
        var hasher = SHA256()
        hashField(Data(), into: &hasher)
        hashField(Data(), into: &hasher)
        return Data(hasher.finalize()).map { String(format: "%02x", $0) }.joined()
    }

    private static func captureOptionalFile(
        named name: String, in parent: Int32, maximumBytes: Int, diagnostic: URL
    ) throws -> FileToken? {
        var status = stat()
        let found = name.withCString { fstatat(parent, $0, &status, AT_SYMLINK_NOFOLLOW) }
        if found != 0, errno == ENOENT { return nil }
        guard found == 0 else { throw SwiftPodsError("Cannot inspect transaction file", file: diagnostic.path) }
        return try readFile(named: name, in: parent, maximumBytes: maximumBytes, diagnostic: diagnostic).token
    }

    private static func readFile(
        named name: String, in parent: Int32, maximumBytes: Int, diagnostic: URL
    ) throws -> (token: FileToken, data: Data) {
        try requireComponent(name)
        let descriptor = name.withCString {
            openat(parent, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else { throw SwiftPodsError("Cannot safely read transaction file", file: diagnostic.path) }
        defer { close(descriptor) }
        var initial = stat()
        guard fstat(descriptor, &initial) == 0, initial.st_mode & S_IFMT == S_IFREG,
            initial.st_size >= 0, initial.st_size <= Int64(maximumBytes)
        else { throw SwiftPodsError("Transaction file is not a bounded regular file", file: diagnostic.path) }
        let duplicate = duplicateCloseOnExec(descriptor)
        guard duplicate >= 0 else {
            throw SwiftPodsError("Cannot duplicate transaction file descriptor", file: diagnostic.path)
        }
        let handle = FileHandle(fileDescriptor: duplicate, closeOnDealloc: true)
        defer { try? handle.close() }
        var data = Data()
        while true {
            let requested = maximumBytes == Int.max
                ? 1 << 20 : min(1 << 20, maximumBytes - data.count + 1)
            guard let chunk = try handle.read(upToCount: requested), !chunk.isEmpty else { break }
            data.append(chunk)
            guard data.count <= maximumBytes else {
                throw SwiftPodsError("Transaction file exceeds its safety limit", file: diagnostic.path)
            }
        }
        let security = try securityDigest(descriptor)
        var final = stat()
        var linked = stat()
        guard fstat(descriptor, &final) == 0, EntryToken(final) == EntryToken(initial),
            Int64(data.count) == initial.st_size,
            name.withCString({ fstatat(parent, $0, &linked, AT_SYMLINK_NOFOLLOW) }) == 0,
            EntryToken(linked) == EntryToken(final)
        else { throw SwiftPodsError("Transaction file changed while it was read", file: diagnostic.path) }
        return (FileToken(entry: .init(final), sha256: sha256(data), securitySHA256: security), data)
    }

    private static func streamedFileToken(
        named name: String, in parent: Int32, diagnostic: URL,
        deadline: RecoveryDeadline? = nil
    ) throws -> FileToken {
        try requireComponent(name)
        let descriptor = name.withCString {
            openat(parent, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else {
            throw SwiftPodsError("Cannot safely read generated transaction file", file: diagnostic.path)
        }
        defer { close(descriptor) }
        var initial = stat()
        guard fstat(descriptor, &initial) == 0, initial.st_mode & S_IFMT == S_IFREG,
            initial.st_size >= 0
        else {
            throw SwiftPodsError("Generated transaction entry is not a regular file", file: diagnostic.path)
        }
        let duplicate = duplicateCloseOnExec(descriptor)
        guard duplicate >= 0 else {
            throw SwiftPodsError("Cannot duplicate generated transaction file descriptor", file: diagnostic.path)
        }
        let handle = FileHandle(fileDescriptor: duplicate, closeOnDealloc: true)
        defer { try? handle.close() }
        var hasher = SHA256()
        var count: Int64 = 0
        while true {
            try deadline?.check()
            guard let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
            let (next, overflow) = count.addingReportingOverflow(Int64(chunk.count))
            guard !overflow, next <= initial.st_size else {
                throw SwiftPodsError("Generated transaction file changed while it was read", file: diagnostic.path)
            }
            count = next
            hasher.update(data: chunk)
        }
        let security = try securityDigest(descriptor)
        var final = stat()
        var linked = stat()
        guard fstat(descriptor, &final) == 0, EntryToken(final) == EntryToken(initial),
            count == initial.st_size,
            name.withCString({ fstatat(parent, $0, &linked, AT_SYMLINK_NOFOLLOW) }) == 0,
            EntryToken(linked) == EntryToken(final)
        else {
            throw SwiftPodsError("Generated transaction file changed while it was read", file: diagnostic.path)
        }
        return FileToken(
            entry: .init(final),
            sha256: Data(hasher.finalize()).map { String(format: "%02x", $0) }.joined(),
            securitySHA256: security)
    }

    private static func securityDigest(_ descriptor: Int32) throws -> String {
        let metadata: BoundedFileSecurityMetadata.Snapshot
        do {
            metadata = try BoundedFileSecurityMetadata.capture(descriptor)
        } catch {
            throw SwiftPodsError("Cannot inspect bounded transaction file security metadata: \(error)")
        }
        var hasher = SHA256()
        for attribute in metadata.attributes {
            hashField(Data(attribute.name.utf8), into: &hasher)
            hashField(attribute.value, into: &hasher)
        }
        hashField(Data(), into: &hasher)
        hashField(metadata.acl, into: &hasher)
        return Data(hasher.finalize()).map { String(format: "%02x", $0) }.joined()
    }

    private static func hashField(_ data: Data, into hasher: inout SHA256) {
        var length = UInt64(data.count).littleEndian
        withUnsafeBytes(of: &length) { hasher.update(data: Data($0)) }
        hasher.update(data: data)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw SwiftPodsError("Cannot write transaction journal data") }
                offset += count
            }
        }
    }

    private static func requireComponent(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"),
            name.utf8.count <= 255,
            !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { throw SwiftPodsError("Unsafe transaction journal path component") }
    }

    private static func names(
        in descriptor: Int32, maximum: Int = maximumTreeEntries,
        deadline: RecoveryDeadline? = nil
    ) throws -> [String] {
        let duplicate = openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard duplicate >= 0, let stream = fdopendir(duplicate) else {
            if duplicate >= 0 { close(duplicate) }
            throw SwiftPodsError("Cannot enumerate transaction directory")
        }
        defer { closedir(stream) }
        var result: [String] = []
        errno = 0
        while let entry = readdir(stream) {
            if result.count & 0xff == 0 { try deadline?.check() }
            var bytes = entry.pointee.d_name
            let name = withUnsafeBytes(of: &bytes) { raw in
                String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
            }
            if name != "." && name != ".." {
                guard result.count < maximum else {
                    throw SwiftPodsError("Transaction directory contains too many entries")
                }
                result.append(name)
            }
            errno = 0
        }
        guard errno == 0 else { throw SwiftPodsError("Cannot enumerate transaction directory") }
        return result.sorted()
    }

    private static func captureChildren(in descriptor: Int32) throws -> [String: TreeToken] {
        var result: [String: TreeToken] = [:]
        var entries = 0
        for name in try names(in: descriptor) {
            result[name] = try captureTree(named: name, in: descriptor, entries: &entries)
        }
        return result
    }

    /// Makes every staged payload durable before journal publication. Directories are synchronized bottom-up so the
    /// journal can never become durable while referring to a child that exists only in volatile directory metadata.
    private static func synchronizeTree(in descriptor: Int32) throws {
        var entries = 0
        try synchronizeDirectory(descriptor, depth: 0, entries: &entries)
    }

    private static func synchronizeDirectory(_ descriptor: Int32, depth: Int, entries: inout Int) throws {
        try requireRollbackSafeDirectory(descriptor, kind: "generated transaction staging")
        guard depth <= maximumTreeDepth else {
            throw SwiftPodsError("Generated transaction staging is nested too deeply to synchronize")
        }
        for name in try names(in: descriptor) {
            entries += 1
            guard entries <= maximumTreeEntries else {
                throw SwiftPodsError("Generated transaction staging contains too many entries to synchronize")
            }
            var linked = stat()
            guard name.withCString({ fstatat(descriptor, $0, &linked, AT_SYMLINK_NOFOLLOW) }) == 0 else {
                throw SwiftPodsError("Generated transaction staging changed while it was synchronized")
            }
            try requireRollbackSafe(linked.st_flags, kind: "generated transaction staging entry")
            switch linked.st_mode & S_IFMT {
            case S_IFDIR:
                let child = name.withCString {
                    openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
                }
                guard child >= 0 else {
                    throw SwiftPodsError("Cannot open generated staging directory while synchronizing it")
                }
                do {
                    var opened = stat()
                    guard fstat(child, &opened) == 0, EntryToken(opened) == EntryToken(linked) else {
                        throw SwiftPodsError("Generated staging directory changed while it was opened")
                    }
                    try synchronizeDirectory(child, depth: depth + 1, entries: &entries)
                    guard fsync(child) == 0 else {
                        throw SwiftPodsError("Cannot synchronize generated staging directory")
                    }
                    var final = stat()
                    var finalLinked = stat()
                    guard fstat(child, &final) == 0, EntryToken(final) == EntryToken(opened),
                        name.withCString({ fstatat(descriptor, $0, &finalLinked, AT_SYMLINK_NOFOLLOW) }) == 0,
                        EntryToken(finalLinked) == EntryToken(final)
                    else { throw SwiftPodsError("Generated staging directory changed while synchronized") }
                    close(child)
                } catch {
                    close(child)
                    throw error
                }
            case S_IFREG:
                let file = name.withCString {
                    openat(descriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
                }
                guard file >= 0 else {
                    throw SwiftPodsError("Cannot open generated staging file while synchronizing it")
                }
                var opened = stat()
                var final = stat()
                var finalLinked = stat()
                let synchronized = fstat(file, &opened) == 0 && EntryToken(opened) == EntryToken(linked)
                    && fsync(file) == 0 && fstat(file, &final) == 0
                    && EntryToken(final) == EntryToken(opened)
                    && name.withCString({ fstatat(descriptor, $0, &finalLinked, AT_SYMLINK_NOFOLLOW) }) == 0
                    && EntryToken(finalLinked) == EntryToken(final)
                close(file)
                guard synchronized
                else { throw SwiftPodsError("Generated staging file changed while synchronized") }
            case S_IFLNK:
                var final = stat()
                guard name.withCString({ fstatat(descriptor, $0, &final, AT_SYMLINK_NOFOLLOW) }) == 0,
                    EntryToken(final) == EntryToken(linked)
                else { throw SwiftPodsError("Generated staging symbolic link changed while synchronized") }
            default:
                throw SwiftPodsError("Generated transaction staging contains a special file")
            }
        }
        guard fsync(descriptor) == 0 else {
            throw SwiftPodsError("Cannot synchronize generated transaction staging")
        }
    }

    private static func captureTree(
        named name: String, in parent: Int32, entries: inout Int,
        deadline: RecoveryDeadline? = nil
    ) throws -> TreeToken {
        try requireComponent(name)
        var members: [String: TreeMember] = [:]
        _ = try captureMember(
            named: name, relative: "", in: parent, depth: 0, entries: &entries, members: &members,
            deadline: deadline)
        return TreeToken(members: members)
    }

    private static func captureTree(
        named name: String, in parent: Int32, deadline: RecoveryDeadline? = nil
    ) throws -> TreeToken? {
        var status = stat()
        let found = name.withCString { fstatat(parent, $0, &status, AT_SYMLINK_NOFOLLOW) }
        if found != 0, errno == ENOENT { return nil }
        guard found == 0 else { throw SwiftPodsError("Cannot inspect generated transaction entry \(name)") }
        var entries = 0
        return try captureTree(named: name, in: parent, entries: &entries, deadline: deadline)
    }

    @discardableResult
    private static func captureMember(
        named name: String, relative: String, in parent: Int32, depth: Int,
        entries: inout Int, members: inout [String: TreeMember],
        deadline: RecoveryDeadline? = nil
    ) throws -> EntryToken {
        try deadline?.check()
        try requireComponent(name)
        guard depth <= maximumTreeDepth else {
            throw SwiftPodsError("Generated transaction tree is nested too deeply")
        }
        entries += 1
        guard entries <= maximumTreeEntries else {
            throw SwiftPodsError("Generated transaction tree contains too many entries")
        }
        var linked = stat()
        guard name.withCString({ fstatat(parent, $0, &linked, AT_SYMLINK_NOFOLLOW) }) == 0 else {
            throw SwiftPodsError("Generated transaction tree changed while it was captured")
        }
        let type = linked.st_mode & S_IFMT
        let state = EntryToken(linked)
        try requireRollbackSafe(state.flags, kind: "generated transaction tree entry")
        switch type {
        case S_IFDIR:
            let child = name.withCString {
                openat(parent, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            }
            guard child >= 0 else { throw SwiftPodsError("Cannot open generated transaction directory \(name)") }
            defer { close(child) }
            var opened = stat()
            guard fstat(child, &opened) == 0, EntryToken(opened) == state else {
                throw SwiftPodsError("Generated transaction directory changed while it was opened")
            }
            let security = try securityDigest(child)
            members[relative] = TreeMember(entry: state, payloadSHA256: nil, securitySHA256: security)
            for nested in try names(in: child, deadline: deadline) {
                let nestedRelative = relative.isEmpty ? nested : relative + "/" + nested
                try captureMember(
                    named: nested, relative: nestedRelative, in: child, depth: depth + 1,
                    entries: &entries, members: &members, deadline: deadline)
            }
            var final = stat()
            guard fstat(child, &final) == 0, EntryToken(final) == state else {
                throw SwiftPodsError("Generated transaction directory changed while it was captured")
            }
        case S_IFREG:
            let value = try streamedFileToken(
                named: name, in: parent,
                diagnostic: URL(fileURLWithPath: relative.isEmpty ? name : relative), deadline: deadline)
            members[relative] = TreeMember(
                entry: value.entry, payloadSHA256: value.sha256,
                securitySHA256: value.securitySHA256)
            guard value.entry == state else {
                throw SwiftPodsError("Generated transaction file changed while it was captured")
            }
        case S_IFLNK:
            var target = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
            let count = name.withCString {
                readlinkat(parent, $0, &target, target.count)
            }
            guard count >= 0, count < target.count else {
                throw SwiftPodsError("Generated transaction symbolic link changed while it was captured")
            }
            var final = stat()
            guard name.withCString({ fstatat(parent, $0, &final, AT_SYMLINK_NOFOLLOW) }) == 0,
                EntryToken(final) == state
            else { throw SwiftPodsError("Generated transaction symbolic link changed while it was captured") }
            members[relative] = TreeMember(
                entry: state,
                payloadSHA256: sha256(Data(target.prefix(Int(count)).map { UInt8(bitPattern: $0) })),
                securitySHA256: nil)
        default:
            throw SwiftPodsError("Generated transaction tree contains a special file")
        }
        return state
    }

    private static func journalUpdateName(transactionID: String) -> String {
        ".journal-\(transactionID)"
    }

    private static func transactionID(fromJournalUpdateName name: String) -> String? {
        let prefix = ".journal-"
        guard name.hasPrefix(prefix), name.count == prefix.count + 36 else { return nil }
        let value = String(name.dropFirst(prefix.count))
        return UUID(uuidString: value) == nil ? nil : value
    }

    private static func requireLockTemporaryName(_ name: String) throws {
        let prefix = ".\(SwiftPodsLock.fileName).tmp-"
        guard name.hasPrefix(prefix), name.count == prefix.count + 36,
            UUID(uuidString: String(name.dropFirst(prefix.count))) != nil
        else { throw SwiftPodsError("SwiftPods transaction journal contains an unsafe lock temporary name") }
    }

    private static func requireLockCleanupDirectoryName(_ name: String) throws {
        let prefix = ".swiftpods-lock-journal-"
        guard name.hasPrefix(prefix), name.count == prefix.count + 36,
            UUID(uuidString: String(name.dropFirst(prefix.count))) != nil
        else { throw SwiftPodsError("SwiftPods transaction journal contains an unsafe lock cleanup name") }
    }

    private static func decodeManifest(
        _ data: Data, deadline: RecoveryDeadline? = nil,
        maximumPreflightBytesForTesting: Int? = nil
    ) throws -> Manifest {
        try deadline?.check()
        try preflightManifest(
            data, deadline: deadline, maximumInspectedBytes: maximumPreflightBytesForTesting)
        let decoded: Manifest
        do { decoded = try JSONDecoder().decode(Manifest.self, from: data) } catch {
            throw SwiftPodsError("SwiftPods transaction journal cannot be decoded: \(error)")
        }
        try deadline?.check()
        try validateManifest(decoded, deadline: deadline)
        return decoded
    }

    /// Test seam for parser-budget regressions. Runtime recovery uses this exact decoder before touching workspace
    /// state, so synthetic manifests can exercise its fail-closed limits without constructing enormous file trees.
    static func validateEncodedManifestForTesting(
        _ data: Data, maximumPreflightBytes: Int? = nil
    ) throws {
        _ = try decodeManifest(data, maximumPreflightBytesForTesting: maximumPreflightBytes)
    }

    /// Performs the security validation before Foundation materializes dictionaries and arrays.  The parser knows the
    /// journal schema, so an unknown top-level key or an oversized array is rejected before its potentially enormous
    /// value is traversed.  JSONDecoder remains the single object-building pass after this bounded preflight.
    private static func preflightManifest(
        _ data: Data, deadline: RecoveryDeadline?, maximumInspectedBytes: Int?
    ) throws {
        guard data.count <= maximumManifestBytes else {
            throw SwiftPodsError("The SwiftPods transaction journal exceeds its safety limit")
        }
        try data.withUnsafeBytes { raw in
            var parser = ManifestPreflightParser(
                bytes: raw, deadline: deadline, maximumInspectedBytes: maximumInspectedBytes)
            try parser.parse()
        }
    }

    private struct ManifestPreflightParser {
        private enum Schema {
            case scalar
            case manifest
            case directory
            case entry
            case file
            case tree
            case treeMembers
            case treeMember
            case initialStaging
            case lock
            case generatedRecord
            case projectRecord
            case packageRecord
            case durablePackage
            case packageNode
            case attribute
            case generatedArray
            case projectArray
            case packageArray
            case directoryArray
            case attributeArray
        }

        let bytes: UnsafeRawBufferPointer
        let deadline: RecoveryDeadline?
        let maximumInspectedBytes: Int?
        var position = 0
        var values = 0
        var aggregateStringBytes = 0
        var whitespaceBytes = 0
        var manifestTreeEntries = 0
        var manifestAttributes = 0

        mutating func parse() throws {
            guard !bytes.isEmpty else { throw invalid("is empty") }
            try parseValue(.manifest, depth: 0)
            try skipWhitespace()
            guard position == bytes.count else { throw invalid("has trailing data") }
        }

        private mutating func parseValue(_ schema: Schema, depth: Int) throws {
            guard depth <= 32 else { throw invalid("is nested too deeply") }
            let (nextValues, overflow) = values.addingReportingOverflow(1)
            guard !overflow, nextValues <= maximumManifestJSONValues else {
                throw invalid("contains too many JSON values")
            }
            values = nextValues
            try skipWhitespace()
            guard position < bytes.count else { throw invalid("ends inside a value") }
            switch schema {
            case .manifest, .directory, .entry, .file, .tree, .treeMembers, .treeMember,
                .initialStaging, .lock, .generatedRecord, .projectRecord, .packageRecord,
                .durablePackage, .packageNode, .attribute:
                try parseObject(schema, depth: depth)
            case .generatedArray, .projectArray, .packageArray, .directoryArray, .attributeArray:
                try parseArray(schema, depth: depth)
            case .scalar:
                try parseScalar()
            }
        }

        private mutating func parseObject(_ schema: Schema, depth: Int) throws {
            guard try consumeIf(0x7B) else { throw invalid("contains a value with the wrong shape") } // {
            try skipWhitespace()
            var keys = Set<String>()
            if try consumeIf(0x7D) { // }
                try requireObjectKeys(keys, schema: schema)
                return
            }
            while true {
                try skipWhitespace()
                guard position < bytes.count, bytes[position] == 0x22 else {
                    throw invalid("contains a non-string object key")
                }
                let key = try parseString(decoded: true)!
                guard keys.insert(key).inserted else { throw invalid("contains duplicate JSON object keys") }
                let child: Schema
                switch schema {
                case .treeMembers:
                    guard keys.count <= maximumTreeEntries else {
                        throw invalid("contains too many entries in one generated tree")
                    }
                    manifestTreeEntries += 1
                    guard manifestTreeEntries <= maximumManifestTreeEntries else {
                        throw invalid("contains too many generated tree entries")
                    }
                    child = .treeMember
                case .initialStaging:
                    guard keys.count <= maximumGeneratedRecords else {
                        throw invalid("contains too many initial staging entries")
                    }
                    child = .tree
                default:
                    guard let expected = childSchema(for: key, in: schema) else {
                        // Do not parse the value of an unknown key: this is the fail-fast boundary that prevents a
                        // small invalid prefix from forcing a scan of tens of MiB of attacker-controlled JSON.
                        throw invalid("contains an unexpected field '\(key)'")
                    }
                    child = expected
                }
                try skipWhitespace()
                guard try consumeIf(0x3A) else { throw invalid("is missing an object separator") } // :
                try parseValue(child, depth: depth + 1)
                try skipWhitespace()
                if try consumeIf(0x7D) { // }
                    try requireObjectKeys(keys, schema: schema)
                    return
                }
                guard try consumeIf(0x2C) else { throw invalid("is missing an object delimiter") } // ,
            }
        }

        private mutating func parseArray(_ schema: Schema, depth: Int) throws {
            guard try consumeIf(0x5B) else { throw invalid("contains a value with the wrong shape") } // [
            try skipWhitespace()
            if try consumeIf(0x5D) { return } // ]
            let element: Schema
            let maximum: Int
            switch schema {
            case .generatedArray: (element, maximum) = (.generatedRecord, maximumGeneratedRecords)
            case .projectArray: (element, maximum) = (.projectRecord, maximumProjectRecords)
            case .packageArray: (element, maximum) = (.packageRecord, maximumPackageRecords)
            case .directoryArray: (element, maximum) = (.packageNode, 4)
            case .attributeArray: (element, maximum) = (.attribute, 4_096)
            default: throw invalid("contains an unexpected array")
            }
            var count = 0
            while true {
                count += 1
                guard count <= maximum else { throw invalid("contains an oversized array") }
                if schema == .attributeArray {
                    manifestAttributes += 1
                    guard manifestAttributes <= maximumManifestAttributes else {
                        throw invalid("contains too many Package.resolved attributes")
                    }
                }
                try parseValue(element, depth: depth + 1)
                try skipWhitespace()
                if try consumeIf(0x5D) { return } // ]
                guard try consumeIf(0x2C) else { throw invalid("is missing an array delimiter") } // ,
            }
        }

        private mutating func parseScalar() throws {
            guard position < bytes.count else { throw invalid("ends inside a scalar") }
            switch bytes[position] {
            case 0x22: _ = try parseString(decoded: false)
            case 0x74: try consumeLiteral([0x74, 0x72, 0x75, 0x65]) // true
            case 0x66: try consumeLiteral([0x66, 0x61, 0x6c, 0x73, 0x65]) // false
            case 0x6e: try consumeLiteral([0x6e, 0x75, 0x6c, 0x6c]) // null; Codable rejects non-optionals
            case 0x2D, 0x30...0x39: try parseNumber()
            default: throw invalid("contains a non-scalar field value")
            }
        }

        private mutating func parseString(decoded: Bool) throws -> String? {
            let start = position
            guard try consumeIf(0x22) else { throw invalid("contains an invalid string") }
            let contentStart = position
            var escaped = false
            while position < bytes.count {
                let byte = bytes[position]
                try advance()
                let rawLength = position - contentStart
                guard rawLength <= maximumManifestStringBytes,
                    aggregateStringBytes <= maximumManifestAggregateStringBytes - min(
                        rawLength, maximumManifestAggregateStringBytes)
                else { throw invalid("contains an oversized string") }
                switch byte {
                case 0x22:
                    let contentLength = rawLength - 1
                    let (aggregate, overflow) = aggregateStringBytes.addingReportingOverflow(contentLength)
                    guard !overflow, aggregate <= maximumManifestAggregateStringBytes else {
                        throw invalid("contains too much string data")
                    }
                    aggregateStringBytes = aggregate
                    guard decoded else { return nil }
                    guard let base = bytes.baseAddress else { throw invalid("contains an invalid string") }
                    if !escaped,
                        let result = String(
                            bytes: UnsafeRawBufferPointer(
                                start: base.advanced(by: contentStart), count: contentLength),
                            encoding: .utf8)
                    {
                        return result
                    }
                    let token = Data(bytes: base.advanced(by: start), count: position - start)
                    guard let result = try? JSONDecoder().decode(String.self, from: token) else {
                        throw invalid("contains an invalid escaped object key")
                    }
                    return result
                case 0x5C: // backslash
                    escaped = true
                    guard position < bytes.count else { throw invalid("ends inside a string escape") }
                    let escape = bytes[position]
                    try advance()
                    if escape == 0x75 { // u
                        for _ in 0..<4 {
                            guard position < bytes.count, Self.isHexDigit(bytes[position]) else {
                                throw invalid("contains an invalid unicode escape")
                            }
                            try advance()
                        }
                    } else if ![0x22, 0x2F, 0x5C, 0x62, 0x66, 0x6E, 0x72, 0x74].contains(escape) {
                        throw invalid("contains an invalid string escape")
                    }
                case 0x00...0x1F:
                    throw invalid("contains a control byte in a string")
                default:
                    break
                }
            }
            throw invalid("ends inside a string")
        }

        private mutating func parseNumber() throws {
            let start = position
            if try consumeIf(0x2D) { try requireNumberLength(from: start) } // -
            guard position < bytes.count else { throw invalid("ends inside a number") }
            if try consumeIf(0x30) { // 0
                try requireNumberLength(from: start)
                guard position == bytes.count || !(0x30...0x39).contains(bytes[position]) else {
                    throw invalid("contains a number with a leading zero")
                }
            } else {
                guard (0x31...0x39).contains(bytes[position]) else { throw invalid("contains an invalid number") }
                try advance()
                try requireNumberLength(from: start)
                while position < bytes.count, (0x30...0x39).contains(bytes[position]) {
                    try advance()
                    try requireNumberLength(from: start)
                }
            }
            if try consumeIf(0x2E) { // .
                try requireNumberLength(from: start)
                guard position < bytes.count, (0x30...0x39).contains(bytes[position]) else {
                    throw invalid("contains an invalid fraction")
                }
                while position < bytes.count, (0x30...0x39).contains(bytes[position]) {
                    try advance()
                    try requireNumberLength(from: start)
                }
            }
            if position < bytes.count, bytes[position] == 0x65 || bytes[position] == 0x45 { // e or E
                try advance()
                try requireNumberLength(from: start)
                if position < bytes.count, bytes[position] == 0x2B || bytes[position] == 0x2D {
                    try advance()
                    try requireNumberLength(from: start)
                }
                guard position < bytes.count, (0x30...0x39).contains(bytes[position]) else {
                    throw invalid("contains an invalid exponent")
                }
                while position < bytes.count, (0x30...0x39).contains(bytes[position]) {
                    try advance()
                    try requireNumberLength(from: start)
                }
            }
        }

        private func requireNumberLength(from start: Int) throws {
            guard position - start <= 128 else { throw invalid("contains an oversized number") }
        }

        private mutating func skipWhitespace() throws {
            while position < bytes.count, [0x09, 0x0A, 0x0D, 0x20].contains(bytes[position]) {
                whitespaceBytes += 1
                guard whitespaceBytes <= 1 * 1_024 * 1_024 else {
                    throw invalid("contains excessive whitespace")
                }
                try advance()
            }
        }

        private mutating func consumeLiteral(_ expected: [UInt8]) throws {
            guard position <= bytes.count - expected.count else { throw invalid("ends inside a literal") }
            for byte in expected {
                guard bytes[position] == byte else { throw invalid("contains an invalid literal") }
                try advance()
            }
        }

        private mutating func consumeIf(_ expected: UInt8) throws -> Bool {
            guard position < bytes.count, bytes[position] == expected else { return false }
            try advance()
            return true
        }

        private mutating func advance() throws {
            position += 1
            if let maximumInspectedBytes, position > maximumInspectedBytes {
                throw invalid("exceeded the test inspection budget")
            }
            if position & 0x0fff == 0 { try deadline?.check() }
        }

        private func childSchema(for key: String, in schema: Schema) -> Schema? {
            switch schema {
            case .manifest:
                switch key {
                case "workspace", "generatedRoot", "staging": return .directory
                case "initialStaging": return .initialStaging
                case "lock": return .lock
                case "generated": return .generatedArray
                case "projects": return .projectArray
                case "packages": return .packageArray
                case "schema", "transactionID", "phase", "generatedRootName", "stagingName": return .scalar
                default: return nil
                }
            case .directory, .entry, .packageNode, .attribute:
                return allowedKeys(for: schema).contains(key) ? .scalar : nil
            case .file:
                if key == "entry" { return .entry }
                return ["sha256", "securitySHA256"].contains(key) ? .scalar : nil
            case .tree:
                return key == "members" ? .treeMembers : nil
            case .treeMember:
                if key == "entry" { return .entry }
                return ["payloadSHA256", "securitySHA256"].contains(key) ? .scalar : nil
            case .lock:
                if key == "original" { return .file }
                return allowedKeys(for: schema).contains(key) ? .scalar : nil
            case .generatedRecord:
                if key == "rootBefore" || key == "stagingBefore" { return .tree }
                return ["kind", "name"].contains(key) ? .scalar : nil
            case .projectRecord:
                if key == "parent" { return .directory }
                if ["original", "backup", "installed"].contains(key) { return .file }
                return ["file", "desiredSHA256", "backupName", "recoveryName"].contains(key) ? .scalar : nil
            case .packageRecord:
                if key == "original" || key == "installed" { return .durablePackage }
                if key == "originalFile" || key == "backup" { return .file }
                return ["project", "backupName", "recoveryID", "recoveryStarted"].contains(key) ? .scalar : nil
            case .durablePackage:
                switch key {
                case "directories": return .directoryArray
                case "entry": return .packageNode
                case "attributes": return .attributeArray
                case "acl", "dataSHA256": return .scalar
                default: return nil
                }
            default:
                return nil
            }
        }

        private func requireObjectKeys(_ actual: Set<String>, schema: Schema) throws {
            if schema == .treeMembers || schema == .initialStaging { return }
            let required = requiredKeys(for: schema)
            let allowed = allowedKeys(for: schema)
            guard required.isSubset(of: actual), actual.isSubset(of: allowed) else {
                throw invalid("has unexpected or missing fields")
            }
        }

        private func requiredKeys(for schema: Schema) -> Set<String> {
            switch schema {
            case .manifest:
                return allowedKeys(for: schema)
            case .directory:
                return allowedKeys(for: schema)
            case .entry:
                return allowedKeys(for: schema)
            case .file:
                return allowedKeys(for: schema)
            case .tree:
                return ["members"]
            case .treeMember:
                return ["entry"]
            case .lock:
                return ["policy"]
            case .generatedRecord:
                return ["kind", "name"]
            case .projectRecord:
                return ["file", "parent", "original", "desiredSHA256"]
            case .packageRecord:
                return ["project", "original", "recoveryID", "recoveryStarted"]
            case .durablePackage:
                return ["directories"]
            case .packageNode:
                return allowedKeys(for: schema)
            case .attribute:
                return allowedKeys(for: schema)
            default:
                return []
            }
        }

        private func allowedKeys(for schema: Schema) -> Set<String> {
            switch schema {
            case .manifest:
                return [
                    "schema", "transactionID", "phase", "workspace", "generatedRootName", "generatedRoot",
                    "stagingName", "staging", "initialStaging", "lock", "generated", "projects", "packages",
                ]
            case .directory:
                return ["device", "inode", "mode", "owner", "group"]
            case .entry:
                return [
                    "device", "inode", "mode", "links", "owner", "group", "flags", "size",
                    "modifiedSeconds", "modifiedNanoseconds", "changedSeconds", "changedNanoseconds",
                ]
            case .file:
                return ["entry", "sha256", "securitySHA256"]
            case .tree:
                return ["members"]
            case .treeMember:
                return ["entry", "payloadSHA256", "securitySHA256"]
            case .lock:
                return ["policy", "original", "plannedSHA256", "temporaryName", "cleanupDirectoryName"]
            case .generatedRecord:
                return ["kind", "name", "rootBefore", "stagingBefore"]
            case .projectRecord:
                return [
                    "file", "parent", "original", "desiredSHA256", "backupName", "recoveryName", "backup",
                    "installed",
                ]
            case .packageRecord:
                return [
                    "project", "original", "backupName", "originalFile", "recoveryID", "backup", "installed",
                    "recoveryStarted",
                ]
            case .durablePackage:
                return ["directories", "entry", "attributes", "acl", "dataSHA256"]
            case .packageNode:
                return [
                    "device", "inode", "mode", "links", "owner", "group", "flags", "size", "accessedSeconds",
                    "accessedNanoseconds", "modifiedSeconds", "modifiedNanoseconds", "changedSeconds",
                    "changedNanoseconds",
                ]
            case .attribute:
                return ["name", "value"]
            default:
                return []
            }
        }

        private func invalid(_ detail: String) -> SwiftPodsError {
            SwiftPodsError("SwiftPods transaction journal \(detail)")
        }

        private static func isHexDigit(_ byte: UInt8) -> Bool {
            (0x30...0x39).contains(byte) || (0x41...0x46).contains(byte) || (0x61...0x66).contains(byte)
        }
    }

    private static func validateManifestJSON(
        _ root: [String: Any], deadline: RecoveryDeadline? = nil
    ) throws {
        try deadline?.check()
        try requireKeys(
            root,
            exactly: [
                "schema", "transactionID", "phase", "workspace", "generatedRootName", "generatedRoot",
                "stagingName", "staging", "initialStaging", "lock", "generated", "projects", "packages",
            ], kind: "manifest")
        try validateDirectoryJSON(try object(root["workspace"], kind: "workspace"))
        try validateDirectoryJSON(try object(root["generatedRoot"], kind: "generated root"))
        try validateDirectoryJSON(try object(root["staging"], kind: "staging"))
        let initial = try object(root["initialStaging"], kind: "initial staging")
        guard initial.count <= maximumGeneratedRecords else {
            throw SwiftPodsError("SwiftPods transaction journal has too many initial staging entries")
        }
        for value in initial.values {
            try deadline?.check()
            try validateTreeJSON(try object(value, kind: "staging tree"), deadline: deadline)
        }
        let lock = try object(root["lock"], kind: "lock")
        try requireKeys(
            lock, required: ["policy"],
            allowed: ["policy", "original", "plannedSHA256", "temporaryName", "cleanupDirectoryName"], kind: "lock")
        if let value = lock["original"] { try validateFileJSON(try object(value, kind: "lock original")) }

        let generated = try array(root["generated"], kind: "generated records", maximum: maximumGeneratedRecords)
        for value in generated {
            try deadline?.check()
            let record = try object(value, kind: "generated record")
            try requireKeys(
                record, required: ["kind", "name"],
                allowed: ["kind", "name", "rootBefore", "stagingBefore"], kind: "generated record")
            if let value = record["rootBefore"] {
                try validateTreeJSON(try object(value, kind: "generated root tree"), deadline: deadline)
            }
            if let value = record["stagingBefore"] {
                try validateTreeJSON(try object(value, kind: "generated staging tree"), deadline: deadline)
            }
        }

        let projects = try array(root["projects"], kind: "project records", maximum: maximumProjectRecords)
        for value in projects {
            try deadline?.check()
            let record = try object(value, kind: "project record")
            try requireKeys(
                record, required: ["file", "parent", "original", "desiredSHA256"],
                allowed: [
                    "file", "parent", "original", "desiredSHA256", "backupName", "recoveryName", "backup",
                    "installed",
                ], kind: "project record")
            try validateDirectoryJSON(try object(record["parent"], kind: "project parent"))
            try validateFileJSON(try object(record["original"], kind: "project original"))
            if let value = record["backup"] { try validateFileJSON(try object(value, kind: "project backup")) }
            if let value = record["installed"] { try validateFileJSON(try object(value, kind: "project installed")) }
        }

        let packages = try array(root["packages"], kind: "package records", maximum: maximumPackageRecords)
        for value in packages {
            try deadline?.check()
            let record = try object(value, kind: "package record")
            try requireKeys(
                record, required: ["project", "original", "recoveryID", "recoveryStarted"],
                allowed: [
                    "project", "original", "backupName", "originalFile", "recoveryID", "backup", "installed",
                    "recoveryStarted",
                ], kind: "package record")
            try validateDurablePackageJSON(try object(record["original"], kind: "package original"))
            if let value = record["originalFile"] { try validateFileJSON(try object(value, kind: "package original file")) }
            if let value = record["backup"] { try validateFileJSON(try object(value, kind: "package backup")) }
            if let value = record["installed"] {
                try validateDurablePackageJSON(try object(value, kind: "package installed"))
            }
        }
    }

    private static func validateDirectoryJSON(_ value: [String: Any]) throws {
        try requireKeys(value, exactly: ["device", "inode", "mode", "owner", "group"], kind: "directory token")
    }

    private static func validateEntryJSON(_ value: [String: Any]) throws {
        try requireKeys(
            value,
            exactly: [
                "device", "inode", "mode", "links", "owner", "group", "flags", "size", "modifiedSeconds",
                "modifiedNanoseconds", "changedSeconds", "changedNanoseconds",
            ], kind: "entry token")
    }

    private static func validateFileJSON(_ value: [String: Any]) throws {
        try requireKeys(value, exactly: ["entry", "sha256", "securitySHA256"], kind: "file token")
        try validateEntryJSON(try object(value["entry"], kind: "file entry"))
    }

    private static func validateTreeJSON(
        _ value: [String: Any], deadline: RecoveryDeadline? = nil
    ) throws {
        try requireKeys(value, exactly: ["members"], kind: "tree token")
        let members = try object(value["members"], kind: "tree members")
        guard members.count <= maximumTreeEntries else {
            throw SwiftPodsError("SwiftPods transaction journal tree contains too many entries")
        }
        for member in members.values {
            try deadline?.check()
            let object = try object(member, kind: "tree member")
            try requireKeys(
                object, required: ["entry"], allowed: ["entry", "payloadSHA256", "securitySHA256"],
                kind: "tree member")
            try validateEntryJSON(try self.object(object["entry"], kind: "tree member entry"))
        }
    }

    private static func validateDurablePackageJSON(_ value: [String: Any]) throws {
        try requireKeys(
            value, required: ["directories"],
            allowed: ["directories", "entry", "attributes", "acl", "dataSHA256"], kind: "Package.resolved state")
        let directories = try array(value["directories"], kind: "Package.resolved directories", maximum: 4)
        for directory in directories { try validatePackageNodeJSON(try object(directory, kind: "Package.resolved directory")) }
        if let entry = value["entry"] { try validatePackageNodeJSON(try object(entry, kind: "Package.resolved entry")) }
        if let attributes = value["attributes"] {
            for attribute in try array(attributes, kind: "Package.resolved attributes", maximum: 4_096) {
                try requireKeys(
                    try object(attribute, kind: "Package.resolved attribute"), exactly: ["name", "value"],
                    kind: "Package.resolved attribute")
            }
        }
    }

    private static func validatePackageNodeJSON(_ value: [String: Any]) throws {
        try requireKeys(
            value,
            exactly: [
                "device", "inode", "mode", "links", "owner", "group", "flags", "size", "accessedSeconds",
                "accessedNanoseconds", "modifiedSeconds", "modifiedNanoseconds", "changedSeconds", "changedNanoseconds",
            ], kind: "Package.resolved node")
    }

    private static func requireKeys(
        _ object: [String: Any], exactly keys: Set<String>, kind: String
    ) throws {
        guard Set(object.keys) == keys else {
            throw SwiftPodsError("SwiftPods transaction journal \(kind) has unexpected or missing fields")
        }
    }

    private static func requireKeys(
        _ object: [String: Any], required: Set<String>, allowed: Set<String>, kind: String
    ) throws {
        let keys = Set(object.keys)
        guard required.isSubset(of: keys), keys.isSubset(of: allowed) else {
            throw SwiftPodsError("SwiftPods transaction journal \(kind) has unexpected or missing fields")
        }
    }

    private static func object(_ value: Any?, kind: String) throws -> [String: Any] {
        guard let result = value as? [String: Any] else {
            throw SwiftPodsError("SwiftPods transaction journal \(kind) is not an object")
        }
        return result
    }

    private static func array(_ value: Any?, kind: String, maximum: Int) throws -> [Any] {
        guard let result = value as? [Any], result.count <= maximum else {
            throw SwiftPodsError("SwiftPods transaction journal \(kind) is invalid or exceeds its limit")
        }
        return result
    }

    private static func validateManifest(
        _ value: Manifest, deadline: RecoveryDeadline? = nil
    ) throws {
        try deadline?.check()
        guard value.schema == schema, UUID(uuidString: value.transactionID) != nil else {
            throw SwiftPodsError("The SwiftPods transaction journal has an unsupported schema or identity")
        }
        try requireComponent(value.generatedRootName)
        try requireComponent(value.stagingName)
        guard value.stagingName.hasPrefix(".staging-"),
            UUID(uuidString: String(value.stagingName.dropFirst(".staging-".count))) != nil,
            value.generated.count <= maximumGeneratedRecords,
            value.projects.count <= maximumProjectRecords,
            value.packages.count <= maximumPackageRecords,
            value.initialStaging.count <= maximumGeneratedRecords
        else { throw SwiftPodsError("SwiftPods transaction journal exceeds its structural limits") }
        switch value.lock.policy {
        case .ignore:
            guard value.lock.original == nil, value.lock.plannedSHA256 == nil,
                value.lock.temporaryName == nil, value.lock.cleanupDirectoryName == nil,
                value.phase != .committing
            else { throw SwiftPodsError("SwiftPods transaction journal has an inconsistent ignored lock") }
        case .preserve:
            guard value.lock.original != nil, value.lock.plannedSHA256 == nil,
                value.lock.temporaryName == nil, value.lock.cleanupDirectoryName == nil,
                value.phase != .committing
            else { throw SwiftPodsError("SwiftPods transaction journal has an inconsistent preserved lock") }
        case .replace:
            guard let digest = value.lock.plannedSHA256, isDigest(digest),
                let name = value.lock.temporaryName,
                let cleanupName = value.lock.cleanupDirectoryName,
                value.lock.original.map(isFileTokenValid) ?? true
            else { throw SwiftPodsError("SwiftPods transaction journal has an inconsistent replacement lock") }
            try requireLockTemporaryName(name)
            try requireLockCleanupDirectoryName(cleanupName)
        }
        var generatedNames = Set<String>()
        var totalMembers = 0
        for record in value.generated {
            try deadline?.check()
            try requireComponent(record.name)
            guard generatedNames.insert(record.name).inserted else {
                throw SwiftPodsError("SwiftPods transaction journal repeats a generated path")
            }
            for tree in [record.rootBefore, record.stagingBefore].compactMap({ $0 }) {
                try validateTree(tree, totalMembers: &totalMembers, deadline: deadline)
            }
        }
        for (name, tree) in value.initialStaging {
            try deadline?.check()
            try requireComponent(name)
            try validateTree(tree, totalMembers: &totalMembers, deadline: deadline)
        }
        guard totalMembers <= maximumManifestTreeEntries else {
            throw SwiftPodsError("SwiftPods transaction journal records too many tree entries")
        }
        var projectPaths = Set<String>()
        for record in value.projects {
            try deadline?.check()
            try requireAbsolutePath(record.file)
            guard projectPaths.insert(record.file).inserted, isDigest(record.desiredSHA256),
                isFileTokenValid(record.original), record.backup.map(isFileTokenValid) ?? true,
                record.installed.map(isFileTokenValid) ?? true
            else { throw SwiftPodsError("SwiftPods transaction journal has an invalid project record") }
            if let name = record.backupName { try requireBackupName(name, prefix: "project-", suffix: ".backup") }
            if let name = record.recoveryName { try requireRecoveryName(name) }
        }
        var packagePaths = Set<String>()
        for record in value.packages {
            try deadline?.check()
            try requireAbsolutePath(record.project)
            let packageFile = PackageResolved.location(project: URL(fileURLWithPath: record.project))
            try PackageResolved.requireRollbackSafe(record.original, file: packageFile)
            if let installed = record.installed {
                try PackageResolved.requireRollbackSafe(installed, file: packageFile)
            }
            guard packagePaths.insert(record.project).inserted, UUID(uuidString: record.recoveryID) != nil,
                record.originalFile.map(isFileTokenValid) ?? true,
                record.backup.map(isFileTokenValid) ?? true
            else { throw SwiftPodsError("SwiftPods transaction journal has an invalid Package.resolved record") }
            if let name = record.backupName { try requireBackupName(name, prefix: "package-", suffix: ".backup") }
        }
    }

    private static func validateTree(
        _ tree: TreeToken, totalMembers: inout Int,
        deadline: RecoveryDeadline? = nil
    ) throws {
        guard tree.members[""] != nil else {
            throw SwiftPodsError("SwiftPods transaction journal tree has no root")
        }
        totalMembers += tree.members.count
        guard totalMembers <= maximumManifestTreeEntries else {
            throw SwiftPodsError("SwiftPods transaction journal records too many tree entries")
        }
        for (path, member) in tree.members {
            try deadline?.check()
            if !path.isEmpty {
                let parts = path.split(separator: "/", omittingEmptySubsequences: false)
                guard parts.count <= maximumTreeDepth, path.utf8.count <= 4_096 else {
                    throw SwiftPodsError("SwiftPods transaction journal tree path exceeds its limit")
                }
                for part in parts { try requireComponent(String(part)) }
            }
            guard member.payloadSHA256.map(isDigest) ?? true,
                member.securitySHA256.map(isDigest) ?? true,
                member.entry.flags & RollbackFileFlags.prohibited == 0
            else { throw SwiftPodsError("SwiftPods transaction journal tree contains an invalid digest") }
        }
    }

    private static func isFileTokenValid(_ token: FileToken) -> Bool {
        isDigest(token.sha256) && isDigest(token.securitySHA256) && token.entry.size >= 0
            && token.entry.flags & RollbackFileFlags.prohibited == 0
    }

    private static func isDigest(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy {
            (0x30...0x39).contains($0) || (0x61...0x66).contains($0)
        }
    }

    private static func requireAbsolutePath(_ value: String) throws {
        guard value.hasPrefix("/"), value.utf8.count <= 32_768,
            !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { throw SwiftPodsError("SwiftPods transaction journal contains an unsafe absolute path") }
    }

    private static func requireBackupName(_ name: String, prefix: String, suffix: String) throws {
        try requireComponent(name)
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else {
            throw SwiftPodsError("SwiftPods transaction journal contains an unsafe backup name")
        }
        let start = name.index(name.startIndex, offsetBy: prefix.count)
        let end = name.index(name.endIndex, offsetBy: -suffix.count)
        guard UUID(uuidString: String(name[start..<end])) != nil else {
            throw SwiftPodsError("SwiftPods transaction journal contains an unsafe backup identity")
        }
    }

    private static func requireRecoveryName(_ name: String) throws {
        try requireComponent(name)
        guard let range = name.range(of: ".swiftpods-recovery-", options: .backwards),
            UUID(uuidString: String(name[range.upperBound...])) != nil
        else { throw SwiftPodsError("SwiftPods transaction journal contains an unsafe recovery name") }
    }

    private static func isSuccessor(_ next: Manifest, of current: Manifest) -> Bool {
        guard next.schema == current.schema, next.transactionID == current.transactionID,
            next.workspace == current.workspace, next.generatedRootName == current.generatedRootName,
            next.generatedRoot == current.generatedRoot, next.stagingName == current.stagingName,
            next.staging == current.staging, next.initialStaging == current.initialStaging,
            next.lock == current.lock, phaseCanAdvance(from: current.phase, to: next.phase),
            arrayCanAppend(current.generated, next.generated),
            projectRecordsCanAdvance(current.projects, next.projects),
            packageRecordsCanAdvance(current.packages, next.packages)
        else { return false }
        return true
    }

    private static func phaseCanAdvance(from current: Phase, to next: Phase) -> Bool {
        if current == next { return true }
        switch (current, next) {
        case (.active, .committing), (.active, .committed), (.active, .rollingBack),
            (.committing, .active), (.committing, .committed),
            (.committed, .committedCleaning):
            return true
        default: return false
        }
    }

    private static func arrayCanAppend<T: Equatable>(_ current: [T], _ next: [T]) -> Bool {
        next.count >= current.count && next.count <= current.count + 1
            && Array(next.prefix(current.count)) == current
    }

    private static func projectRecordsCanAdvance(_ current: [ProjectRecord], _ next: [ProjectRecord]) -> Bool {
        guard next.count >= current.count, next.count <= current.count + 1 else { return false }
        for index in current.indices {
            let old = current[index]
            let new = next[index]
            guard old.file == new.file, old.parent == new.parent, old.original == new.original,
                old.desiredSHA256 == new.desiredSHA256, old.backupName == new.backupName,
                old.recoveryName == new.recoveryName, optionalCanAdvance(old.backup, new.backup),
                optionalCanAdvance(old.installed, new.installed)
            else { return false }
        }
        return true
    }

    private static func packageRecordsCanAdvance(_ current: [PackageRecord], _ next: [PackageRecord]) -> Bool {
        guard next.count >= current.count, next.count <= current.count + 1 else { return false }
        for index in current.indices {
            let old = current[index]
            let new = next[index]
            guard old.project == new.project, old.original == new.original,
                old.backupName == new.backupName, old.originalFile == new.originalFile,
                old.recoveryID == new.recoveryID, optionalCanAdvance(old.backup, new.backup),
                optionalCanAdvance(old.installed, new.installed), (!old.recoveryStarted || new.recoveryStarted)
            else { return false }
        }
        return true
    }

    private static func optionalCanAdvance<T: Equatable>(_ current: T?, _ next: T?) -> Bool {
        current == nil ? true : current == next
    }
}

private extension SwiftPodsLock {
    static let maximumJournalBytes = 16 * 1_024 * 1_024
}
