import CryptoKit
import Darwin
import Foundation
import SwiftPodsSecurity

/// A `.xcodeproj` bundle's `project.pbxproj`, edited as typed values and written with minimal diffs.
public struct XcodeProject: Sendable {
    private static let maximumProjectBytes = 32 * 1_024 * 1_024

    private struct FileSnapshot: Sendable, Equatable {
        let device: UInt64
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64
        let mode: UInt32
        let owner: UInt32
        let group: UInt32
        let flags: UInt32
        let linkCount: UInt64
        let digest: String
    }

    private struct DirectoryIdentity: Sendable, Equatable {
        let device: UInt64
        let inode: UInt64
    }

    /// Retains both the project directory itself and the route by which the caller authenticated it. Descriptor-
    /// relative consumers can therefore keep using the original directory even while a non-cooperating writer
    /// temporarily rebinds its pathname, while `openVerified` proves that pathname still names that same object at
    /// boundaries where a path must be handed to another API.
    private final class DirectoryAnchor: @unchecked Sendable {
        private let root: Int32?
        private let components: [String]
        private let absolutePath: URL?
        private let projectDescriptor: Int32
        private let projectIdentity: DirectoryIdentity

        init(rootDescriptor: Int32, relativePath: String, file: String) throws(XcodeError) {
            guard !relativePath.hasPrefix("/"), !relativePath.isEmpty,
                !relativePath.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                !relativePath.contains("\\")
            else { throw XcodeError("The anchored Xcode project path is not a safe relative path", file: file) }
            let components = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
                throw XcodeError("The anchored Xcode project path contains an ambiguous component", file: file)
            }
            let root = fcntl(rootDescriptor, F_DUPFD_CLOEXEC, STDERR_FILENO + 1)
            guard root >= 0 else {
                throw XcodeError("Cannot retain the authenticated project root", file: file)
            }
            self.root = root
            self.components = components
            absolutePath = nil
            var retained: Int32 = -1
            do {
                retained = try Self.open(root: root, components: components, file: file)
                let identity = try XcodeProject.directoryIdentity(retained, file: file)
                projectDescriptor = retained
                projectIdentity = identity
            } catch {
                if retained >= 0 { close(retained) }
                close(root)
                throw error
            }
        }

        init(path: URL, file: String) throws(XcodeError) {
            root = nil
            components = []
            absolutePath = path
            let directory = try XcodeProject.openProjectDirectory(path)
            projectDescriptor = directory
            do {
                projectIdentity = try XcodeProject.directoryIdentity(directory, file: file)
            } catch {
                close(directory)
                throw error
            }
        }

        deinit {
            close(projectDescriptor)
            if let root { close(root) }
        }

        /// Duplicates the originally authenticated project directory without consulting its mutable pathname.
        func duplicateRetained(file: String) throws(XcodeError) -> Int32 {
            let directory = fcntl(projectDescriptor, F_DUPFD_CLOEXEC, STDERR_FILENO + 1)
            guard directory >= 0 else {
                throw XcodeError("Cannot duplicate the authenticated Xcode project directory", file: file)
            }
            do {
                guard try XcodeProject.directoryIdentity(directory, file: file) == projectIdentity else {
                    throw XcodeError("The retained Xcode project directory changed", file: file)
                }
                return directory
            } catch let error as XcodeError {
                close(directory)
                throw error
            } catch {
                close(directory)
                throw XcodeError("Cannot verify the retained Xcode project directory", file: file)
            }
        }

        func openVerified(file: String) throws(XcodeError) -> Int32 {
            let directory: Int32
            if let root {
                directory = try Self.open(root: root, components: components, file: file)
            } else if let absolutePath {
                directory = try XcodeProject.openProjectDirectory(absolutePath)
            } else {
                throw XcodeError("The Xcode project has no authenticated pathname", file: file)
            }
            do {
                guard try XcodeProject.directoryIdentity(directory, file: file) == projectIdentity else {
                    throw XcodeError("The anchored Xcode project directory changed since it was read", file: file)
                }
                return directory
            } catch let error as XcodeError {
                close(directory)
                throw error
            } catch {
                close(directory)
                throw XcodeError("Cannot verify the anchored Xcode project directory", file: file)
            }
        }

        func stillReferences(_ directory: Int32, file: String) throws(XcodeError) -> Bool {
            let current = try openVerified(file: file)
            defer { close(current) }
            return try XcodeProject.directoryIdentity(current, file: file)
                == XcodeProject.directoryIdentity(directory, file: file)
        }

        private static func open(root: Int32, components: [String], file: String) throws(XcodeError) -> Int32 {
            var current = fcntl(root, F_DUPFD_CLOEXEC, STDERR_FILENO + 1)
            guard current >= 0 else {
                throw XcodeError("Cannot duplicate the authenticated project root", file: file)
            }
            for component in components {
                let next = component.withCString {
                    openat(current, $0, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
                }
                let failure = errno
                close(current)
                guard next >= 0 else {
                    throw XcodeError(
                        "Cannot safely open anchored project component \(component): \(String(cString: strerror(failure)))",
                        file: file)
                }
                current = next
            }
            return current
        }
    }

    public struct NativeTarget: Sendable, Equatable {
        public let id: String
        public let name: String
        public let productType: String?
    }

    /// The `.xcodeproj` directory.
    public let path: URL
    public var objects: [String: PBXObject]
    public let rootID: String
    private let document: PBXDocument
    private var root: [String: PBXValue]
    private var sourceSnapshot: FileSnapshot?
    private var sourceDirectoryIdentity: DirectoryIdentity?
    private var sourceDigest: String
    private var directoryAnchor: DirectoryAnchor?

    public var file: URL { path.appendingPathComponent("project.pbxproj") }

    public init(path: URL) throws(XcodeError) {
        let project = path.standardizedFileURL
        let anchor = try DirectoryAnchor(path: project, file: project.path)
        let directory = try anchor.openVerified(file: project.path)
        defer { close(directory) }
        let directoryIdentity = try Self.directoryIdentity(directory, file: project.path)
        let (text, snapshot) = try Self.readProjectFile(at: directory, file: project.appendingPathComponent("project.pbxproj"))
        guard try Self.directoryIdentity(project) == directoryIdentity else {
            throw XcodeError("The Xcode project directory changed while it was being read", file: project.path)
        }
        try self.init(path: project, text: text)
        sourceSnapshot = snapshot
        sourceDirectoryIdentity = directoryIdentity
        directoryAnchor = anchor
    }

    /// Opens a project whose relative path must remain beneath an already-authenticated directory descriptor.
    public init(path: URL, relativePath: String, relativeToDirectoryDescriptor descriptor: Int32) throws(XcodeError) {
        let project = path.standardizedFileURL
        let anchor = try DirectoryAnchor(
            rootDescriptor: descriptor, relativePath: relativePath, file: project.path)
        let directory = try anchor.openVerified(file: project.path)
        defer { close(directory) }
        let directoryIdentity = try Self.directoryIdentity(directory, file: project.path)
        let (text, snapshot) = try Self.readProjectFile(
            at: directory, file: project.appendingPathComponent("project.pbxproj"))
        guard try anchor.stillReferences(directory, file: project.path) else {
            throw XcodeError("The anchored Xcode project directory changed while it was being read", file: project.path)
        }
        try self.init(path: project, text: text)
        sourceSnapshot = snapshot
        sourceDirectoryIdentity = directoryIdentity
        directoryAnchor = anchor
    }

    /// Duplicates the exact `.xcodeproj` directory authenticated when this value was loaded. The caller owns the
    /// returned descriptor and must close it. This deliberately does not reopen `path`; call
    /// `verifyDirectoryPathBinding()` separately wherever the pathname itself is part of the operation's contract.
    package func duplicateRetainedDirectoryDescriptor() throws(XcodeError) -> Int32 {
        guard let directoryAnchor else {
            throw XcodeError("The Xcode project was created from text and has no authenticated directory", file: path.path)
        }
        return try directoryAnchor.duplicateRetained(file: path.path)
    }

    /// Proves that the project's public pathname still names the exact directory retained when it was loaded.
    package func verifyDirectoryPathBinding() throws(XcodeError) {
        guard let directoryAnchor else {
            throw XcodeError("The Xcode project was created from text and has no authenticated directory", file: path.path)
        }
        let directory = try directoryAnchor.openVerified(file: path.path)
        close(directory)
    }

    public init(path: URL, text: String) throws(XcodeError) {
        self.path = path.standardizedFileURL
        let file = self.path.appendingPathComponent("project.pbxproj").path
        guard text.utf8.count <= Self.maximumProjectBytes else {
            throw XcodeError("Project file exceeds the 32 MiB limit", file: file)
        }
        do {
            document = try PBXDocument(text)
        } catch {
            throw XcodeError(error.message, file: file)
        }
        root = document.value.dictionary ?? [:]
        var objects: [String: PBXObject] = [:]
        for (id, value) in root["objects"]?.dictionary ?? [:] {
            guard let object = value.dictionary, object.isa != nil else {
                throw XcodeError("Object \(id) has no class", file: file)
            }
            objects[id] = object
        }
        guard let rootID = root["rootObject"]?.string, objects[rootID]?.isa == "PBXProject" else {
            throw XcodeError("The project has no PBXProject root object", file: file)
        }
        self.objects = objects
        self.rootID = rootID
        sourceSnapshot = nil
        sourceDirectoryIdentity = nil
        sourceDigest = Self.digest(Data(text.utf8))
        directoryAnchor = nil
    }

    /// Reads one stable regular-file snapshot without following a final symlink or blocking on a FIFO/device.
    private static func readProjectFile(
        at directory: Int32, name: String = "project.pbxproj", file: URL
    ) throws(XcodeError) -> (String, FileSnapshot) {
        let descriptor = name.withCString {
            openat(directory, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else {
            let reason = errno == ELOOP ? "symbolic link" : String(cString: strerror(errno))
            throw XcodeError("Cannot read the project: refusing \(reason)", file: file.path)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }

        var initial = stat()
        guard fstat(descriptor, &initial) == 0 else {
            throw XcodeError("Cannot inspect the project file", file: file.path)
        }
        guard initial.st_mode & S_IFMT == S_IFREG else {
            throw XcodeError("Project file must be a regular file", file: file.path)
        }
        guard initial.st_size >= 0, initial.st_size <= maximumProjectBytes else {
            throw XcodeError("Project file exceeds the 32 MiB limit", file: file.path)
        }

        var data = Data()
        do {
            while let chunk = try handle.read(
                upToCount: min(1 << 20, maximumProjectBytes + 1 - data.count)), !chunk.isEmpty
            {
                data.append(chunk)
                guard data.count <= maximumProjectBytes else {
                    throw XcodeError("Project file exceeds the 32 MiB limit", file: file.path)
                }
            }
        } catch let error as XcodeError {
            throw error
        } catch {
            throw XcodeError("Cannot read the project: \(error.localizedDescription)", file: file.path)
        }

        var final = stat()
        guard fstat(descriptor, &final) == 0 else {
            throw XcodeError("Cannot re-inspect the project file", file: file.path)
        }
        guard final.st_dev == initial.st_dev, final.st_ino == initial.st_ino,
            final.st_mode == initial.st_mode, final.st_nlink == initial.st_nlink,
            final.st_uid == initial.st_uid, final.st_gid == initial.st_gid,
            final.st_flags == initial.st_flags,
            final.st_size == initial.st_size,
            final.st_mtimespec.tv_sec == initial.st_mtimespec.tv_sec,
            final.st_mtimespec.tv_nsec == initial.st_mtimespec.tv_nsec,
            final.st_ctimespec.tv_sec == initial.st_ctimespec.tv_sec,
            final.st_ctimespec.tv_nsec == initial.st_ctimespec.tv_nsec,
            data.count == Int(initial.st_size)
        else {
            throw XcodeError("Project file changed while it was being read", file: file.path)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw XcodeError("Project file is not valid UTF-8", file: file.path)
        }
        return (
            text,
            FileSnapshot(
                device: UInt64(initial.st_dev), inode: UInt64(initial.st_ino), size: Int64(initial.st_size),
                modifiedSeconds: Int64(initial.st_mtimespec.tv_sec),
                modifiedNanoseconds: Int64(initial.st_mtimespec.tv_nsec),
                changedSeconds: Int64(initial.st_ctimespec.tv_sec),
                changedNanoseconds: Int64(initial.st_ctimespec.tv_nsec), mode: UInt32(initial.st_mode),
                owner: UInt32(initial.st_uid), group: UInt32(initial.st_gid), flags: UInt32(initial.st_flags),
                linkCount: UInt64(initial.st_nlink), digest: digest(data)))
    }

    private static func openProjectDirectory(_ directory: URL) throws(XcodeError) -> Int32 {
        let descriptor = directory.path.withCString { open($0, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW) }
        guard descriptor >= 0 else {
            throw XcodeError("Cannot safely open the Xcode project directory: \(String(cString: strerror(errno)))", file: directory.path)
        }
        return descriptor
    }

    private static func directoryIdentity(_ descriptor: Int32, file: String) throws(XcodeError) -> DirectoryIdentity {
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFDIR else {
            throw XcodeError("Cannot inspect the Xcode project directory", file: file)
        }
        return DirectoryIdentity(device: UInt64(status.st_dev), inode: UInt64(status.st_ino))
    }

    private static func directoryIdentity(_ directory: URL) throws(XcodeError) -> DirectoryIdentity {
        var status = stat()
        guard directory.path.withCString({ lstat($0, &status) }) == 0, status.st_mode & S_IFMT == S_IFDIR else {
            throw XcodeError("Xcode project must be a real directory", file: directory.path)
        }
        return DirectoryIdentity(device: UInt64(status.st_dev), inode: UInt64(status.st_ino))
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func matches(_ status: stat, snapshot: FileSnapshot) -> Bool {
        UInt64(status.st_dev) == snapshot.device && UInt64(status.st_ino) == snapshot.inode
            && Int64(status.st_size) == snapshot.size && UInt32(status.st_mode) == snapshot.mode
            && UInt32(status.st_uid) == snapshot.owner && UInt32(status.st_gid) == snapshot.group
            && UInt32(status.st_flags) == snapshot.flags
            && UInt64(status.st_nlink) == snapshot.linkCount
            && Int64(status.st_mtimespec.tv_sec) == snapshot.modifiedSeconds
            && Int64(status.st_mtimespec.tv_nsec) == snapshot.modifiedNanoseconds
            && Int64(status.st_ctimespec.tv_sec) == snapshot.changedSeconds
            && Int64(status.st_ctimespec.tv_nsec) == snapshot.changedNanoseconds
    }

    /// Renaming may advance ctime even though the inode and bytes are unchanged.
    private static func represents(_ status: stat, snapshot: FileSnapshot) -> Bool {
        UInt64(status.st_dev) == snapshot.device && UInt64(status.st_ino) == snapshot.inode
            && Int64(status.st_size) == snapshot.size && UInt32(status.st_mode) == snapshot.mode
            && UInt32(status.st_uid) == snapshot.owner && UInt32(status.st_gid) == snapshot.group
            && UInt32(status.st_flags) == snapshot.flags && UInt64(status.st_nlink) == snapshot.linkCount
    }

    private static func represents(_ snapshot: FileSnapshot, sameFileAs expected: FileSnapshot) -> Bool {
        snapshot.device == expected.device && snapshot.inode == expected.inode && snapshot.size == expected.size
            && snapshot.mode == expected.mode && snapshot.owner == expected.owner && snapshot.group == expected.group
            && snapshot.flags == expected.flags && snapshot.linkCount == expected.linkCount
            && snapshot.digest == expected.digest
    }

    /// Retain the source-inode lock for compatibility with older SwiftPods writers. Current writers also lock the
    /// project directory because an atomic replacement changes the file inode while the update is still in progress.
    private static func lockProjectFile(at directory: Int32, file: URL) throws(XcodeError) -> Int32 {
        let descriptor = "project.pbxproj".withCString {
            openat(directory, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else {
            throw XcodeError("Cannot lock the project file: \(String(cString: strerror(errno)))", file: file.path)
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let failure = errno
            close(descriptor)
            throw XcodeError(
                "Another process is updating the project file: \(String(cString: strerror(failure)))", file: file.path)
        }
        return descriptor
    }

    /// The file format version; Xcode 15 introduced 60.
    public var objectVersion: Int? { root["objectVersion"]?.string.flatMap { Int($0) } }

    /// The project's directory: where `<group>` and `SOURCE_ROOT` paths start.
    ///
    /// Xcode generators may place the `.xcodeproj` outside the source tree and record that tree in the
    /// `PBXProject.projectDirPath` field. An empty field means the directory containing the `.xcodeproj`.
    public var sourceRoot: URL {
        let projectDirectory = path.deletingLastPathComponent()
        guard let projectDirPath = project.string("projectDirPath"), !projectDirPath.isEmpty else {
            return projectDirectory
        }
        if (projectDirPath as NSString).isAbsolutePath {
            return URL(fileURLWithPath: projectDirPath).standardizedFileURL
        }
        return projectDirectory.appendingPathComponent(projectDirPath).standardizedFileURL
    }

    public subscript(id: String) -> PBXObject? {
        get { objects[id] }
        set { objects[id] = newValue }
    }

    public var project: PBXObject {
        get { objects[rootID]! }
        set { objects[rootID] = newValue }
    }

    public var nativeTargets: [NativeTarget] {
        project.strings("targets").compactMap { id in
            guard let object = objects[id], object.isa == "PBXNativeTarget", let name = object.string("name") else {
                return nil
            }
            return NativeTarget(id: id, name: name, productType: object.string("productType"))
        }
    }

    /// Every object whose array property `key` lists `id`.
    public func referrers(of id: String, through key: String) -> [String] {
        objects.filter { $0.value.strings(key).contains(id) }.keys.sorted()
    }

    /// Text with only changed records rewritten.
    public func serialized() -> String {
        var value = root
        value["objects"] = .dictionary(objects.mapValues { .dictionary($0) })
        return document.updating(.dictionary(value))
    }

    public var hasChanges: Bool {
        var value = root
        value["objects"] = .dictionary(objects.mapValues { .dictionary($0) })
        return document.value != .dictionary(value)
    }

    /// Writes atomically when something changed. Returns whether it wrote.
    @discardableResult
    public mutating func save() throws(XcodeError) -> Bool {
        try save(beforeAtomicReplacement: {})
    }

    /// Internal race seam used to verify that a non-cooperating writer cannot be overwritten between validation and rename.
    @discardableResult
    mutating func save(beforeAtomicReplacement: () -> Void) throws(XcodeError) -> Bool {
        try save(beforeAtomicReplacement: beforeAtomicReplacement, afterAtomicReplacement: {})
    }

    /// The second seam verifies that the directory lock remains held after `RENAME_SWAP`, when the installed file has
    /// a new inode and the source-inode lock alone can no longer serialize another cooperating writer.
    @discardableResult
    mutating func save(
        beforeAtomicReplacement: () -> Void, afterAtomicReplacement: () -> Void
    ) throws(XcodeError) -> Bool {
        guard hasChanges else { return false }
        let data = Data(serialized().utf8)
        guard data.count <= Self.maximumProjectBytes else {
            throw XcodeError("Updated project file exceeds the 32 MiB limit", file: file.path)
        }
        let desiredDigest = Self.digest(data)
        let directory: Int32
        if let directoryAnchor {
            directory = try directoryAnchor.openVerified(file: path.path)
        } else {
            directory = try Self.openProjectDirectory(path)
        }
        defer { close(directory) }
        let openedIdentity = try Self.directoryIdentity(directory, file: path.path)
        guard flock(directory, LOCK_EX | LOCK_NB) == 0 else {
            throw XcodeError(
                "Another process is updating the Xcode project: \(String(cString: strerror(errno)))", file: path.path)
        }
        defer { flock(directory, LOCK_UN) }
        let lockedSource = try Self.lockProjectFile(at: directory, file: file)
        defer {
            flock(lockedSource, LOCK_UN)
            close(lockedSource)
        }
        let current = try Self.readProjectFile(at: directory, file: file).1
        var lockedStatus = stat()
        guard fstat(lockedSource, &lockedStatus) == 0, Self.matches(lockedStatus, snapshot: current) else {
            throw XcodeError("Project file changed while SwiftPods acquired its update lock", file: file.path)
        }
        if let sourceDirectoryIdentity {
            let stillReferenced = if let directoryAnchor {
                try directoryAnchor.stillReferences(directory, file: path.path)
            } else {
                try Self.directoryIdentity(path) == sourceDirectoryIdentity
            }
            guard openedIdentity == sourceDirectoryIdentity, stillReferenced else {
                throw XcodeError("The Xcode project directory changed since it was read", file: path.path)
            }
        }
        if current.digest == desiredDigest {
            sourceSnapshot = current
            sourceDirectoryIdentity = openedIdentity
            sourceDigest = current.digest
            return false
        }
        if let sourceSnapshot {
            guard current == sourceSnapshot else {
                throw XcodeError("Project file changed since SwiftPods read it; no changes were written", file: file.path)
            }
        } else if current.digest != sourceDigest {
            throw XcodeError(
                "Project file does not match the text supplied to XcodeProject; no changes were written", file: file.path)
        }
        let nonReplaceableFlags = UInt32(UF_IMMUTABLE) | UInt32(UF_APPEND) | UInt32(SF_IMMUTABLE)
            | UInt32(SF_APPEND) | UInt32(SF_NOUNLINK)
        guard current.flags & nonReplaceableFlags == 0 else {
            throw XcodeError("Project file has flags that prohibit atomic replacement", file: file.path)
        }
        // Compression/dataless flags describe the old inode's byte representation. Copying their private xattrs and
        // reapplying those flags to different bytes can make the replacement unreadable, so never replace such a file.
        let contentRepresentationFlags = UInt32(UF_COMPRESSED) | UInt32(SF_SYNTHETIC) | UInt32(SF_FIRMLINK)
        guard current.flags & contentRepresentationFlags == 0 else {
            throw XcodeError("Project file uses a storage representation that cannot be safely replaced", file: file.path)
        }

        let temporary = ".project.pbxproj.swiftpods-" + UUID().uuidString
        let descriptor = temporary.withCString {
            openat(directory, $0, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            throw XcodeError("Cannot create a temporary project file: \(String(cString: strerror(errno)))", file: file.path)
        }
        var renamed = false
        defer {
            close(descriptor)
            if !renamed { temporary.withCString { _ = unlinkat(directory, $0, 0) } }
        }
        let preservedMetadata: BoundedFileSecurityMetadata.Snapshot
        do {
            preservedMetadata = try BoundedFileSecurityMetadata.copy(from: lockedSource, to: descriptor)
        } catch {
            throw XcodeError(
                "Cannot preserve bounded project file metadata: \(error)", file: file.path)
        }
        guard fchown(descriptor, uid_t(current.owner), gid_t(current.group)) == 0 else {
            throw XcodeError("Cannot preserve project file ownership: \(String(cString: strerror(errno)))", file: file.path)
        }
        var writeFailure: Int32?
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count > 0 {
                    offset += count
                } else if count < 0 && errno == EINTR {
                    continue
                } else {
                    writeFailure = count < 0 ? errno : EIO
                    break
                }
            }
        }
        if let writeFailure {
            throw XcodeError("Cannot write the project: \(String(cString: strerror(writeFailure)))", file: file.path)
        }
        let permissions = mode_t(current.mode & 0o7777)
        guard fchmod(descriptor, permissions) == 0 else {
            throw XcodeError("Cannot set project file permissions: \(String(cString: strerror(errno)))", file: file.path)
        }
        guard fchflags(descriptor, current.flags) == 0 else {
            throw XcodeError("Cannot preserve project file flags: \(String(cString: strerror(errno)))", file: file.path)
        }
        guard fsync(descriptor) == 0 else {
            throw XcodeError("Cannot flush the project file: \(String(cString: strerror(errno)))", file: file.path)
        }
        var replacementStatus = stat()
        guard fstat(descriptor, &replacementStatus) == 0 else {
            throw XcodeError("Cannot inspect the prepared project file", file: file.path)
        }

        // Recheck immediately before the atomic replacement, after all potentially slow serialization and I/O.
        guard try Self.readProjectFile(at: directory, file: file).1 == current else {
            throw XcodeError("Project file changed while SwiftPods prepared its update; no changes were written", file: file.path)
        }
        beforeAtomicReplacement()
        let stillReferencedBeforeReplacement = if let directoryAnchor {
            try directoryAnchor.stillReferences(directory, file: path.path)
        } else {
            try Self.directoryIdentity(path) == openedIdentity
        }
        guard stillReferencedBeforeReplacement else {
            throw XcodeError("The Xcode project directory moved before SwiftPods could update it", file: path.path)
        }
        do {
            try BoundedFileSecurityMetadata.requireEquivalentMetadata(descriptor, to: preservedMetadata)
        } catch {
            throw XcodeError(
                "Prepared project file metadata changed before atomic replacement: \(error)", file: file.path)
        }
        let replacement = temporary.withCString { temporaryName in
            "project.pbxproj".withCString {
                projectName in renameatx_np(directory, temporaryName, directory, projectName, UInt32(RENAME_SWAP))
            }
        }
        guard replacement == 0 else {
            throw XcodeError("Cannot replace the project: \(String(cString: strerror(errno)))", file: file.path)
        }
        renamed = true
        afterAtomicReplacement()

        let displacedFile = path.appendingPathComponent(temporary)
        let displaced = try? Self.readProjectFile(at: directory, name: temporary, file: displacedFile).1
        let installed = try? Self.readProjectFile(at: directory, file: file).1
        let installedMetadataIsPrepared: Bool
        do {
            try BoundedFileSecurityMetadata.requireEquivalentMetadata(descriptor, to: preservedMetadata)
            installedMetadataIsPrepared = true
        } catch {
            installedMetadataIsPrepared = false
        }
        let installedIsPrepared = installed.map {
            Self.represents(replacementStatus, snapshot: $0) && $0.digest == desiredDigest
                && $0.mode == current.mode && $0.owner == current.owner && $0.group == current.group
                && $0.flags == current.flags && installedMetadataIsPrepared
        } == true
        let directoryStillReferenced = if let directoryAnchor {
            (try? directoryAnchor.stillReferences(directory, file: path.path)) == true
        } else {
            (try? Self.directoryIdentity(path)) == openedIdentity
        }
        guard displaced.map({ Self.represents($0, sameFileAs: current) }) == true,
            installedIsPrepared, directoryStillReferenced, let written = installed
        else {
            // Swap back instead of overwriting the file that appeared after the final validation. Both names remain
            // available throughout; only a file proven to be our prepared inode is eligible for cleanup.
            let rollback = temporary.withCString { temporaryName in
                "project.pbxproj".withCString {
                    projectName in renameatx_np(directory, temporaryName, directory, projectName, UInt32(RENAME_SWAP))
                }
            }
            guard rollback == 0 else {
                throw XcodeError(
                    "Project file changed during atomic replacement; the displaced data was preserved at \(displacedFile.path)",
                    file: file.path)
            }
            renamed = false
            let prepared = try? Self.readProjectFile(at: directory, name: temporary, file: displacedFile).1
            var preservedRecovery = true
            if prepared.map({ Self.represents(replacementStatus, snapshot: $0) && $0.digest == desiredDigest }) == true {
                preservedRecovery = temporary.withCString { unlinkat(directory, $0, 0) } != 0
            }
            // Never let the defer unlink a name another writer could recreate after the verified cleanup.
            // If this is not our prepared inode, it is a concurrent update and must remain recoverable.
            renamed = true
            throw XcodeError(
                preservedRecovery
                    ? "Project file changed during atomic replacement; concurrent data was preserved at \(displacedFile.path)"
                    : "Project file changed during atomic replacement; no changes were written",
                file: file.path)
        }
        guard temporary.withCString({ unlinkat(directory, $0, 0) }) == 0 else {
            throw XcodeError(
                "Project was updated, but its previous inode could not be removed: \(String(cString: strerror(errno)))",
                file: displacedFile.path)
        }
        guard fsync(directory) == 0 else {
            throw XcodeError("Cannot flush the Xcode project directory: \(String(cString: strerror(errno)))", file: path.path)
        }
        let finalDirectoryIsReferenced = if let directoryAnchor {
            try directoryAnchor.stillReferences(directory, file: path.path)
        } else {
            try Self.directoryIdentity(path) == openedIdentity
        }
        guard finalDirectoryIsReferenced else {
            throw XcodeError("The Xcode project directory moved while SwiftPods was writing it", file: path.path)
        }
        sourceSnapshot = written
        sourceDirectoryIdentity = openedIdentity
        sourceDigest = written.digest
        return true
    }

    /// The identifier SwiftPods gives the object it derives from `key`. Stable across runs and machines,
    /// so ownership needs no record: an object is SwiftPods' own when its identifier matches its key.
    public static func identifier(_ key: String) -> String {
        let digest = SHA256.hash(data: Data(("SwiftPods\u{0}" + key).utf8))
        return digest.prefix(12).map { String(format: "%02X", $0) }.joined()
    }

    /// Adds or replaces the object with the identifier derived from `key`.
    @discardableResult
    public mutating func put(_ key: String, _ object: PBXObject) -> String {
        let id = Self.identifier(key)
        objects[id] = object
        return id
    }

    /// Removes an object and every array reference to it.
    public mutating func remove(_ id: String) {
        remove(Set([id]))
    }

    /// Removes a set of objects and all of their array references in one object-graph pass.
    public mutating func remove(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        for id in ids { objects[id] = nil }
        for (other, object) in objects {
            var updated = object
            var changed = false
            for (key, value) in object {
                guard let array = value.array else { continue }
                let filtered = array.filter { value in
                    guard let reference = value.string else { return true }
                    return !ids.contains(reference)
                }
                guard filtered.count != array.count else { continue }
                updated[key] = .array(filtered)
                changed = true
            }
            if changed { objects[other] = updated }
        }
    }

    /// Appends `id` to the array property `key` of `owner` unless it is already listed.
    public mutating func append(_ id: String, to key: String, of owner: String) {
        guard var object = objects[owner] else { return }
        var values = object[key]?.array ?? []
        guard !values.contains(.string(id)) else { return }
        values.append(.string(id))
        object[key] = .array(values)
        objects[owner] = object
    }

    /// Build configuration identifiers of a target or the project, keyed by configuration name.
    public func configurations(of owner: String) -> [String: String] {
        guard let list = objects[owner]?.string("buildConfigurationList") else { return [:] }
        var result: [String: String] = [:]
        for id in objects[list]?.strings("buildConfigurations") ?? [] {
            if let name = objects[id]?.string("name") { result[name] = id }
        }
        return result
    }
}
