import CryptoKit
import Darwin
import CoreFoundation
import Foundation
import SwiftPodsManifest
import SwiftPodsSecurity

@inline(__always)
func duplicateCloseOnExec(_ descriptor: Int32, minimum: Int32 = 0) -> Int32 {
    fcntl(descriptor, F_DUPFD_CLOEXEC, minimum)
}

/// Flags that make a file or directory impossible (or privilege-dependent) to remove during rollback.  Transaction
/// recovery must reject these before it creates durable evidence: copying an immutable flag onto a temporary file can
/// otherwise leave a journal that its owner cannot clean up.
enum RollbackFileFlags {
    static let prohibited = UInt32(bitPattern:
        UF_IMMUTABLE | UF_APPEND | SF_IMMUTABLE | SF_APPEND | SF_NOUNLINK)

    static func requireRemovable(_ flags: UInt32, kind: String) throws {
        guard flags & prohibited == 0 else {
            throw SwiftPodsError("The \(kind) has immutable, append-only, or no-unlink flags")
        }
    }
}

/// A stable comparison and restorable copy of metadata that `stat` does not expose. The unlinked backup descriptor
/// lets rollback reproduce ACLs and extended attributes without trusting the file after an external command ran.
struct FileSecurityMetadata: Equatable {
    typealias Attribute = BoundedFileSecurityMetadata.Attribute

    private final class Backup {
        let descriptor: Int32

        init(snapshot: BoundedFileSecurityMetadata.Snapshot) throws {
            var template = Array((NSTemporaryDirectory() + "/swiftpods-metadata-XXXXXX").utf8CString)
            let candidate = mkostemp(&template, O_CLOEXEC)
            guard candidate >= 0 else { throw CocoaError(.fileWriteUnknown) }
            template.withUnsafeBufferPointer { buffer in
                if let base = buffer.baseAddress { _ = unlink(base) }
            }
            do {
                try BoundedFileSecurityMetadata.replace(snapshot, on: candidate)
            } catch {
                close(candidate)
                throw error
            }
            descriptor = candidate
        }

        deinit { close(descriptor) }
    }

    let attributes: [Attribute]
    let acl: Data
    private let backup: Backup

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.attributes == rhs.attributes && lhs.acl == rhs.acl
    }

    init(descriptor: Int32) throws {
        let snapshot = try BoundedFileSecurityMetadata.capture(descriptor)
        attributes = snapshot.attributes
        acl = snapshot.acl
        backup = try Backup(snapshot: snapshot)
        try BoundedFileSecurityMetadata.requireUnchanged(descriptor, since: snapshot)
    }

    func apply(to descriptor: Int32) throws {
        let snapshot = try BoundedFileSecurityMetadata.copy(from: backup.descriptor, to: descriptor)
        guard snapshot.attributes == attributes, snapshot.acl == acl else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }
}

/// A same-directory, owner-private holding area for displaced rollback entries. Moving a recovery name here before
/// cleanup prevents ordinary workspace writers from racing the final unlink. A hostile process running as the same
/// UID can still address the directory if it discovers its random name, so every move is followed by token checks and
/// mismatches preserve the directory instead of deleting anything.
final class RollbackQuarantine {
    let name: String
    let descriptor: Int32
    private let parent: Int32
    private let device: UInt64
    private let inode: UInt64
    private var preservesEvidence = false
    private var removed = false

    init(parent: Int32, prefix: String, name explicitName: String? = nil) throws {
        self.parent = parent
        let quarantineName = explicitName ?? ".swiftpods-\(prefix)-quarantine-\(UUID().uuidString)"
        guard !quarantineName.isEmpty, quarantineName != ".", quarantineName != "..",
            !quarantineName.contains("/"), !quarantineName.contains("\\"),
            !quarantineName.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { throw SwiftPodsError("Unsafe rollback quarantine name") }
        name = quarantineName
        guard quarantineName.withCString({ mkdirat(parent, $0, 0o700) }) == 0 else {
            throw SwiftPodsError("Cannot create private rollback quarantine: \(String(cString: strerror(errno)))")
        }
        let candidate = quarantineName.withCString {
            openat(parent, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard candidate >= 0 else {
            _ = quarantineName.withCString { unlinkat(parent, $0, AT_REMOVEDIR) }
            throw SwiftPodsError("Cannot open private rollback quarantine")
        }
        func discardCandidate() {
            close(candidate)
            _ = quarantineName.withCString { unlinkat(parent, $0, AT_REMOVEDIR) }
        }
        guard fchmod(candidate, 0o700) == 0, let emptyACL = acl_init(0) else {
            discardCandidate()
            throw SwiftPodsError("Cannot secure private rollback quarantine permissions")
        }
        errno = 0
        let aclResult = acl_set_fd_np(candidate, emptyACL, ACL_TYPE_EXTENDED)
        let aclFailure = errno
        acl_free(UnsafeMutableRawPointer(emptyACL))
        guard aclResult == 0 || aclFailure == ENOTSUP || aclFailure == EOPNOTSUPP else {
            discardCandidate()
            throw SwiftPodsError("Cannot remove inherited access controls from private rollback quarantine")
        }
        let hasExtendedACL: Bool
        do { hasExtendedACL = try Self.hasExtendedACL(candidate) } catch {
            discardCandidate()
            throw error
        }
        var opened = stat()
        var linked = stat()
        guard !hasExtendedACL, fstat(candidate, &opened) == 0, opened.st_mode & S_IFMT == S_IFDIR,
            opened.st_uid == geteuid(), opened.st_mode & 0o077 == 0,
            quarantineName.withCString({ fstatat(parent, $0, &linked, AT_SYMLINK_NOFOLLOW) }) == 0,
            opened.st_dev == linked.st_dev, opened.st_ino == linked.st_ino
        else {
            discardCandidate()
            throw SwiftPodsError("Private rollback quarantine changed while it was opened")
        }
        descriptor = candidate
        device = UInt64(opened.st_dev)
        inode = UInt64(opened.st_ino)
    }

    deinit {
        let removeEmptyDirectory = !removed && !preservesEvidence && isStillLinked()
        close(descriptor)
        if removeEmptyDirectory {
            // rmdir is intentionally non-recursive: an unexpected entry is evidence and must survive.
            _ = name.withCString { unlinkat(parent, $0, AT_REMOVEDIR) }
        }
    }

    func preserveEvidence() { preservesEvidence = true }

    func finish() throws {
        guard fsync(descriptor) == 0 else {
            preservesEvidence = true
            throw SwiftPodsError("Cannot synchronize private rollback quarantine")
        }
        guard isStillLinked() else {
            preservesEvidence = true
            throw SwiftPodsError("Private rollback quarantine pathname changed; evidence was preserved")
        }
        guard name.withCString({ unlinkat(parent, $0, AT_REMOVEDIR) }) == 0 else {
            preservesEvidence = true
            throw SwiftPodsError("Private rollback quarantine is not empty")
        }
        removed = true
        guard fsync(parent) == 0 else {
            throw SwiftPodsError("Cannot synchronize rollback quarantine removal")
        }
    }

    private func isStillLinked() -> Bool {
        var opened = stat()
        var linked = stat()
        guard let hasExtendedACL = try? Self.hasExtendedACL(descriptor), !hasExtendedACL else { return false }
        return fstat(descriptor, &opened) == 0
            && name.withCString({ fstatat(parent, $0, &linked, AT_SYMLINK_NOFOLLOW) }) == 0
            && UInt64(opened.st_dev) == device && UInt64(opened.st_ino) == inode
            && opened.st_dev == linked.st_dev && opened.st_ino == linked.st_ino
            && linked.st_mode & S_IFMT == S_IFDIR && linked.st_uid == geteuid() && linked.st_mode & 0o077 == 0
    }

    private static func hasExtendedACL(_ descriptor: Int32) throws -> Bool {
        errno = 0
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            let failure = errno
            if failure == ENOENT || failure == ENOTSUP || failure == EOPNOTSUPP { return false }
            throw SwiftPodsError(
                "Cannot inspect private rollback quarantine access controls: \(String(cString: strerror(failure)))")
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        guard acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry) == 0 else {
            throw SwiftPodsError("Cannot inspect private rollback quarantine access controls")
        }
        return entry != nil
    }
}

/// Foundation's JSON decoders accept duplicate object keys and silently keep one value. Lock files are security
/// boundaries, so validate the raw document before decoding it into dictionaries or Codable values.
enum StrictJSONKeyValidator {
    enum Failure: Error {
        case duplicateKey
        case invalidJSON
    }

    private static let defaultMaximumDepth = 128
    private static let defaultMaximumValues = 500_000
    private static let defaultMaximumStringBytes = 16 * 1_024 * 1_024
    private static let defaultMaximumAggregateStringBytes = 16 * 1_024 * 1_024

    static func validate(
        _ data: Data, maximumDepth: Int = defaultMaximumDepth,
        maximumValues: Int = defaultMaximumValues,
        maximumStringBytes: Int = defaultMaximumStringBytes,
        maximumAggregateStringBytes: Int = defaultMaximumAggregateStringBytes
    ) throws {
        guard maximumDepth >= 0, maximumValues > 0, maximumStringBytes >= 0,
            maximumAggregateStringBytes >= 0
        else { throw Failure.invalidJSON }
        var parser = Parser(
            bytes: Array(data), maximumDepth: maximumDepth, maximumValues: maximumValues,
            maximumStringBytes: maximumStringBytes,
            maximumAggregateStringBytes: maximumAggregateStringBytes)
        try parser.parseValue(depth: 0)
        parser.skipWhitespace()
        guard parser.isAtEnd else { throw Failure.invalidJSON }
    }

    private struct Parser {
        let bytes: [UInt8]
        let maximumDepth: Int
        let maximumValues: Int
        let maximumStringBytes: Int
        let maximumAggregateStringBytes: Int
        var position = 0
        var values = 0
        var aggregateStringBytes = 0

        var isAtEnd: Bool { position == bytes.count }

        mutating func parseValue(depth: Int) throws {
            guard depth <= maximumDepth else { throw Failure.invalidJSON }
            values += 1
            guard values <= maximumValues else { throw Failure.invalidJSON }
            skipWhitespace()
            guard position < bytes.count else { throw Failure.invalidJSON }
            switch bytes[position] {
            case 0x7B: try parseObject(depth: depth) // {
            case 0x5B: try parseArray(depth: depth) // [
            case 0x22: _ = try parseString() // "
            case 0x74: try consume(Array("true".utf8))
            case 0x66: try consume(Array("false".utf8))
            case 0x6E: try consume(Array("null".utf8))
            case 0x2D, 0x30...0x39: try parseNumber()
            default: throw Failure.invalidJSON
            }
        }

        mutating func skipWhitespace() {
            while position < bytes.count, [0x09, 0x0A, 0x0D, 0x20].contains(bytes[position]) {
                position += 1
            }
        }

        private mutating func parseObject(depth: Int) throws {
            position += 1
            skipWhitespace()
            if consumeIf(0x7D) { return } // }
            var keys: Set<String> = []
            while true {
                skipWhitespace()
                guard position < bytes.count, bytes[position] == 0x22 else { throw Failure.invalidJSON }
                let key = try parseString()
                guard keys.insert(key).inserted else { throw Failure.duplicateKey }
                skipWhitespace()
                guard consumeIf(0x3A) else { throw Failure.invalidJSON } // :
                try parseValue(depth: depth + 1)
                skipWhitespace()
                if consumeIf(0x7D) { return }
                guard consumeIf(0x2C) else { throw Failure.invalidJSON } // ,
            }
        }

        private mutating func parseArray(depth: Int) throws {
            position += 1
            skipWhitespace()
            if consumeIf(0x5D) { return } // ]
            while true {
                try parseValue(depth: depth + 1)
                skipWhitespace()
                if consumeIf(0x5D) { return }
                guard consumeIf(0x2C) else { throw Failure.invalidJSON } // ,
            }
        }

        private mutating func parseString() throws -> String {
            let start = position
            guard consumeIf(0x22) else { throw Failure.invalidJSON }
            while position < bytes.count {
                let byte = bytes[position]
                position += 1
                switch byte {
                case 0x22:
                    let rawStringBytes = position - start - 2
                    let (newAggregate, overflow) = aggregateStringBytes.addingReportingOverflow(rawStringBytes)
                    guard !overflow, rawStringBytes <= maximumStringBytes,
                        newAggregate <= maximumAggregateStringBytes
                    else { throw Failure.invalidJSON }
                    aggregateStringBytes = newAggregate
                    let token = Data(bytes[start..<position])
                    guard let value = try? JSONDecoder().decode(String.self, from: token) else {
                        throw Failure.invalidJSON
                    }
                    return value
                case 0x5C: // backslash
                    guard position < bytes.count else { throw Failure.invalidJSON }
                    let escape = bytes[position]
                    position += 1
                    if escape == 0x75 { // u
                        guard position + 4 <= bytes.count,
                            bytes[position..<(position + 4)].allSatisfy(Self.isHexDigit)
                        else { throw Failure.invalidJSON }
                        position += 4
                    } else if ![0x22, 0x2F, 0x5C, 0x62, 0x66, 0x6E, 0x72, 0x74].contains(escape) {
                        throw Failure.invalidJSON
                    }
                case 0x00...0x1F:
                    throw Failure.invalidJSON
                default:
                    break
                }
            }
            throw Failure.invalidJSON
        }

        private mutating func parseNumber() throws {
            _ = consumeIf(0x2D) // -
            guard position < bytes.count else { throw Failure.invalidJSON }
            if consumeIf(0x30) { // 0
                guard position == bytes.count || !(0x30...0x39).contains(bytes[position]) else {
                    throw Failure.invalidJSON
                }
            } else {
                guard (0x31...0x39).contains(bytes[position]) else { throw Failure.invalidJSON }
                position += 1
                while position < bytes.count, (0x30...0x39).contains(bytes[position]) { position += 1 }
            }
            if consumeIf(0x2E) { // .
                guard position < bytes.count, (0x30...0x39).contains(bytes[position]) else {
                    throw Failure.invalidJSON
                }
                while position < bytes.count, (0x30...0x39).contains(bytes[position]) { position += 1 }
            }
            if position < bytes.count, bytes[position] == 0x65 || bytes[position] == 0x45 { // e or E
                position += 1
                if position < bytes.count, bytes[position] == 0x2B || bytes[position] == 0x2D { position += 1 }
                guard position < bytes.count, (0x30...0x39).contains(bytes[position]) else {
                    throw Failure.invalidJSON
                }
                while position < bytes.count, (0x30...0x39).contains(bytes[position]) { position += 1 }
            }
        }

        private mutating func consume(_ expected: [UInt8]) throws {
            guard position + expected.count <= bytes.count,
                bytes[position..<(position + expected.count)].elementsEqual(expected)
            else { throw Failure.invalidJSON }
            position += expected.count
        }

        private mutating func consumeIf(_ byte: UInt8) -> Bool {
            guard position < bytes.count, bytes[position] == byte else { return false }
            position += 1
            return true
        }

        private static func isHexDigit(_ byte: UInt8) -> Bool {
            (0x30...0x39).contains(byte) || (0x41...0x46).contains(byte) || (0x61...0x66).contains(byte)
        }
    }
}

/// Xcode's record of resolved package versions, in any of its formats.
struct PackageResolved {
    private static let maximumBytes = 16 * 1_024 * 1_024
    private static let resolvedDirectoryComponents = ["project.xcworkspace", "xcshareddata", "swiftpm"]

    private enum ReadError: Error {
        case notRegular
        case tooLarge
        case changed
    }

    struct Pin: Equatable {
        let location: String
        let version: Version?
        let branch: String?
        let revision: String?
    }

    /// The bytes and complete descriptor-anchored identity of a project's Package.resolved path. Deployment compares
    /// the directory and file metadata as well as the bytes so replacing a path and putting the old bytes back is not
    /// accepted as an unchanged resolution.
    struct PathSnapshot: Equatable {
        fileprivate let directories: [NodeState]
        fileprivate let entry: NodeState?
        fileprivate let metadata: FileSecurityMetadata?
        let data: Data?
    }

    fileprivate struct NodeState: Codable, Equatable {
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

        /// Rename advances ctime. Every independently comparable field, including flags and mtime, must still match
        /// after a swap so a metadata-only concurrent edit is not discarded with the displaced inode.
        func representsAfterRename(_ other: Self) -> Bool {
            isSameObject(as: other) && flags == other.flags && size == other.size
                && modifiedSeconds == other.modifiedSeconds && modifiedNanoseconds == other.modifiedNanoseconds
        }

        func hasRestoredMetadata(of other: Self) -> Bool {
            mode == other.mode && owner == other.owner && group == other.group && flags == other.flags
                && size == other.size && accessedSeconds == other.accessedSeconds
                && accessedNanoseconds == other.accessedNanoseconds
                && modifiedSeconds == other.modifiedSeconds
                && modifiedNanoseconds == other.modifiedNanoseconds
        }

        /// Creating or removing a child necessarily changes a directory's link count, size, mtime, and ctime.
        /// These fields therefore cannot be used while unwinding a suffix that the resolver created.
        func isSameDirectoryObject(as other: Self) -> Bool {
            device == other.device && inode == other.inode && mode == other.mode
                && owner == other.owner && group == other.group && flags == other.flags
        }
    }

    struct DurableState: Codable, Equatable {
        fileprivate let directories: [NodeState]
        fileprivate let entry: NodeState?
        fileprivate let attributes: [FileSecurityMetadata.Attribute]?
        fileprivate let acl: Data?
        fileprivate let dataSHA256: String?
    }

    let pins: [Pin]

    static func location(project: URL) -> URL {
        project.appendingPathComponent("project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
    }

    init(pins: [Pin]) { self.pins = pins }

    init(contentsOf file: URL) throws {
        try self.init(snapshot: Self.snapshot(contentsOf: file), file: file)
    }

    init(snapshot: PathSnapshot, file: URL) throws {
        guard let data = snapshot.data else {
            throw SwiftPodsError("Package.resolved does not exist", file: file.path)
        }
        try self.init(snapshot: data, file: file)
    }

    init(snapshot data: Data, file: URL) throws {
        do {
            try StrictJSONKeyValidator.validate(data)
        } catch StrictJSONKeyValidator.Failure.duplicateKey {
            throw Self.malformed("contains duplicate JSON object keys", file: file.path)
        } catch {
            throw SwiftPodsError("Package.resolved is not valid JSON", file: file.path)
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SwiftPodsError("Package.resolved is not valid JSON", file: file.path)
        }
        pins = try Self.parse(root, file: file.path)
    }

    /// A race-checked raw snapshot suitable for proving a resolver did not modify the lock.
    static func snapshot(contentsOf file: URL) throws -> Data {
        do {
            return try Self.readBoundedRegularFile(file)
        } catch ReadError.notRegular {
            throw SwiftPodsError("Package.resolved must be a regular file", file: file.path)
        } catch ReadError.tooLarge {
            throw SwiftPodsError("Package.resolved exceeds the 16 MiB limit", file: file.path)
        } catch ReadError.changed {
            throw SwiftPodsError("Package.resolved changed while it was being read", file: file.path)
        } catch {
            throw SwiftPodsError("Cannot read \(file.path)", hint: "Commit Package.resolved, or run `swiftpods install --resolve`")
        }
    }

    /// Reads Package.resolved by walking every fixed component below the already validated `.xcodeproj` directory
    /// with `openat(..., O_NOFOLLOW)`. The returned state includes ctime for every component and the final file.
    static func snapshot(project: URL, projectDescriptor: Int32? = nil) throws -> PathSnapshot {
        let file = location(project: project)
        let result = try pathSnapshot(
            project: project, projectDescriptor: projectDescriptor, allowsMissingFile: false)
        guard result.data != nil else {
            throw SwiftPodsError(
                "Cannot read \(file.path)", file: file.path,
                hint: "Commit Package.resolved, or run `swiftpods install --resolve`")
        }
        return result
    }

    /// Rechecks the current pathname after Xcode ran. A missing suffix is representable so a failed `--resolve` can
    /// remove only the directories and file that Xcode created; unsafe intermediate entries are still rejected.
    static func currentSnapshot(project: URL, projectDescriptor: Int32? = nil) throws -> PathSnapshot {
        try pathSnapshot(
            project: project, projectDescriptor: projectDescriptor,
            allowsMissingFile: true, allowsMissingDirectories: true)
    }

    /// Project integration atomically replaces `project.pbxproj`, which legitimately changes only the metadata of the
    /// outer `.xcodeproj` directory. Preserve the originally authenticated lock and every descendant identity while
    /// rebasing that one expected directory-metadata change before invoking Xcode.
    static func snapshotAfterProjectWrite(
        _ original: PathSnapshot, project: URL, projectDescriptor: Int32? = nil
    ) throws -> PathSnapshot {
        let current = try snapshot(project: project, projectDescriptor: projectDescriptor)
        guard original.directories.count == current.directories.count,
            let originalProject = original.directories.first,
            let currentProject = current.directories.first,
            currentProject.isSameDirectoryObject(as: originalProject),
            Array(original.directories.dropFirst()) == Array(current.directories.dropFirst()),
            original.entry == current.entry,
            original.metadata == current.metadata,
            original.data == current.data
        else {
            throw SwiftPodsError(
                "Package.resolved changed after deployment validation",
                file: location(project: project).path,
                hint: "Restore the exact Package.resolved validated at the start of the deployment install")
        }
        return current
    }

    static func verifyUnchanged(
        _ expected: PathSnapshot, project: URL, projectDescriptor: Int32? = nil
    ) throws {
        guard try currentSnapshot(project: project, projectDescriptor: projectDescriptor) == expected else {
            throw SwiftPodsError(
                "Package.resolved changed before transaction commit",
                file: location(project: project).path,
                hint: "A concurrent edit was preserved; review Package.resolved before retrying")
        }
    }

    /// Flushes the resolver result and every existing directory component bottom-up, then repeats the complete
    /// descriptor/CAS snapshot. A journal confirmation is therefore never durable ahead of Package.resolved itself.
    static func synchronize(
        _ expected: PathSnapshot, project: URL, projectDescriptor retainedProjectDescriptor: Int32? = nil
    ) throws {
        let file = location(project: project)
        guard try currentSnapshot(project: project, projectDescriptor: retainedProjectDescriptor) == expected else {
            throw SwiftPodsError("Package.resolved changed before synchronization", file: file.path)
        }
        let projectDescriptor = try openProjectDirectory(
            project: project, retainedDescriptor: retainedProjectDescriptor,
            operation: "synchronizing Package.resolved")
        var descriptors = [projectDescriptor]
        defer { for descriptor in descriptors.reversed() { close(descriptor) } }
        var projectStatus = stat()
        guard let expectedProject = expected.directories.first,
            fstat(projectDescriptor, &projectStatus) == 0, NodeState(projectStatus) == expectedProject
        else { throw SwiftPodsError("Xcode project changed before Package.resolved synchronization", file: file.path) }
        if expected.directories.count > 1 {
            for index in 1..<expected.directories.count {
                let component = resolvedDirectoryComponents[index - 1]
                let parent = descriptors.last!
                let child = component.withCString {
                    openat(parent, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
                }
                guard child >= 0 else {
                    throw SwiftPodsError("Cannot safely open the Package.resolved path for synchronization", file: file.path)
                }
                var opened = stat()
                var linked = stat()
                guard fstat(child, &opened) == 0, NodeState(opened) == expected.directories[index],
                    component.withCString({ fstatat(parent, $0, &linked, AT_SYMLINK_NOFOLLOW) }) == 0,
                    NodeState(linked) == NodeState(opened)
                else {
                    close(child)
                    throw SwiftPodsError("Package.resolved path changed before synchronization", file: file.path)
                }
                descriptors.append(child)
            }
        }
        if let expectedEntry = expected.entry {
            guard expected.directories.count == resolvedDirectoryComponents.count + 1 else {
                throw SwiftPodsError("Package.resolved has an inconsistent synchronization snapshot", file: file.path)
            }
            let parent = descriptors.last!
            let descriptor = "Package.resolved".withCString {
                openat(parent, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            }
            guard descriptor >= 0 else {
                throw SwiftPodsError("Cannot safely open Package.resolved for synchronization", file: file.path)
            }
            var opened = stat()
            var final = stat()
            var linked = stat()
            let synchronized = fstat(descriptor, &opened) == 0 && NodeState(opened) == expectedEntry
                && fsync(descriptor) == 0 && fstat(descriptor, &final) == 0
                && NodeState(final) == NodeState(opened)
                && "Package.resolved".withCString({
                    fstatat(parent, $0, &linked, AT_SYMLINK_NOFOLLOW)
                }) == 0
                && NodeState(linked) == NodeState(final)
            close(descriptor)
            guard synchronized else {
                throw SwiftPodsError("Package.resolved changed while it was synchronized", file: file.path)
            }
        } else {
            guard expected.data == nil, expected.metadata == nil else {
                throw SwiftPodsError("Package.resolved has an inconsistent synchronization snapshot", file: file.path)
            }
        }
        for descriptor in descriptors.reversed() {
            guard fsync(descriptor) == 0 else {
                throw SwiftPodsError("Cannot synchronize the Package.resolved path", file: file.path)
            }
        }
        guard try currentSnapshot(project: project, projectDescriptor: retainedProjectDescriptor) == expected else {
            throw SwiftPodsError("Package.resolved changed while it was synchronized", file: file.path)
        }
    }

    static func durableState(of snapshot: PathSnapshot) -> DurableState {
        DurableState(
            directories: snapshot.directories,
            entry: snapshot.entry,
            attributes: snapshot.metadata?.attributes,
            acl: snapshot.metadata?.acl,
            dataSHA256: snapshot.data.map(Self.sha256))
    }

    /// Checks every pre-existing object that rollback may have to replace or remove.  A missing suffix is safe: any
    /// directories subsequently created by Xcode are authenticated again before recovery removes them.
    static func requireRollbackSafe(_ snapshot: PathSnapshot, file: URL) throws {
        for directory in snapshot.directories {
            do { try RollbackFileFlags.requireRemovable(directory.flags, kind: "Package.resolved directory") } catch {
                throw SwiftPodsError("Package.resolved cannot be transactionally updated: \(error)", file: file.path)
            }
        }
        if let entry = snapshot.entry {
            do { try RollbackFileFlags.requireRemovable(entry.flags, kind: "Package.resolved file") } catch {
                throw SwiftPodsError("Package.resolved cannot be transactionally updated: \(error)", file: file.path)
            }
        }
    }

    static func requireRollbackSafe(_ state: DurableState, file: URL) throws {
        for directory in state.directories {
            do { try RollbackFileFlags.requireRemovable(directory.flags, kind: "Package.resolved directory") } catch {
                throw SwiftPodsError("Package.resolved recovery record is not removable: \(error)", file: file.path)
            }
        }
        if let entry = state.entry {
            do { try RollbackFileFlags.requireRemovable(entry.flags, kind: "Package.resolved file") } catch {
                throw SwiftPodsError("Package.resolved recovery record is not removable: \(error)", file: file.path)
            }
        }
    }

    static func matches(_ snapshot: PathSnapshot, durable state: DurableState) -> Bool {
        durableState(of: snapshot) == state
    }

    /// A rollback recreates the final file inode and necessarily advances directory timestamps. This comparison keeps
    /// the authenticated directory objects and exact file bytes/security metadata, while allowing only those expected
    /// identity/timestamp changes caused by restoration.
    static func representsOriginal(_ snapshot: PathSnapshot, durable state: DurableState) -> Bool {
        guard snapshot.directories.count == state.directories.count else { return false }
        for index in snapshot.directories.indices {
            guard snapshot.directories[index].isSameDirectoryObject(as: state.directories[index]) else { return false }
        }
        switch (snapshot.entry, state.entry) {
        case (nil, nil):
            return snapshot.metadata == nil && snapshot.data == nil
                && state.attributes == nil && state.acl == nil && state.dataSHA256 == nil
        case (let entry?, let original?):
            // Reading the restored file may advance atime, so it is not durable CAS evidence. All independently
            // stable metadata restored by the rollback (including flags and mtime) must still match exactly.
            return entry.mode == original.mode && entry.owner == original.owner && entry.group == original.group
                && entry.flags == original.flags && entry.size == original.size
                && entry.modifiedSeconds == original.modifiedSeconds
                && entry.modifiedNanoseconds == original.modifiedNanoseconds
                && snapshot.metadata?.attributes == state.attributes
                && snapshot.metadata?.acl == state.acl
                && snapshot.data.map(Self.sha256) == state.dataSHA256
        default:
            return false
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Reconstructs an original in-memory snapshot from its durable, metadata-preserving backup and delegates to the
    /// normal descriptor/CAS rollback. A missing original has no backup and removes only the resolver-created suffix.
    static func restore(
        durable original: DurableState, backup: URL?, project: URL, replacing expected: PathSnapshot
    ) throws {
        var descriptor: Int32?
        if let backup {
            let opened = backup.path.withCString {
                open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            }
            guard opened >= 0 else {
                throw SwiftPodsError(
                    "Cannot safely open the durable Package.resolved recovery backup",
                    file: location(project: project).path)
            }
            descriptor = opened
        }
        defer { if let descriptor { close(descriptor) } }
        try restore(
            durable: original, backupDescriptor: descriptor,
            project: project, replacing: expected)
    }

    static func restore(
        durable original: DurableState, backupDescriptor: Int32?, project: URL,
        replacing expected: PathSnapshot
    ) throws {
        try requireRollbackSafe(original, file: location(project: project))
        let reconstructed: PathSnapshot
        if original.entry == nil {
            guard backupDescriptor == nil, original.attributes == nil, original.acl == nil,
                original.dataSHA256 == nil
            else {
                throw SwiftPodsError(
                    "Durable Package.resolved recovery record is inconsistent",
                    file: location(project: project).path)
            }
            reconstructed = PathSnapshot(
                directories: original.directories, entry: nil, metadata: nil, data: nil)
        } else {
            guard let descriptor = backupDescriptor, let expectedDigest = original.dataSHA256 else {
                throw SwiftPodsError(
                    "Durable Package.resolved recovery backup is missing",
                    file: location(project: project).path)
            }
            var status = stat()
            guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
                status.st_size >= 0, status.st_size <= maximumBytes
            else {
                throw SwiftPodsError(
                    "Durable Package.resolved recovery backup is not a bounded regular file",
                    file: location(project: project).path)
            }
            let duplicate = duplicateCloseOnExec(descriptor)
            guard duplicate >= 0 else {
                throw SwiftPodsError(
                    "Cannot duplicate the durable Package.resolved recovery backup",
                    file: location(project: project).path)
            }
            let handle = FileHandle(fileDescriptor: duplicate, closeOnDealloc: true)
            defer { try? handle.close() }
            var data = Data()
            while let chunk = try handle.read(upToCount: min(1 << 20, maximumBytes + 1 - data.count)),
                !chunk.isEmpty
            {
                data.append(chunk)
                guard data.count <= maximumBytes else {
                    throw SwiftPodsError(
                        "Durable Package.resolved recovery backup is too large",
                        file: location(project: project).path)
                }
            }
            let metadata = try FileSecurityMetadata(descriptor: descriptor)
            guard Self.sha256(data) == expectedDigest,
                metadata.attributes == original.attributes,
                metadata.acl == original.acl
            else {
                throw SwiftPodsError(
                    "Durable Package.resolved recovery backup changed",
                    file: location(project: project).path)
            }
            reconstructed = PathSnapshot(
                directories: original.directories, entry: original.entry,
                metadata: metadata, data: data)
        }
        try restore(reconstructed, project: project, replacing: expected)
    }

    /// Crash-idempotent recovery used by the durable install journal. Every intermediate pathname is derived from the
    /// journal-recorded UUID, so a restart recognizes only its own source/removal/quarantine entries and never scans
    /// for or deletes wildcard-matching workspace files.
    static func recoverJournaled(
        durable original: DurableState, installed: DurableState, backupDescriptor: Int32?,
        project: URL, recoveryID: String, allowsProgress: Bool
    ) throws {
        try requireRollbackSafe(original, file: location(project: project))
        try requireRollbackSafe(installed, file: location(project: project))
        guard UUID(uuidString: recoveryID) != nil else {
            throw SwiftPodsError("Package.resolved recovery has an invalid journal identity", file: location(project: project).path)
        }
        if original.entry != nil {
            guard backupDescriptor != nil, original.directories.count == resolvedDirectoryComponents.count + 1 else {
                throw SwiftPodsError("Package.resolved recovery record is inconsistent", file: location(project: project).path)
            }
            try recoverExistingJournaled(
                original: original, installed: installed, backupDescriptor: backupDescriptor!,
                project: project, recoveryID: recoveryID, allowsProgress: allowsProgress)
        } else {
            guard backupDescriptor == nil, original.attributes == nil, original.acl == nil,
                original.dataSHA256 == nil
            else {
                throw SwiftPodsError("Package.resolved recovery record is inconsistent", file: location(project: project).path)
            }
            try recoverMissingJournaled(
                original: original, installed: installed, project: project,
                recoveryID: recoveryID, allowsProgress: allowsProgress)
        }
    }

    private static func recoverExistingJournaled(
        original: DurableState, installed: DurableState, backupDescriptor: Int32,
        project: URL, recoveryID: String, allowsProgress: Bool
    ) throws {
        let file = location(project: project)
        let recoveryName = ".Package.resolved.swiftpods-journal-\(recoveryID)"
        let descriptors = try openRecoveryDirectories(project: project, expected: original.directories)
        defer { for descriptor in descriptors.reversed() { close(descriptor) } }
        guard descriptors.count == original.directories.count else {
            throw SwiftPodsError("Package.resolved recovery parent disappeared", file: file.path)
        }
        let parent = descriptors.last!
        var current = try currentSnapshot(project: project)
        if matches(current, durable: installed) {
            try ensureJournalRecoverySource(
                named: recoveryName, in: parent, backupDescriptor: backupDescriptor,
                original: original, file: file)
            guard try namedFileMatches(
                recoveryName, in: parent, durable: original, identity: .restored, file: file)
            else {
                throw SwiftPodsError("Package.resolved journal recovery source changed", file: file.path)
            }
            let swapped = recoveryName.withCString { source in
                "Package.resolved".withCString {
                    renameatx_np(parent, source, parent, $0, UInt32(RENAME_SWAP))
                }
            }
            guard swapped == 0, fsync(parent) == 0 else {
                throw SwiftPodsError("Cannot durably restore Package.resolved from its journal", file: file.path)
            }
            current = try currentSnapshot(project: project)
        } else if !representsOriginal(current, durable: original) {
            guard allowsProgress else {
                throw SwiftPodsError("Package.resolved changed before journal recovery", file: file.path)
            }
            throw SwiftPodsError(
                "Package.resolved has an unknown journal recovery state; evidence was preserved", file: file.path)
        }
        guard representsOriginal(current, durable: original) else {
            throw SwiftPodsError("Package.resolved journal recovery did not restore the original file", file: file.path)
        }
        if try namedEntryExists(recoveryName, in: parent) {
            guard try namedFileMatches(
                recoveryName, in: parent, durable: installed, identity: .renamed, file: file)
            else {
                throw SwiftPodsError(
                    "Package.resolved journal residue has unknown contents; evidence was preserved", file: file.path)
            }
            let first = try readFinalEntry(named: recoveryName, in: parent, allowsMissing: false, file: file)
            let second = try readFinalEntry(named: recoveryName, in: parent, allowsMissing: false, file: file)
            guard first.entry == second.entry, first.metadata == second.metadata, first.data == second.data,
                recoveryName.withCString({ unlinkat(parent, $0, 0) }) == 0,
                fsync(parent) == 0
            else {
                throw SwiftPodsError("Cannot safely remove Package.resolved journal residue", file: file.path)
            }
        }
        try synchronizeRecoveryDirectories(descriptors, expected: original.directories, file: file)
        guard representsOriginal(try currentSnapshot(project: project), durable: original) else {
            throw SwiftPodsError("Package.resolved changed after journal recovery", file: file.path)
        }
    }

    private enum JournalFileIdentity {
        case restored
        case renamed
    }

    private static func ensureJournalRecoverySource(
        named name: String, in parent: Int32, backupDescriptor: Int32,
        original: DurableState, file: URL
    ) throws {
        if try namedEntryExists(name, in: parent) {
            guard try namedFileMatches(name, in: parent, durable: original, identity: .restored, file: file) else {
                throw SwiftPodsError(
                    "Package.resolved journal recovery source has unknown contents; evidence was preserved",
                    file: file.path)
            }
            return
        }
        guard let originalEntry = original.entry else {
            throw SwiftPodsError("Package.resolved journal recovery has no original entry", file: file.path)
        }
        try requireRollbackSafe(original, file: file)
        let output = name.withCString {
            openat(parent, $0, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        }
        guard output >= 0 else {
            throw SwiftPodsError("Cannot create Package.resolved journal recovery source", file: file.path)
        }
        var removeOutput = true
        defer {
            close(output)
            if removeOutput { _ = name.withCString { unlinkat(parent, $0, 0) } }
        }
        guard lseek(backupDescriptor, 0, SEEK_SET) >= 0,
            fcopyfile(backupDescriptor, output, nil, copyfile_flags_t(COPYFILE_DATA)) == 0,
            fchown(output, uid_t(originalEntry.owner), gid_t(originalEntry.group)) == 0,
            fchmod(output, mode_t(originalEntry.mode & 0o7777)) == 0
        else { throw SwiftPodsError("Cannot copy Package.resolved journal recovery source", file: file.path) }
        do {
            try FileSecurityMetadata(descriptor: backupDescriptor).apply(to: output)
        } catch {
            throw SwiftPodsError("Cannot restore Package.resolved journal security metadata", file: file.path)
        }
        var times = [
            timespec(tv_sec: time_t(originalEntry.accessedSeconds), tv_nsec: Int(originalEntry.accessedNanoseconds)),
            timespec(tv_sec: time_t(originalEntry.modifiedSeconds), tv_nsec: Int(originalEntry.modifiedNanoseconds)),
        ]
        guard futimens(output, &times) == 0, fchflags(output, originalEntry.flags) == 0,
            fsync(output) == 0, fsync(parent) == 0
        else { throw SwiftPodsError("Cannot synchronize Package.resolved journal recovery source", file: file.path) }
        removeOutput = false
        guard try namedFileMatches(name, in: parent, durable: original, identity: .restored, file: file) else {
            throw SwiftPodsError("Package.resolved journal recovery source does not match its backup", file: file.path)
        }
    }

    private static func recoverMissingJournaled(
        original: DurableState, installed: DurableState, project: URL,
        recoveryID: String, allowsProgress: Bool
    ) throws {
        let file = location(project: project)
        guard installed.directories.count >= original.directories.count,
            installed.directories.count <= resolvedDirectoryComponents.count + 1
        else { throw SwiftPodsError("Package.resolved recovery path record is inconsistent", file: file.path) }
        var descriptors = try openExistingRecoveryDirectories(project: project, expected: installed.directories)
        defer { for descriptor in descriptors.reversed() { close(descriptor) } }
        let removalName = ".Package.resolved.swiftpods-journal-removed-\(recoveryID)"
        if descriptors.count == installed.directories.count,
            descriptors.count == resolvedDirectoryComponents.count + 1
        {
            let parent = descriptors.last!
            let finalExists = try namedEntryExists("Package.resolved", in: parent)
            let residueExists = try namedEntryExists(removalName, in: parent)
            guard !(finalExists && residueExists) else {
                throw SwiftPodsError("Package.resolved recovery has two competing entries", file: file.path)
            }
            if finalExists {
                guard try namedFileMatches(
                    "Package.resolved", in: parent, durable: installed, identity: .renamed, file: file),
                    allowsProgress
                else {
                    throw SwiftPodsError(
                        "Package.resolved changed before journal removal; evidence was preserved", file: file.path)
                }
                guard "Package.resolved".withCString({ source in
                    removalName.withCString {
                        renameatx_np(parent, source, parent, $0, UInt32(RENAME_EXCL))
                    }
                }) == 0, fsync(parent) == 0 else {
                    throw SwiftPodsError("Cannot durably stage Package.resolved journal removal", file: file.path)
                }
            }
            if try namedEntryExists(removalName, in: parent) {
                guard try namedFileMatches(
                    removalName, in: parent, durable: installed, identity: .renamed, file: file)
                else {
                    throw SwiftPodsError(
                        "Package.resolved removal residue has unknown contents; evidence was preserved", file: file.path)
                }
                let first = try readFinalEntry(named: removalName, in: parent, allowsMissing: false, file: file)
                let second = try readFinalEntry(named: removalName, in: parent, allowsMissing: false, file: file)
                guard first.entry == second.entry, first.metadata == second.metadata, first.data == second.data,
                    removalName.withCString({ unlinkat(parent, $0, 0) }) == 0,
                    fsync(parent) == 0
                else { throw SwiftPodsError("Cannot safely finish Package.resolved journal removal", file: file.path) }
            }
        } else if !allowsProgress {
            throw SwiftPodsError("Package.resolved path disappeared before journal recovery", file: file.path)
        }
        for descriptor in descriptors.reversed() { close(descriptor) }
        descriptors.removeAll(keepingCapacity: false)

        if installed.directories.count > original.directories.count {
            for index in stride(
                from: installed.directories.count - 1,
                through: original.directories.count,
                by: -1
            ) {
                let parentDescriptors = try openExistingRecoveryDirectories(
                    project: project, expected: Array(installed.directories.prefix(index)))
                defer { for descriptor in parentDescriptors.reversed() { close(descriptor) } }
                guard parentDescriptors.count == index else { continue }
                let parent = parentDescriptors.last!
                let component = resolvedDirectoryComponents[index - 1]
                let quarantine = ".swiftpods-package-journal-\(recoveryID)-\(index)"
                let sourceExists = try namedEntryExists(component, in: parent)
                let quarantineExists = try namedEntryExists(quarantine, in: parent)
                guard !(sourceExists && quarantineExists) else {
                    throw SwiftPodsError("Package.resolved directory recovery has competing entries", file: file.path)
                }
                if sourceExists {
                    let child = try openRecoveryDirectory(
                        named: component, in: parent, expected: installed.directories[index], file: file)
                    defer { close(child) }
                    if component == "swiftpm" { try removeEmptyResolverConfiguration(in: child, file: file) }
                    guard try directoryIsEmpty(child) else {
                        throw SwiftPodsError(
                            "A resolver-created Package.resolved directory is not empty; evidence was preserved",
                            file: file.path)
                    }
                    guard component.withCString({ source in
                        quarantine.withCString {
                            renameatx_np(parent, source, parent, $0, UInt32(RENAME_EXCL))
                        }
                    }) == 0, fsync(parent) == 0 else {
                        throw SwiftPodsError("Cannot durably quarantine a resolver-created directory", file: file.path)
                    }
                }
                if try namedEntryExists(quarantine, in: parent) {
                    let child = try openRecoveryDirectory(
                        named: quarantine, in: parent, expected: installed.directories[index], file: file)
                    defer { close(child) }
                    if component == "swiftpm" { try removeEmptyResolverConfiguration(in: child, file: file) }
                    guard try directoryIsEmpty(child),
                        quarantine.withCString({ unlinkat(parent, $0, AT_REMOVEDIR) }) == 0,
                        fsync(parent) == 0
                    else {
                        throw SwiftPodsError("Cannot safely remove a resolver-created directory", file: file.path)
                    }
                }
            }
        }
        let originalDescriptors = try openRecoveryDirectories(project: project, expected: original.directories)
        defer { for descriptor in originalDescriptors.reversed() { close(descriptor) } }
        try synchronizeRecoveryDirectories(originalDescriptors, expected: original.directories, file: file)
        guard representsOriginal(try currentSnapshot(project: project), durable: original) else {
            throw SwiftPodsError("Package.resolved missing-path journal recovery is incomplete", file: file.path)
        }
    }

    private static func openRecoveryDirectories(
        project: URL, expected: [NodeState]
    ) throws -> [Int32] {
        let result = try openExistingRecoveryDirectories(project: project, expected: expected)
        guard result.count == expected.count else {
            for descriptor in result.reversed() { close(descriptor) }
            throw SwiftPodsError("Package.resolved recovery path is missing", file: location(project: project).path)
        }
        return result
    }

    private static func openExistingRecoveryDirectories(
        project: URL, expected: [NodeState]
    ) throws -> [Int32] {
        guard !expected.isEmpty, expected.count <= resolvedDirectoryComponents.count + 1 else {
            throw SwiftPodsError("Package.resolved recovery directory record is inconsistent", file: location(project: project).path)
        }
        let first = project.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard first >= 0 else {
            throw SwiftPodsError("Cannot open Xcode project for Package.resolved recovery", file: location(project: project).path)
        }
        var result = [first]
        var status = stat()
        guard fstat(first, &status) == 0, NodeState(status).isSameDirectoryObject(as: expected[0]) else {
            close(first)
            throw SwiftPodsError("Xcode project changed before Package.resolved recovery", file: location(project: project).path)
        }
        if expected.count > 1 {
            for index in 1..<expected.count {
                let parent = result.last!
                let component = resolvedDirectoryComponents[index - 1]
                let child = component.withCString {
                    openat(parent, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
                }
                if child < 0, errno == ENOENT { break }
                guard child >= 0 else {
                    for descriptor in result.reversed() { close(descriptor) }
                    throw SwiftPodsError("Cannot open Package.resolved recovery path", file: location(project: project).path)
                }
                var opened = stat()
                var linked = stat()
                guard fstat(child, &opened) == 0,
                    NodeState(opened).isSameDirectoryObject(as: expected[index]),
                    component.withCString({ fstatat(parent, $0, &linked, AT_SYMLINK_NOFOLLOW) }) == 0,
                    NodeState(linked).isSameDirectoryObject(as: NodeState(opened))
                else {
                    close(child)
                    for descriptor in result.reversed() { close(descriptor) }
                    throw SwiftPodsError("Package.resolved recovery path changed", file: location(project: project).path)
                }
                result.append(child)
            }
        }
        return result
    }

    private static func openRecoveryDirectory(
        named name: String, in parent: Int32, expected: NodeState, file: URL
    ) throws -> Int32 {
        let descriptor = name.withCString {
            openat(parent, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else { throw SwiftPodsError("Cannot open Package.resolved recovery directory", file: file.path) }
        var opened = stat()
        var linked = stat()
        guard fstat(descriptor, &opened) == 0,
            NodeState(opened).isSameDirectoryObject(as: expected),
            name.withCString({ fstatat(parent, $0, &linked, AT_SYMLINK_NOFOLLOW) }) == 0,
            NodeState(linked).isSameDirectoryObject(as: NodeState(opened))
        else {
            close(descriptor)
            throw SwiftPodsError("Package.resolved recovery directory changed", file: file.path)
        }
        return descriptor
    }

    private static func synchronizeRecoveryDirectories(
        _ descriptors: [Int32], expected: [NodeState], file: URL
    ) throws {
        guard descriptors.count == expected.count else {
            throw SwiftPodsError("Package.resolved recovery path is incomplete", file: file.path)
        }
        for (index, descriptor) in descriptors.enumerated().reversed() {
            var status = stat()
            guard fstat(descriptor, &status) == 0,
                NodeState(status).isSameDirectoryObject(as: expected[index]), fsync(descriptor) == 0
            else { throw SwiftPodsError("Cannot synchronize Package.resolved recovery path", file: file.path) }
        }
    }

    private static func namedEntryExists(_ name: String, in parent: Int32) throws -> Bool {
        var status = stat()
        if name.withCString({ fstatat(parent, $0, &status, AT_SYMLINK_NOFOLLOW) }) == 0 { return true }
        if errno == ENOENT { return false }
        throw SwiftPodsError("Cannot inspect Package.resolved journal recovery entry")
    }

    private static func namedFileMatches(
        _ name: String, in parent: Int32, durable: DurableState,
        identity: JournalFileIdentity, file: URL
    ) throws -> Bool {
        guard let expected = durable.entry, let expectedDigest = durable.dataSHA256 else { return false }
        let value = try readFinalEntry(named: name, in: parent, allowsMissing: false, file: file)
        guard let entry = value.entry, value.metadata?.attributes == durable.attributes,
            value.metadata?.acl == durable.acl, value.data.map(sha256) == expectedDigest
        else { return false }
        switch identity {
        case .restored:
            // Reading the candidate may advance atime. Every independently stable/restored field still has to match.
            return entry.mode == expected.mode && entry.owner == expected.owner && entry.group == expected.group
                && entry.flags == expected.flags && entry.size == expected.size
                && entry.modifiedSeconds == expected.modifiedSeconds
                && entry.modifiedNanoseconds == expected.modifiedNanoseconds
        case .renamed:
            return entry == expected || entry.representsAfterRename(expected)
        }
    }

    private static func directoryIsEmpty(_ descriptor: Int32) throws -> Bool {
        let duplicate = openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard duplicate >= 0, let stream = fdopendir(duplicate) else {
            if duplicate >= 0 { close(duplicate) }
            throw SwiftPodsError("Cannot enumerate Package.resolved recovery directory")
        }
        defer { closedir(stream) }
        errno = 0
        while let entry = readdir(stream) {
            var bytes = entry.pointee.d_name
            let name = withUnsafeBytes(of: &bytes) {
                String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self))
            }
            if name != "." && name != ".." { return false }
            errno = 0
        }
        guard errno == 0 else { throw SwiftPodsError("Cannot enumerate Package.resolved recovery directory") }
        return true
    }

    /// Before invoking Xcode, reject every symbolic link already present in the fixed path. Missing suffix components
    /// are allowed for `--resolve`, because Xcode may create its normal workspace metadata directories.
    static func validateResolverPath(project: URL, projectDescriptor retainedProjectDescriptor: Int32? = nil) throws {
        let projectDescriptor = try openProjectDirectory(
            project: project, retainedDescriptor: retainedProjectDescriptor,
            operation: "validating the package resolver path")
        var descriptors = [projectDescriptor]
        defer { for descriptor in descriptors.reversed() { close(descriptor) } }
        for component in resolvedDirectoryComponents {
            let parent = descriptors.last!
            var linked = stat()
            guard component.withCString({ fstatat(parent, $0, &linked, AT_SYMLINK_NOFOLLOW) }) == 0 else {
                if errno == ENOENT { return }
                throw SwiftPodsError("Cannot inspect the Package.resolved path", file: location(project: project).path)
            }
            guard linked.st_mode & S_IFMT == S_IFDIR else {
                throw SwiftPodsError(
                    "Package.resolved path component `\(component)` must be a real directory", file: location(project: project).path)
            }
            let child = component.withCString {
                openat(parent, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            }
            guard child >= 0 else {
                throw SwiftPodsError("Cannot safely open the Package.resolved path", file: location(project: project).path)
            }
            var opened = stat()
            guard fstat(child, &opened) == 0, NodeState(opened) == NodeState(linked) else {
                close(child)
                throw SwiftPodsError("Package.resolved path changed while it was validated", file: location(project: project).path)
            }
            descriptors.append(child)
        }
        var entry = stat()
        let found = "Package.resolved".withCString {
            fstatat(descriptors.last!, $0, &entry, AT_SYMLINK_NOFOLLOW)
        }
        if found == 0 {
            guard entry.st_mode & S_IFMT == S_IFREG else {
                throw SwiftPodsError("Package.resolved must be a regular file", file: location(project: project).path)
            }
        } else if errno != ENOENT {
            throw SwiftPodsError("Cannot inspect Package.resolved", file: location(project: project).path)
        }
    }

    /// Restores the pre-Xcode bytes only if the path still exactly matches the post-Xcode snapshot supplied by the
    /// caller. A concurrent third-party edit is preserved: a swap is verified and swapped back on any mismatch.
    static func restore(
        _ original: PathSnapshot, project: URL, projectDescriptor retainedProjectDescriptor: Int32? = nil,
        replacing expected: PathSnapshot,
        afterSwapForTesting: (() -> Void)? = nil,
        beforeReverseSwapForTesting: (() -> Void)? = nil,
        beforeMissingSourceRenameForTesting: (() -> Void)? = nil,
        beforeCleanupForTesting: (() -> Void)? = nil
    ) throws {
        let file = location(project: project)
        try requireRollbackSafe(original, file: file)
        try requireRollbackSafe(expected, file: file)
        guard isConsistentPathSnapshot(original), isConsistentPathSnapshot(expected),
            expected.directories.count >= original.directories.count
        else {
            throw SwiftPodsError("Cannot restore an inconsistent Package.resolved path snapshot", file: file.path)
        }
        for index in original.directories.indices {
            guard expected.directories[index].isSameDirectoryObject(as: original.directories[index]) else {
                throw SwiftPodsError(
                    "A pre-existing Package.resolved directory was replaced; refusing restoration", file: file.path)
            }
        }
        let current = try currentSnapshot(project: project, projectDescriptor: retainedProjectDescriptor)
        guard current == expected else {
            throw SwiftPodsError(
                "Package.resolved changed again; refusing to overwrite a concurrent edit", file: file.path)
        }

        let projectDescriptor = try openProjectDirectory(
            project: project, retainedDescriptor: retainedProjectDescriptor,
            operation: "restoring Package.resolved")
        var descriptors = [projectDescriptor]
        defer { for descriptor in descriptors.reversed() { close(descriptor) } }
        var projectStatus = stat()
        guard fstat(projectDescriptor, &projectStatus) == 0,
            NodeState(projectStatus) == expected.directories[0]
        else { throw SwiftPodsError("Xcode project changed; refusing Package.resolved restoration", file: file.path) }
        for index in 1..<expected.directories.count {
            let component = resolvedDirectoryComponents[index - 1]
            let parent = descriptors.last!
            let child = component.withCString {
                openat(parent, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            }
            guard child >= 0 else { throw SwiftPodsError("Cannot safely reopen the Package.resolved path", file: file.path) }
            var status = stat()
            guard fstat(child, &status) == 0, NodeState(status) == expected.directories[index] else {
                close(child)
                throw SwiftPodsError("Package.resolved parent changed; refusing restoration", file: file.path)
            }
            descriptors.append(child)
        }
        let parent = descriptors.last!
        guard flock(parent, LOCK_EX | LOCK_NB) == 0 else {
            throw SwiftPodsError("Another process is updating Package.resolved", file: file.path)
        }
        defer { flock(parent, LOCK_UN) }
        guard try currentSnapshot(project: project, projectDescriptor: retainedProjectDescriptor) == expected else {
            throw SwiftPodsError("Package.resolved changed again; refusing restoration", file: file.path)
        }

        if original.entry == nil, original.data == nil {
            if expected.entry != nil {
                guard expected.directories.count == resolvedDirectoryComponents.count + 1 else {
                    throw SwiftPodsError("Package.resolved exists below an incomplete path snapshot", file: file.path)
                }
                let removed = ".Package.resolved.swiftpods-removed-" + UUID().uuidString
                guard "Package.resolved".withCString({ source in
                    removed.withCString {
                        renameatx_np(parent, source, parent, $0, UInt32(RENAME_EXCL))
                    }
                }) == 0 else {
                    throw SwiftPodsError("Package.resolved changed again; refusing removal", file: file.path)
                }
                let displaced = try readFinalEntry(
                    named: removed, in: parent, allowsMissing: false, file: file)
                guard let displacedEntry = displaced.entry, let expectedEntry = expected.entry,
                    displacedEntry.representsAfterRename(expectedEntry), displaced.metadata == expected.metadata,
                    displaced.data == expected.data
                else {
                    throw SwiftPodsError(
                        "Package.resolved changed during removal; recovery evidence remains at \(removed)",
                        file: file.path)
                }
                try quarantineAndRemoveRecovery(
                    named: removed, in: parent, expected: displaced, file: file,
                    beforeMoveForTesting: beforeCleanupForTesting)
                guard fsync(parent) == 0 else {
                    throw SwiftPodsError("Cannot finalize Package.resolved rollback", file: file.path)
                }
            }
            try removeCreatedDirectories(
                after: original.directories.count, descriptors: descriptors,
                expected: expected.directories, file: file)
            return
        }
        guard let originalData = original.data, let originalEntry = original.entry,
            let originalMetadata = original.metadata,
            original.directories.count == resolvedDirectoryComponents.count + 1,
            expected.directories.count == resolvedDirectoryComponents.count + 1
        else {
            throw SwiftPodsError("Cannot restore an inconsistent Package.resolved snapshot", file: file.path)
        }

        let temporary = ".Package.resolved.swiftpods-" + UUID().uuidString
        let output = temporary.withCString {
            openat(parent, $0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        }
        guard output >= 0 else { throw SwiftPodsError("Cannot create a Package.resolved recovery file", file: file.path) }
        var temporaryExists = true
        defer {
            close(output)
            if temporaryExists { _ = temporary.withCString { unlinkat(parent, $0, 0) } }
        }
        try write(originalData, to: output, file: file)
        // chown may clear set-id bits, while chmod may rewrite ACL masks. Restore owner and mode first, then the
        // exact ACL/xattrs, timestamps, and flags in that order.
        var restoredTimes = [
            timespec(tv_sec: time_t(originalEntry.accessedSeconds), tv_nsec: Int(originalEntry.accessedNanoseconds)),
            timespec(tv_sec: time_t(originalEntry.modifiedSeconds), tv_nsec: Int(originalEntry.modifiedNanoseconds)),
        ]
        guard fchown(output, uid_t(originalEntry.owner), gid_t(originalEntry.group)) == 0,
            fchmod(output, mode_t(originalEntry.mode & 0o7777)) == 0
        else { throw SwiftPodsError("Cannot restore Package.resolved ownership or mode", file: file.path) }
        do { try originalMetadata.apply(to: output) } catch {
            throw SwiftPodsError("Cannot restore Package.resolved ACLs or extended attributes", file: file.path)
        }
        guard futimens(output, &restoredTimes) == 0,
            fchflags(output, originalEntry.flags) == 0, fsync(output) == 0
        else { throw SwiftPodsError("Cannot finalize the Package.resolved recovery file", file: file.path) }

        // The temporary name changes only the parent directory. The final entry must still be exactly what was
        // observed after Xcode before the atomic rename is attempted.
        let immediatelyBefore = try readFinalEntry(in: parent, allowsMissing: true, file: file)
        guard immediatelyBefore.entry == expected.entry, immediatelyBefore.metadata == expected.metadata,
            immediatelyBefore.data == expected.data
        else {
            throw SwiftPodsError("Package.resolved changed again; refusing restoration", file: file.path)
        }
        if expected.entry == nil {
            let quarantine = try RollbackQuarantine(parent: parent, prefix: "package-resolved-source")
            let source = "recovery"
            let evidence = "original-evidence"
            guard temporary.withCString({ value in
                source.withCString {
                    renameatx_np(parent, value, quarantine.descriptor, $0, UInt32(RENAME_EXCL))
                }
            }) == 0 else { throw SwiftPodsError("Cannot quarantine Package.resolved recovery source", file: file.path) }
            temporaryExists = false
            quarantine.preserveEvidence()
            let moved = try readFinalEntry(
                named: source, in: quarantine.descriptor, allowsMissing: false, file: file)
            var outputStatus = stat()
            var sourceStatus = stat()
            guard let movedEntry = moved.entry,
                movedEntry.hasRestoredMetadata(of: originalEntry), moved.metadata == originalMetadata,
                moved.data == originalData, fstat(output, &outputStatus) == 0,
                source.withCString({
                    fstatat(quarantine.descriptor, $0, &sourceStatus, AT_SYMLINK_NOFOLLOW)
                }) == 0,
                NodeState(outputStatus) == NodeState(sourceStatus)
            else {
                throw SwiftPodsError(
                    "Quarantined Package.resolved recovery source does not match its open descriptor; evidence remains at \(quarantine.name)",
                    file: file.path)
            }
            guard source.withCString({ from in
                evidence.withCString { linkat(quarantine.descriptor, from, quarantine.descriptor, $0, 0) }
            }) == 0 else {
                throw SwiftPodsError(
                    "Cannot retain Package.resolved recovery evidence at \(quarantine.name)", file: file.path)
            }
            guard futimens(output, &restoredTimes) == 0, fsync(output) == 0 else {
                throw SwiftPodsError(
                    "Cannot finalize quarantined Package.resolved recovery source", file: file.path)
            }
            beforeMissingSourceRenameForTesting?()
            let immediatelyBeforeRename = try readFinalEntry(
                named: source, in: quarantine.descriptor, allowsMissing: false, file: file)
            var outputBeforeRename = stat()
            var linkedBeforeRename = stat()
            guard let sourceEntry = immediatelyBeforeRename.entry,
                immediatelyBeforeRename.metadata == originalMetadata,
                immediatelyBeforeRename.data == originalData,
                sourceEntry.hasRestoredMetadata(of: originalEntry),
                fstat(output, &outputBeforeRename) == 0,
                source.withCString({
                    fstatat(quarantine.descriptor, $0, &linkedBeforeRename, AT_SYMLINK_NOFOLLOW)
                }) == 0,
                NodeState(outputBeforeRename) == NodeState(linkedBeforeRename)
            else {
                throw SwiftPodsError(
                    "Package.resolved recovery source changed before installation; evidence remains at \(quarantine.name)",
                    file: file.path)
            }
            guard source.withCString({ value in
                "Package.resolved".withCString {
                    renameatx_np(quarantine.descriptor, value, parent, $0, UInt32(RENAME_EXCL))
                }
            }) == 0 else {
                throw SwiftPodsError(
                    "Package.resolved changed again; recovery evidence remains at \(quarantine.name)", file: file.path)
            }
            guard futimens(output, &restoredTimes) == 0, fsync(output) == 0 else {
                throw SwiftPodsError(
                    "Cannot finalize restored Package.resolved timestamps; evidence remains at \(quarantine.name)",
                    file: file.path)
            }
            let installed = try readFinalEntry(in: parent, allowsMissing: false, file: file)
            var installedDescriptorStatus = stat()
            var installedLinkedStatus = stat()
            guard let installedEntry = installed.entry,
                installedEntry.hasRestoredMetadata(of: originalEntry),
                installed.metadata == originalMetadata, installed.data == originalData,
                fstat(output, &installedDescriptorStatus) == 0,
                "Package.resolved".withCString({
                    fstatat(parent, $0, &installedLinkedStatus, AT_SYMLINK_NOFOLLOW)
                }) == 0,
                NodeState(installedDescriptorStatus) == NodeState(installedLinkedStatus)
            else {
                throw SwiftPodsError(
                    "Installed Package.resolved does not match its recovery descriptor; evidence remains at \(quarantine.name)",
                    file: file.path)
            }
            beforeCleanupForTesting?()
            let evidenceToken = try readFinalEntry(
                named: evidence, in: quarantine.descriptor, allowsMissing: false, file: file)
            let evidenceImmediatelyBeforeUnlink = try readFinalEntry(
                named: evidence, in: quarantine.descriptor, allowsMissing: false, file: file)
            guard let evidenceEntry = evidenceToken.entry,
                evidenceEntry.isSameObject(as: installedEntry),
                evidenceEntry.flags == installedEntry.flags, evidenceEntry.size == installedEntry.size,
                evidenceEntry.modifiedSeconds == installedEntry.modifiedSeconds,
                evidenceEntry.modifiedNanoseconds == installedEntry.modifiedNanoseconds,
                evidenceImmediatelyBeforeUnlink.entry == evidenceToken.entry,
                evidenceImmediatelyBeforeUnlink.metadata == evidenceToken.metadata,
                evidenceImmediatelyBeforeUnlink.data == evidenceToken.data,
                evidenceToken.metadata == originalMetadata, evidenceToken.data == originalData
            else {
                throw SwiftPodsError(
                    "Package.resolved recovery evidence changed before cleanup; it remains at \(quarantine.name)",
                    file: file.path)
            }
            // POSIX has no compare-and-unlink primitive. The final check and unlink are descriptor-relative inside a
            // random 0700 directory, which is the strongest practical defense against a same-UID hostile writer.
            guard evidence.withCString({ unlinkat(quarantine.descriptor, $0, 0) }) == 0 else {
                throw SwiftPodsError(
                    "Cannot remove verified Package.resolved recovery evidence at \(quarantine.name)", file: file.path)
            }
            guard futimens(output, &restoredTimes) == 0, fsync(output) == 0 else {
                throw SwiftPodsError("Cannot finalize restored Package.resolved timestamps", file: file.path)
            }
            var finalDescriptorStatus = stat()
            var finalLinkedStatus = stat()
            guard fstat(output, &finalDescriptorStatus) == 0,
                "Package.resolved".withCString({
                    fstatat(parent, $0, &finalLinkedStatus, AT_SYMLINK_NOFOLLOW)
                }) == 0,
                NodeState(finalDescriptorStatus) == NodeState(finalLinkedStatus),
                NodeState(finalDescriptorStatus).hasRestoredMetadata(of: originalEntry)
            else {
                throw SwiftPodsError(
                    "Restored Package.resolved changed during evidence cleanup", file: file.path)
            }
            try quarantine.finish()
        } else {
            guard temporary.withCString({ source in
                "Package.resolved".withCString {
                    renameatx_np(parent, source, parent, $0, UInt32(RENAME_SWAP))
                }
            }) == 0 else {
                throw SwiftPodsError("Cannot atomically restore Package.resolved", file: file.path)
            }
            // Once the swap has published the recovery file, preserve its random name on every exceptional path.
            // Only the fully verified success path below is allowed to unlink it.
            temporaryExists = false
            afterSwapForTesting?()
            let displaced = try readFinalEntry(named: temporary, in: parent, allowsMissing: false, file: file)
            let installed = try readFinalEntry(in: parent, allowsMissing: false, file: file)
            guard let displacedEntry = displaced.entry, let expectedEntry = expected.entry,
                displacedEntry.representsAfterRename(expectedEntry), displaced.metadata == expected.metadata,
                displaced.data == expected.data,
                let installedEntry = installed.entry,
                installedEntry.hasRestoredMetadata(of: originalEntry),
                installed.metadata == original.metadata, installed.data == originalData
            else {
                // From this point on, never let the defer unlink the random recovery name. Before reversing the swap,
                // prove that both names still denote the exact entries just inspected. A writer may replace either
                // name after the failed guard; blindly swapping and then unlinking would delete that concurrent file.
                temporaryExists = false
                beforeReverseSwapForTesting?()
                let displacedBeforeReverse = try readFinalEntry(
                    named: temporary, in: parent, allowsMissing: false, file: file)
                let installedBeforeReverse = try readFinalEntry(
                    in: parent, allowsMissing: false, file: file)
                guard displacedBeforeReverse.entry == displaced.entry,
                    displacedBeforeReverse.metadata == displaced.metadata,
                    displacedBeforeReverse.data == displaced.data,
                    installedBeforeReverse.entry == installed.entry,
                    installedBeforeReverse.metadata == installed.metadata,
                    installedBeforeReverse.data == installed.data
                else {
                    throw SwiftPodsError(
                        "Package.resolved changed before rollback reversal; recovery evidence remains at \(temporary)",
                        file: file.path)
                }
                guard temporary.withCString({ source in
                    "Package.resolved".withCString {
                        renameatx_np(parent, source, parent, $0, UInt32(RENAME_SWAP))
                    }
                }) == 0 else {
                    throw SwiftPodsError(
                        "Cannot reverse the Package.resolved rollback; recovery evidence remains at \(temporary)",
                        file: file.path)
                }
                let restoredExpected = try readFinalEntry(in: parent, allowsMissing: false, file: file)
                let preservedRecovery = try readFinalEntry(
                    named: temporary, in: parent, allowsMissing: false, file: file)
                guard let restoredEntry = restoredExpected.entry, let displacedEntry = displaced.entry,
                    restoredEntry.representsAfterRename(displacedEntry),
                    restoredExpected.metadata == displaced.metadata, restoredExpected.data == displaced.data,
                    let recoveryEntry = preservedRecovery.entry, let installedEntry = installed.entry,
                    recoveryEntry.representsAfterRename(installedEntry),
                    preservedRecovery.metadata == installed.metadata, preservedRecovery.data == installed.data
                else {
                    throw SwiftPodsError(
                        "Package.resolved changed during rollback reversal; recovery evidence remains at \(temporary)",
                        file: file.path)
                }
                throw SwiftPodsError(
                    "Package.resolved changed during restoration; recovery evidence remains at \(temporary)",
                    file: file.path)
            }
            // Reading the installed file for post-swap verification may advance atime. Reapply the original times
            // through the still-open recovery descriptor, then verify that the pathname still denotes that inode.
            guard futimens(output, &restoredTimes) == 0, fsync(output) == 0 else {
                throw SwiftPodsError(
                    "Cannot finalize restored Package.resolved timestamps; recovery evidence remains at \(temporary)",
                    file: file.path)
            }
            var restoredDescriptorStatus = stat()
            var restoredLinkedStatus = stat()
            guard fstat(output, &restoredDescriptorStatus) == 0,
                "Package.resolved".withCString({
                    fstatat(parent, $0, &restoredLinkedStatus, AT_SYMLINK_NOFOLLOW)
                }) == 0,
                NodeState(restoredDescriptorStatus) == NodeState(restoredLinkedStatus),
                NodeState(restoredDescriptorStatus).hasRestoredMetadata(of: originalEntry)
            else {
                throw SwiftPodsError(
                    "Restored Package.resolved changed before timestamp finalization; recovery evidence remains at \(temporary)",
                    file: file.path)
            }
            try quarantineAndRemoveRecovery(
                named: temporary, in: parent, expected: displaced, file: file,
                beforeMoveForTesting: beforeCleanupForTesting)
        }
        guard fsync(parent) == 0 else {
            throw SwiftPodsError("Restored Package.resolved but could not synchronize its directory", file: file.path)
        }
    }

    private static func isConsistentPathSnapshot(_ snapshot: PathSnapshot) -> Bool {
        let completeCount = resolvedDirectoryComponents.count + 1
        guard (1...completeCount).contains(snapshot.directories.count) else { return false }
        if snapshot.directories.count < completeCount {
            return snapshot.entry == nil && snapshot.metadata == nil && snapshot.data == nil
        }
        let present = snapshot.entry != nil && snapshot.metadata != nil && snapshot.data != nil
        let absent = snapshot.entry == nil && snapshot.metadata == nil && snapshot.data == nil
        return present || absent
    }

    private static func quarantineAndRemoveRecovery(
        named name: String, in parent: Int32,
        expected: (entry: NodeState?, metadata: FileSecurityMetadata?, data: Data?),
        file: URL, beforeMoveForTesting: (() -> Void)?
    ) throws {
        beforeMoveForTesting?()
        let quarantine = try RollbackQuarantine(parent: parent, prefix: "package-resolved-cleanup")
        let item = "displaced"
        guard name.withCString({ source in
            item.withCString {
                renameatx_np(parent, source, quarantine.descriptor, $0, UInt32(RENAME_EXCL))
            }
        }) == 0 else {
            throw SwiftPodsError("Cannot quarantine displaced Package.resolved", file: file.path)
        }
        quarantine.preserveEvidence()
        let moved = try readFinalEntry(
            named: item, in: quarantine.descriptor, allowsMissing: false, file: file)
        guard let movedEntry = moved.entry, let expectedEntry = expected.entry,
            movedEntry.representsAfterRename(expectedEntry), moved.metadata == expected.metadata,
            moved.data == expected.data
        else {
            throw SwiftPodsError(
                "Displaced Package.resolved changed before cleanup; evidence remains at \(quarantine.name)",
                file: file.path)
        }
        let immediatelyBeforeUnlink = try readFinalEntry(
            named: item, in: quarantine.descriptor, allowsMissing: false, file: file)
        guard immediatelyBeforeUnlink.entry == moved.entry,
            immediatelyBeforeUnlink.metadata == moved.metadata, immediatelyBeforeUnlink.data == moved.data
        else {
            throw SwiftPodsError(
                "Displaced Package.resolved changed inside cleanup quarantine; evidence remains at \(quarantine.name)",
                file: file.path)
        }
        // POSIX has no compare-and-unlink primitive. Keep this final check adjacent to a descriptor-relative unlink
        // inside the random 0700 quarantine; any observed mismatch is preserved rather than deleted.
        guard item.withCString({ unlinkat(quarantine.descriptor, $0, 0) }) == 0 else {
            throw SwiftPodsError(
                "Cannot remove verified displaced Package.resolved at \(quarantine.name)", file: file.path)
        }
        try quarantine.finish()
    }

    /// Removes only the directory suffix absent from the original snapshot. Every removal is descriptor-anchored and
    /// fails closed if the resolver (or another process) left any additional entry behind.
    private static func removeCreatedDirectories(
        after originalCount: Int, descriptors: [Int32], expected: [NodeState], file: URL
    ) throws {
        guard descriptors.count == expected.count, expected.count > originalCount else { return }
        for index in stride(from: expected.count - 1, through: originalCount, by: -1) {
            let child = descriptors[index]
            let parent = descriptors[index - 1]
            let component = resolvedDirectoryComponents[index - 1]
            var opened = stat()
            var linked = stat()
            guard fstat(child, &opened) == 0,
                NodeState(opened).isSameDirectoryObject(as: expected[index]),
                component.withCString({ fstatat(parent, $0, &linked, AT_SYMLINK_NOFOLLOW) }) == 0,
                NodeState(linked).isSameDirectoryObject(as: NodeState(opened))
            else {
                throw SwiftPodsError(
                    "A resolver-created Package.resolved directory changed; refusing removal", file: file.path)
            }
            try quarantineAndRemoveCreatedDirectory(
                named: component, in: parent, opened: child, expected: expected[index], file: file)
            guard fsync(parent) == 0 else {
                throw SwiftPodsError("Cannot synchronize Package.resolved directory rollback", file: file.path)
            }
        }
    }

    private static func quarantineAndRemoveCreatedDirectory(
        named name: String, in parent: Int32, opened descriptor: Int32, expected: NodeState, file: URL
    ) throws {
        let quarantine = try RollbackQuarantine(parent: parent, prefix: "package-resolved-directory")
        let item = "directory"
        guard name.withCString({ source in
            item.withCString {
                renameatx_np(parent, source, quarantine.descriptor, $0, UInt32(RENAME_EXCL))
            }
        }) == 0 else {
            throw SwiftPodsError("Cannot quarantine a resolver-created Package.resolved directory", file: file.path)
        }
        quarantine.preserveEvidence()
        var opened = stat()
        var moved = stat()
        guard fstat(descriptor, &opened) == 0,
            NodeState(opened).isSameDirectoryObject(as: expected),
            item.withCString({ fstatat(quarantine.descriptor, $0, &moved, AT_SYMLINK_NOFOLLOW) }) == 0,
            NodeState(moved).isSameDirectoryObject(as: NodeState(opened))
        else {
            throw SwiftPodsError(
                "A resolver-created Package.resolved directory changed during cleanup; evidence remains at \(quarantine.name)",
                file: file.path)
        }
        if name == "swiftpm" { try removeEmptyResolverConfiguration(in: descriptor, file: file) }
        guard item.withCString({ unlinkat(quarantine.descriptor, $0, AT_REMOVEDIR) }) == 0 else {
            throw SwiftPodsError(
                "A resolver-created Package.resolved directory is no longer empty; evidence remains at \(quarantine.name)",
                file: file.path)
        }
        try quarantine.finish()
    }

    /// Xcode creates this empty directory alongside Package.resolved. Remove it only inside a resolver-created
    /// swiftpm directory. Pre-existing swiftpm directories, configuration files and symlinks are left alone.
    private static func removeEmptyResolverConfiguration(in parent: Int32, file: URL) throws {
        let name = "configuration"
        var linked = stat()
        let result = name.withCString { fstatat(parent, $0, &linked, AT_SYMLINK_NOFOLLOW) }
        if result != 0 && errno == ENOENT { return }
        guard result == 0, linked.st_mode & S_IFMT == S_IFDIR else {
            throw SwiftPodsError("Resolver configuration is not a real directory; evidence was preserved", file: file.path)
        }
        let expected = NodeState(linked)
        let descriptor = try openRecoveryDirectory(named: name, in: parent, expected: expected, file: file)
        defer { close(descriptor) }
        guard try directoryIsEmpty(descriptor) else {
            throw SwiftPodsError("Resolver configuration is not empty; evidence was preserved", file: file.path)
        }
        try quarantineAndRemoveCreatedDirectory(
            named: name, in: parent, opened: descriptor, expected: expected, file: file)
        guard fsync(parent) == 0 else {
            throw SwiftPodsError("Cannot synchronize resolver configuration rollback", file: file.path)
        }
    }

    /// Problems that make the pins unusable for a deployment install.
    func problems(for packages: [Package]) -> [String] {
        var pinsByOrigin: [String: Pin] = [:]
        var duplicateOrigins: Set<String> = []
        for pin in pins where PackageLocation.isSafeRemote(pin.location) {
            let origin = PackageLocation.fetchIdentity(pin.location)
            if pinsByOrigin.updateValue(pin, forKey: origin) != nil { duplicateOrigins.insert(origin) }
        }
        var result: [String] = []
        for package in packages {
            guard case .remote(let url) = package.location, let requirement = package.requirement else { continue }
            let origin = PackageLocation.fetchIdentity(url)
            if duplicateOrigins.contains(origin) {
                result.append("\(package.name) has duplicate pins for \(url)")
                continue
            }
            guard let pin = pinsByOrigin[origin] else {
                result.append("\(package.name) (\(url)) has no pin")
                continue
            }
            guard let pinnedRevision = pin.revision, Self.isFullObjectID(pinnedRevision) else {
                result.append("\(package.name) does not record a full lowercase commit revision in Package.resolved")
                continue
            }
            switch requirement {
            case .branch(let branch):
                if pin.branch != branch { result.append("\(package.name) is pinned to \(pin.branch.map { "branch " + $0 } ?? "a version"), the Podfile requires branch \(branch)") }
            case .revision(let revision):
                if pinnedRevision != revision {
                    result.append("\(package.name) is pinned to revision \(pinnedRevision), the Podfile requires \(revision)")
                }
            default:
                guard let version = pin.version else {
                    result.append("\(package.name) is pinned to \(pin.branch.map { "branch " + $0 } ?? "a revision"), the Podfile requires \(requirement)")
                    continue
                }
                if !requirement.allows(version) {
                    result.append("\(package.name) is pinned to \(version), the Podfile requires \(requirement)")
                }
            }
        }
        return result
    }

    private static func isFullObjectID(_ text: String) -> Bool {
        (text.count == 40 || text.count == 64)
            && text.allSatisfy { $0.isASCII && ($0.isNumber || "abcdef".contains($0)) }
    }

    private static func parse(_ root: [String: Any], file: String) throws -> [Pin] {
        guard let number = root["version"] as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID(),
            ["i", "l", "q", "I", "L", "Q"].contains(String(cString: number.objCType))
        else {
            throw malformed("has no integer schema version", file: file)
        }
        let schema = number.intValue
        let entries: [Any]
        let locationKey: String
        switch schema {
        case 1:
            guard Set(root.keys) == ["object", "version"],
                let object = root["object"] as? [String: Any], Set(object.keys) == ["pins"],
                let values = object["pins"] as? [Any]
            else {
                throw malformed("version 1 must contain only object.pins", file: file)
            }
            entries = values
            locationKey = "repositoryURL"
        case 2:
            guard Set(root.keys) == ["pins", "version"], let values = root["pins"] as? [Any] else {
                throw malformed("version \(schema) must contain only top-level pins", file: file)
            }
            entries = values
            locationKey = "location"
        case 3:
            let keys = Set(root.keys)
            guard keys.isSuperset(of: ["pins", "version"]),
                keys.isSubset(of: ["originHash", "pins", "version"]),
                let values = root["pins"] as? [Any]
            else {
                throw malformed("version 3 must contain top-level pins and an optional originHash", file: file)
            }
            if let value = root["originHash"] {
                guard let originHash = value as? String, originHash.count == 64, isFullObjectID(originHash) else {
                    throw malformed("version 3 has an invalid originHash", file: file)
                }
            }
            entries = values
            locationKey = "location"
        default:
            throw SwiftPodsError("Package.resolved has unsupported schema version \(schema)", file: file)
        }

        var result: [Pin] = []
        var origins: Set<String> = []
        var registryIdentities: Set<String> = []
        for (index, value) in entries.enumerated() {
            guard let entry = value as? [String: Any] else {
                throw malformed("pin \(index + 1) is not an object", file: file)
            }
            let kind: String
            let recordedIdentity: String
            if schema == 1 {
                guard Set(entry.keys) == ["package", "repositoryURL", "state"],
                    let package = entry["package"] as? String, isSafeScalar(package)
                else {
                    throw malformed("version 1 pin \(index + 1) has unexpected or missing fields", file: file)
                }
                kind = "remoteSourceControl"
                recordedIdentity = package.precomposedStringWithCanonicalMapping.lowercased()
            } else {
                guard Set(entry.keys) == ["identity", "kind", "location", "state"],
                    let valueKind = entry["kind"] as? String, isSafeScalar(valueKind),
                    let identity = entry["identity"] as? String, isSafeScalar(identity)
                else {
                    throw malformed("pin \(index + 1) has unexpected or missing fields", file: file)
                }
                kind = valueKind
                recordedIdentity = identity
            }
            guard let location = entry[locationKey] as? String, isSafeScalar(location),
                let state = entry["state"] as? [String: Any],
                Set(state.keys).isSubset(of: ["branch", "revision", "version"])
            else {
                throw malformed("pin \(index + 1) has an invalid location or state", file: file)
            }
            let branch = try optionalString("branch", in: state, pin: index, file: file)
            let revision = try optionalString("revision", in: state, pin: index, file: file)
            let versionText = try optionalString("version", in: state, pin: index, file: file)
            guard branch == nil || isSafeGitBranch(branch!) else {
                throw malformed("pin \(index + 1) has an invalid Git branch", file: file)
            }

            switch kind {
            case "remoteSourceControl":
                guard PackageLocation.isSafeRemote(location) else {
                    throw malformed("pin \(index + 1) has an unsafe repository location", file: file)
                }
                guard recordedIdentity == PackageLocation.identity(location) else {
                    throw malformed("pin \(index + 1) identity does not match its location", file: file)
                }
                let origin = PackageLocation.fetchIdentity(location)
                guard origins.insert(origin).inserted else {
                    throw malformed("contains duplicate pins for \(location)", file: file)
                }
                guard let revision, isFullObjectID(revision) else {
                    throw malformed("pin \(index + 1) has no full lowercase commit revision", file: file)
                }
                guard branch == nil || versionText == nil else {
                    throw malformed("pin \(index + 1) records both a branch and a version", file: file)
                }
                let version: Version?
                if let versionText {
                    guard let parsed = Version(versionText) else {
                        throw malformed("pin \(index + 1) has an invalid semantic version", file: file)
                    }
                    version = parsed
                } else {
                    version = nil
                }
                result.append(Pin(location: location, version: version, branch: branch, revision: revision))
            case "registry":
                let canonical = location.precomposedStringWithCanonicalMapping.lowercased()
                guard schema != 1, isRegistryIdentity(location), recordedIdentity == canonical else {
                    throw malformed("registry pin \(index + 1) identity does not match its location", file: file)
                }
                guard registryIdentities.insert(canonical).inserted else {
                    throw malformed("contains duplicate registry pins for \(location)", file: file)
                }
                guard branch == nil, revision == nil, let versionText, Version(versionText) != nil else {
                    throw malformed("registry pin \(index + 1) has an invalid state", file: file)
                }
                // Registry pins can be transitive, but SwiftPods only compares Podfile Git packages.
            default:
                throw malformed("pin \(index + 1) has unsupported kind `\(kind)`", file: file)
            }
        }
        return result
    }

    private static func optionalString(
        _ key: String, in object: [String: Any], pin index: Int, file: String
    ) throws -> String? {
        guard let value = object[key] else { return nil }
        if value is NSNull { return nil }
        guard let text = value as? String else {
            throw malformed("pin \(index + 1) has a non-string \(key)", file: file)
        }
        return text
    }

    private static func malformed(_ detail: String, file: String) -> SwiftPodsError {
        SwiftPodsError("Package.resolved \(detail)", file: file, hint: "Regenerate it with `swiftpods install --resolve`")
    }

    private static func isSafeScalar(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.count <= 4_096
            && !text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    private static func isSafeGitBranch(_ text: String) -> Bool {
        guard isSafeScalar(text), text.utf8.count <= 1_024, text != "@", !text.hasPrefix("-"),
            !text.hasPrefix("/"), !text.hasSuffix("/"), !text.hasSuffix("."),
            !text.contains("//"), !text.contains(".."), !text.contains("@{")
        else { return false }
        let forbidden = CharacterSet(charactersIn: " ~^:?*[\\")
        guard !text.unicodeScalars.contains(where: forbidden.contains) else { return false }
        return text.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && !$0.hasPrefix(".") && !$0.hasSuffix(".lock")
        }
    }

    private static func isRegistryIdentity(_ text: String) -> Bool {
        let components = text.split(separator: ".", omittingEmptySubsequences: false)
        return components.count == 2 && components.allSatisfy { component in
            !component.isEmpty && component.unicodeScalars.allSatisfy {
                $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "-_".unicodeScalars.contains($0))
            }
        }
    }

    private static func readBoundedRegularFile(_ file: URL) throws -> Data {
        // O_NONBLOCK prevents a malicious FIFO/device at this path from hanging before fstat rejects it.
        let descriptor = file.path.withCString { open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK) }
        guard descriptor >= 0 else {
            if errno == ELOOP { throw ReadError.notRegular }
            throw CocoaError(.fileReadNoSuchFile)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw CocoaError(.fileReadUnknown) }
        guard status.st_mode & S_IFMT == S_IFREG else { throw ReadError.notRegular }
        guard status.st_size >= 0, status.st_size <= maximumBytes else { throw ReadError.tooLarge }
        var data = Data()
        while let chunk = try handle.read(upToCount: min(1 << 20, maximumBytes + 1 - data.count)), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= maximumBytes else { throw ReadError.tooLarge }
        }
        var finalStatus = stat()
        guard fstat(descriptor, &finalStatus) == 0 else { throw CocoaError(.fileReadUnknown) }
        guard finalStatus.st_dev == status.st_dev, finalStatus.st_ino == status.st_ino,
            finalStatus.st_size == status.st_size,
            finalStatus.st_mtimespec.tv_sec == status.st_mtimespec.tv_sec,
            finalStatus.st_mtimespec.tv_nsec == status.st_mtimespec.tv_nsec,
            finalStatus.st_ctimespec.tv_sec == status.st_ctimespec.tv_sec,
            finalStatus.st_ctimespec.tv_nsec == status.st_ctimespec.tv_nsec,
            data.count == Int(status.st_size)
        else {
            throw ReadError.changed
        }
        return data
    }

    private static func pathSnapshot(
        project: URL, projectDescriptor retainedProjectDescriptor: Int32?,
        allowsMissingFile: Bool, allowsMissingDirectories: Bool = false
    ) throws -> PathSnapshot {
        let file = location(project: project)
        let projectDescriptor = try openProjectDirectory(
            project: project, retainedDescriptor: retainedProjectDescriptor,
            operation: "snapshotting Package.resolved")
        var descriptors = [projectDescriptor]
        defer { for descriptor in descriptors.reversed() { close(descriptor) } }
        var directoryStates: [NodeState] = []
        var projectStatus = stat()
        guard fstat(projectDescriptor, &projectStatus) == 0, projectStatus.st_mode & S_IFMT == S_IFDIR else {
            throw SwiftPodsError("Xcode project must be a real directory", file: project.path)
        }
        directoryStates.append(NodeState(projectStatus))
        var firstMissingComponent: String?
        for component in resolvedDirectoryComponents {
            let parent = descriptors.last!
            var linked = stat()
            let found = component.withCString { fstatat(parent, $0, &linked, AT_SYMLINK_NOFOLLOW) }
            if found != 0, errno == ENOENT, allowsMissingDirectories {
                firstMissingComponent = component
                break
            }
            guard found == 0, linked.st_mode & S_IFMT == S_IFDIR else {
                throw SwiftPodsError("Package.resolved parent must be a real directory", file: file.path)
            }
            let descriptor = component.withCString {
                openat(parent, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            }
            guard descriptor >= 0 else {
                throw SwiftPodsError("Cannot safely open the Package.resolved parent", file: file.path)
            }
            var opened = stat()
            guard fstat(descriptor, &opened) == 0, NodeState(opened) == NodeState(linked) else {
                close(descriptor)
                throw SwiftPodsError("Package.resolved parent changed while it was opened", file: file.path)
            }
            descriptors.append(descriptor)
            directoryStates.append(NodeState(opened))
        }
        let final: (entry: NodeState?, metadata: FileSecurityMetadata?, data: Data?)
        if firstMissingComponent == nil {
            final = try readFinalEntry(in: descriptors.last!, allowsMissing: allowsMissingFile, file: file)
        } else {
            final = (nil, nil, nil)
        }

        // Revalidate the complete chain while every descriptor is retained, then re-anchor the project pathname.
        for index in descriptors.indices {
            var status = stat()
            guard fstat(descriptors[index], &status) == 0, NodeState(status) == directoryStates[index] else {
                throw SwiftPodsError("Package.resolved path changed while it was read", file: file.path)
            }
            if index > 0 {
                var linked = stat()
                let name = resolvedDirectoryComponents[index - 1]
                guard name.withCString({ fstatat(descriptors[index - 1], $0, &linked, AT_SYMLINK_NOFOLLOW) }) == 0,
                    NodeState(linked) == directoryStates[index]
                else { throw SwiftPodsError("Package.resolved path changed while it was read", file: file.path) }
            }
        }
        if let firstMissingComponent {
            var linked = stat()
            let stillMissing = firstMissingComponent.withCString {
                fstatat(descriptors.last!, $0, &linked, AT_SYMLINK_NOFOLLOW)
            }
            guard stillMissing != 0, errno == ENOENT else {
                throw SwiftPodsError("Package.resolved path changed while it was read", file: file.path)
            }
        }
        if retainedProjectDescriptor == nil {
            let reopened = project.path.withCString {
                open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            }
            guard reopened >= 0 else {
                throw SwiftPodsError("Xcode project moved while Package.resolved was read", file: file.path)
            }
            defer { close(reopened) }
            var reopenedStatus = stat()
            guard fstat(reopened, &reopenedStatus) == 0, NodeState(reopenedStatus) == directoryStates[0] else {
                throw SwiftPodsError("Xcode project moved while Package.resolved was read", file: file.path)
            }
        }
        return PathSnapshot(
            directories: directoryStates, entry: final.entry, metadata: final.metadata, data: final.data)
    }

    /// Opens a fresh descriptor for either the caller's retained project capability or, for legacy/test callers, the
    /// public project pathname. Every descriptor-relative Package.resolved operation funnels through this helper.
    private static func openProjectDirectory(
        project: URL, retainedDescriptor: Int32?, operation: String
    ) throws -> Int32 {
        let descriptor: Int32
        if let retainedDescriptor {
            descriptor = duplicateCloseOnExec(retainedDescriptor, minimum: STDERR_FILENO + 1)
        } else {
            descriptor = project.path.withCString {
                open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            }
        }
        guard descriptor >= 0 else {
            throw SwiftPodsError("Cannot safely open the Xcode project while \(operation)", file: project.path)
        }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFDIR else {
            close(descriptor)
            throw SwiftPodsError("The retained Xcode project is not a directory while \(operation)", file: project.path)
        }
        return descriptor
    }

    /// Returns a descriptor for the fixed `swiftpm` parent authenticated by `snapshot`. The install journal uses it
    /// to copy the exact Package.resolved inode without reopening any public pathname.
    static func duplicateResolvedParent(
        project: URL, projectDescriptor retainedProjectDescriptor: Int32?, matching snapshot: PathSnapshot
    ) throws -> Int32 {
        let file = location(project: project)
        guard snapshot.directories.count == resolvedDirectoryComponents.count + 1 else {
            throw SwiftPodsError("Package.resolved has no complete authenticated parent path", file: file.path)
        }
        let root = try openProjectDirectory(
            project: project, retainedDescriptor: retainedProjectDescriptor,
            operation: "opening the Package.resolved journal source")
        var descriptors = [root]
        defer { for descriptor in descriptors.reversed() { close(descriptor) } }
        var rootStatus = stat()
        guard fstat(root, &rootStatus) == 0, NodeState(rootStatus) == snapshot.directories[0] else {
            throw SwiftPodsError("Xcode project changed before Package.resolved journaling", file: file.path)
        }
        for index in 1..<snapshot.directories.count {
            let name = resolvedDirectoryComponents[index - 1]
            let parent = descriptors.last!
            let child = name.withCString {
                openat(parent, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            }
            guard child >= 0 else {
                throw SwiftPodsError("Cannot safely open the Package.resolved journal source", file: file.path)
            }
            var opened = stat()
            var linked = stat()
            guard fstat(child, &opened) == 0, NodeState(opened) == snapshot.directories[index],
                name.withCString({ fstatat(parent, $0, &linked, AT_SYMLINK_NOFOLLOW) }) == 0,
                NodeState(linked) == NodeState(opened)
            else {
                close(child)
                throw SwiftPodsError("Package.resolved path changed before journaling", file: file.path)
            }
            descriptors.append(child)
        }
        let result = duplicateCloseOnExec(descriptors.last!, minimum: STDERR_FILENO + 1)
        guard result >= 0 else {
            throw SwiftPodsError("Cannot retain the Package.resolved journal source", file: file.path)
        }
        return result
    }

    private static func readFinalEntry(
        named name: String = "Package.resolved", in parent: Int32, allowsMissing: Bool, file: URL
    ) throws -> (entry: NodeState?, metadata: FileSecurityMetadata?, data: Data?) {
        let descriptor = name.withCString {
            openat(parent, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        if descriptor < 0 {
            if errno == ENOENT, allowsMissing {
                var status = stat()
                guard name.withCString({ fstatat(parent, $0, &status, AT_SYMLINK_NOFOLLOW) }) != 0, errno == ENOENT else {
                    throw SwiftPodsError("Package.resolved changed while it was inspected", file: file.path)
                }
                return (nil, nil, nil)
            }
            if errno == ELOOP { throw SwiftPodsError("Package.resolved must be a regular file", file: file.path) }
            throw SwiftPodsError("Cannot read Package.resolved", file: file.path)
        }
        defer { close(descriptor) }
        var initial = stat()
        guard fstat(descriptor, &initial) == 0, initial.st_mode & S_IFMT == S_IFREG else {
            throw SwiftPodsError("Package.resolved must be a regular file", file: file.path)
        }
        guard initial.st_size >= 0, initial.st_size <= maximumBytes else {
            throw SwiftPodsError("Package.resolved exceeds the 16 MiB limit", file: file.path)
        }
        let duplicate = duplicateCloseOnExec(descriptor)
        guard duplicate >= 0 else {
            throw SwiftPodsError("Cannot duplicate the Package.resolved descriptor", file: file.path)
        }
        let handle = FileHandle(fileDescriptor: duplicate, closeOnDealloc: true)
        defer { try? handle.close() }
        var data = Data()
        while let chunk = try handle.read(upToCount: min(1 << 20, maximumBytes + 1 - data.count)), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= maximumBytes else {
                throw SwiftPodsError("Package.resolved exceeds the 16 MiB limit", file: file.path)
            }
        }
        let metadata: FileSecurityMetadata
        do { metadata = try FileSecurityMetadata(descriptor: descriptor) } catch {
            throw SwiftPodsError("Cannot snapshot Package.resolved ACLs or extended attributes", file: file.path)
        }
        var final = stat()
        var linked = stat()
        guard fstat(descriptor, &final) == 0, NodeState(final) == NodeState(initial),
            Int64(data.count) == initial.st_size,
            name.withCString({ fstatat(parent, $0, &linked, AT_SYMLINK_NOFOLLOW) }) == 0,
            NodeState(linked) == NodeState(final)
        else { throw SwiftPodsError("Package.resolved changed while it was read", file: file.path) }
        return (NodeState(initial), metadata, data)
    }

    private static func write(_ data: Data, to descriptor: Int32, file: URL) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw SwiftPodsError("Cannot write the Package.resolved recovery file", file: file.path)
                }
                offset += count
            }
        }
    }
}
