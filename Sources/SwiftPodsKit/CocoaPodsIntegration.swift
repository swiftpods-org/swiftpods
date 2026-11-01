import Darwin
import Foundation
import SwiftPodsSecurity
import SwiftPodsXcode

/// Removes what CocoaPods, or SwiftPods 0.1, added to a project, so migrating does not need a working CocoaPods.
enum CocoaPodsIntegration {
    private static let phasePrefixes = ["[CP] ", "[CP-User] ", "📦 ", ProjectIntegration.scriptPrefix]
    private static let maximumWorkspaceBytes = 16 * 1_024 * 1_024

    fileprivate struct OpenedWorkspaceDirectory {
        let root: Int32
        let components: [String]
        let directory: Int32
        let absoluteBindingPath: URL?
    }

    private struct AbsoluteWorkspaceBinding {
        let components: [String]
        let device: UInt64
        let inode: UInt64
    }

    fileprivate final class WorkspaceDirectoryAnchor {
        let root: Int32
        let components: [String]
        let directory: Int32
        let device: UInt64
        let inode: UInt64
        let absoluteBindingPath: URL?

        init(_ opened: OpenedWorkspaceDirectory, status: stat, file: String) throws {
            let root = openat(
                opened.root, ".", O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
            guard root >= 0 else {
                throw SwiftPodsError("Cannot retain the workspace root descriptor", file: file)
            }
            let directory = openat(
                opened.directory, ".", O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
            guard directory >= 0 else {
                close(root)
                throw SwiftPodsError("Cannot retain the Xcode workspace descriptor", file: file)
            }
            self.root = root
            self.components = opened.components
            self.directory = directory
            device = UInt64(status.st_dev)
            inode = UInt64(status.st_ino)
            absoluteBindingPath = opened.absoluteBindingPath
        }

        deinit {
            close(directory)
            close(root)
        }

        func openDirectory(file: String) throws -> Int32 {
            let duplicate = openat(
                directory, ".", O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
            guard duplicate >= 0 else {
                throw SwiftPodsError("Cannot duplicate the retained Xcode workspace descriptor", file: file)
            }
            return duplicate
        }

        func isStillBound(file: String) throws -> Bool {
            let currentComponents: [String]
            if let absoluteBindingPath {
                guard let binding = try CocoaPodsIntegration.absoluteWorkspaceBinding(absoluteBindingPath),
                    binding.device == device, binding.inode == inode
                else { return false }
                currentComponents = binding.components
            } else {
                currentComponents = components
            }
            guard let reopened = try CocoaPodsIntegration.openRelativeDirectory(
                from: root, components: currentComponents, file: file)
            else { return false }
            defer { close(reopened) }
            var status = stat()
            return fstat(reopened, &status) == 0 && status.st_mode & S_IFMT == S_IFDIR
                && UInt64(status.st_dev) == device && UInt64(status.st_ino) == inode
        }
    }

    /// Accepts stable system symlink ancestors such as macOS `/var -> /private/var`,
    /// while binding the caller's lexical path to the canonical directory inode.
    private static func absoluteWorkspaceBinding(_ workspace: URL) throws -> AbsoluteWorkspaceBinding? {
        guard workspace.isFileURL, workspace.path.hasPrefix("/"),
            workspace.path.utf8.count <= Int(PATH_MAX)
        else {
            throw SwiftPodsError("Xcode workspace path is not a safe absolute path", file: workspace.path)
        }
        var before = stat()
        if workspace.path.withCString({ lstat($0, &before) }) != 0 {
            if errno == ENOENT { return nil }
            throw SwiftPodsError(
                "Cannot inspect the Xcode workspace path: \(String(cString: strerror(errno)))",
                file: workspace.path)
        }
        guard before.st_mode & S_IFMT == S_IFDIR else {
            throw SwiftPodsError("Xcode workspace path must name a real directory", file: workspace.path)
        }
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let result = buffer.withUnsafeMutableBufferPointer { output in
            workspace.path.withCString { realpath($0, output.baseAddress) }
        }
        guard result != nil else {
            throw SwiftPodsError(
                "Cannot resolve the Xcode workspace path: \(String(cString: strerror(errno)))",
                file: workspace.path)
        }
        var after = stat()
        guard workspace.path.withCString({ lstat($0, &after) }) == 0,
            after.st_mode & S_IFMT == S_IFDIR,
            after.st_dev == before.st_dev, after.st_ino == before.st_ino
        else {
            throw SwiftPodsError("Xcode workspace path changed while it was being resolved", file: workspace.path)
        }
        let canonicalBytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        guard let canonical = String(bytes: canonicalBytes, encoding: .utf8) else {
            throw SwiftPodsError("Canonical Xcode workspace path is not UTF-8", file: workspace.path)
        }
        let parts = (canonical as NSString).pathComponents
        guard parts.first == "/", parts.dropFirst().allSatisfy({
            !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/")
                && $0.utf8.count <= Int(NAME_MAX)
        }) else {
            throw SwiftPodsError("Canonical Xcode workspace path is unsafe", file: workspace.path)
        }
        return AbsoluteWorkspaceBinding(
            components: Array(parts.dropFirst()), device: UInt64(after.st_dev), inode: UInt64(after.st_ino))
    }

    /// Walks only through already-open directories. `O_NOFOLLOW` on only the
    /// final `.xcworkspace` cannot protect a mutable ancestor from replacement.
    private static func openRelativeDirectory(
        from root: Int32, components: [String], file: String
    ) throws -> Int32? {
        var current = openat(root, ".", O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
        guard current >= 0 else {
            throw SwiftPodsError("Cannot duplicate the workspace root descriptor", file: file)
        }
        for component in components {
            let next = component.withCString {
                openat(current, $0, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
            }
            if next < 0 {
                let failure = errno
                close(current)
                if failure == ENOENT { return nil }
                throw SwiftPodsError(
                    "Cannot safely open the Xcode workspace directory path component: \(String(cString: strerror(failure)))",
                    file: file)
            }
            close(current)
            current = next
        }
        return current
    }

    private static func openWorkspaceDirectory(
        _ workspace: URL, relativeToWorkspaceRoot workspaceRootDescriptor: Int32?,
        relativeWorkspacePath: String?
    ) throws -> OpenedWorkspaceDirectory? {
        let root: Int32
        let components: [String]
        let absoluteBindingPath: URL?
        let absoluteBinding: AbsoluteWorkspaceBinding?
        switch (workspaceRootDescriptor, relativeWorkspacePath) {
        case (let descriptor?, let path?):
            let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard !path.hasPrefix("/"), path.utf8.count <= Int(PATH_MAX),
                parts.last?.hasSuffix(".xcworkspace") == true,
                parts.allSatisfy({
                    !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/")
                        && $0.utf8.count <= Int(NAME_MAX)
                })
            else {
                throw SwiftPodsError("Relative Xcode workspace path is unsafe", file: workspace.path)
            }
            root = openat(
                descriptor, ".", O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
            components = parts
            absoluteBindingPath = nil
            absoluteBinding = nil
        case (nil, nil):
            guard let binding = try absoluteWorkspaceBinding(workspace) else { return nil }
            root = open("/", O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
            components = binding.components
            absoluteBindingPath = workspace
            absoluteBinding = binding
        default:
            throw SwiftPodsError(
                "A relative workspace path and its authenticated root descriptor must be supplied together",
                file: workspace.path)
        }
        guard root >= 0 else {
            throw SwiftPodsError(
                "Cannot anchor the Xcode workspace path: \(String(cString: strerror(errno)))", file: workspace.path)
        }
        let directory: Int32
        do {
            guard let opened = try openRelativeDirectory(
                from: root, components: components, file: workspace.path)
            else {
                close(root)
                return nil
            }
            directory = opened
        } catch {
            close(root)
            throw error
        }
        if let absoluteBinding {
            var status = stat()
            guard fstat(directory, &status) == 0, status.st_mode & S_IFMT == S_IFDIR,
                UInt64(status.st_dev) == absoluteBinding.device, UInt64(status.st_ino) == absoluteBinding.inode
            else {
                close(directory)
                close(root)
                throw SwiftPodsError(
                    "Canonical Xcode workspace differs from the caller's path", file: workspace.path)
            }
        }
        return OpenedWorkspaceDirectory(
            root: root, components: components, directory: directory,
            absoluteBindingPath: absoluteBindingPath)
    }

    private static func workspacePathStillReferences(
        _ opened: OpenedWorkspaceDirectory, status expected: stat, file: String
    ) throws -> Bool {
        guard let directory = try openRelativeDirectory(
            from: opened.root, components: opened.components, file: file)
        else { return false }
        defer { close(directory) }
        var current = stat()
        return fstat(directory, &current) == 0 && current.st_mode & S_IFMT == S_IFDIR
            && current.st_dev == expected.st_dev && current.st_ino == expected.st_ino
    }

    fileprivate struct WorkspaceSnapshot: Equatable {
        let data: Data
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
    }

    struct WorkspaceMutation {
        fileprivate let workspace: URL
        fileprivate let anchor: WorkspaceDirectoryAnchor
        fileprivate let original: WorkspaceSnapshot
        fileprivate let installed: WorkspaceSnapshot

        func verifyInstalled() throws {
            try CocoaPodsIntegration.withMutationDirectory(self, requirePathBinding: true) { directory, file in
                guard try CocoaPodsIntegration.readWorkspace(at: directory, file: file) == installed else {
                    throw SwiftPodsError(
                        "Xcode workspace changed before deintegration committed", file: file.path)
                }
            }
        }

        func rollback() throws {
            try CocoaPodsIntegration.withMutationDirectory(self, requirePathBinding: false) { directory, file in
                _ = try CocoaPodsIntegration.writeWorkspace(
                    original.data, replacing: installed, at: directory, file: file,
                    beforeAtomicReplacement: {}, afterAtomicReplacement: {})
            }
        }
    }

    private static func matches(_ status: stat, snapshot: WorkspaceSnapshot) -> Bool {
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

    private static func represents(_ status: stat, snapshot: WorkspaceSnapshot) -> Bool {
        UInt64(status.st_dev) == snapshot.device && UInt64(status.st_ino) == snapshot.inode
            && Int64(status.st_size) == snapshot.size && UInt32(status.st_mode) == snapshot.mode
            && UInt32(status.st_uid) == snapshot.owner && UInt32(status.st_gid) == snapshot.group
            && UInt32(status.st_flags) == snapshot.flags && UInt64(status.st_nlink) == snapshot.linkCount
    }

    private static func represents(_ snapshot: WorkspaceSnapshot, sameFileAs expected: WorkspaceSnapshot) -> Bool {
        snapshot.device == expected.device && snapshot.inode == expected.inode && snapshot.size == expected.size
            && snapshot.mode == expected.mode && snapshot.owner == expected.owner && snapshot.group == expected.group
            && snapshot.flags == expected.flags && snapshot.linkCount == expected.linkCount && snapshot.data == expected.data
    }

    private static func isPodsFile(_ object: PBXObject) -> Bool {
        let path = object.string("path") ?? ""
        let name = object.string("name") ?? (path as NSString).lastPathComponent
        return path.contains("Pods/Target Support Files/") || path == "Pods/Pods.xcodeproj" || path.hasSuffix("/Pods/Pods.xcodeproj")
            || (name.hasPrefix("Pods-") && name.hasSuffix(".xcconfig"))
            || (name.hasPrefix("Pods_") && name.hasSuffix(".framework"))
            || (name.hasPrefix("libPods-") && name.hasSuffix(".a"))
    }

    static func remove(from project: inout XcodeProject) throws -> [ProjectChange] {
        let owned = try ProjectIntegration.ownedIdentifiers(project)
        var removed = Set<String>()
        var changes: [ProjectChange] = []

        let files = Set(project.objects.filter { $0.value.isa == "PBXFileReference" && isPodsFile($0.value) }.keys)
        removed.formUnion(files)
        removed.formUnion(project.objects.filter { $0.value.isa == "PBXBuildFile" && files.contains($0.value.string("fileRef") ?? "") }.keys)
        let proxies = Set(project.objects.filter { _, object in
            object.isa == "PBXContainerItemProxy"
                && (files.contains(object.string("containerPortal") ?? "") || object.string("remoteInfo")?.hasPrefix("Pods-") == true)
        }.keys)
        removed.formUnion(proxies)

        for target in project.nativeTargets {
            let object = project[target.id] ?? [:]
            for id in object.strings("buildPhases") where !owned.contains(id) {
                guard let phase = project[id], phase.isa == "PBXShellScriptBuildPhase", let name = phase.string("name"),
                    phasePrefixes.contains(where: name.hasPrefix)
                else { continue }
                removed.insert(id)
                changes.append(ProjectChange(kind: .removed, subject: "script phase \(name) in \(target.name)"))
            }
            for id in object.strings("dependencies") {
                guard let dependency = project[id] else { continue }
                if dependency.string("name")?.hasPrefix("Pods-") == true || proxies.contains(dependency.string("targetProxy") ?? "") {
                    removed.insert(id)
                    changes.append(ProjectChange(
                        kind: .removed, subject: "target dependency \(dependency.string("name") ?? id) in \(target.name)"))
                }
            }
        }
        for id in files.sorted() {
            changes.append(ProjectChange(kind: .removed, subject: "file " + (project[id]?.string("path") ?? id)))
        }

        // Compute groups that become empty before mutating the graph, then remove every
        // CocoaPods-owned object and every array reference in one graph pass.
        removed.formUnion(project.objects.compactMap { id, object in
            guard object.isa == "PBXGroup",
                (object.string("name") ?? object.string("path")) == "Pods",
                object.strings("children").allSatisfy(removed.contains)
            else { return nil }
            return id
        })
        project.remove(removed)

        // Cross-project references to the Pods project are dictionaries, which `remove` does not visit.
        var root = project.project
        if let references = root["projectReferences"]?.array {
            let kept = references.filter { !files.contains($0.dictionary?["ProjectRef"]?.string ?? "") }
            root["projectReferences"] = kept.isEmpty ? nil : .array(kept)
            project.project = root
        }
        for (id, object) in project.objects where object.isa == "XCBuildConfiguration" {
            var configuration = object
            if let base = configuration.string("baseConfigurationReference"), files.contains(base) {
                configuration["baseConfigurationReference"] = nil
            }
            if var settings = configuration["buildSettings"]?.dictionary {
                for key in settings.keys where key.hasPrefix("PODS_") {
                    settings[key] = nil
                    changes.append(ProjectChange(kind: .removed, subject: "build setting \(key) in \(object.string("name") ?? id)"))
                }
                configuration["buildSettings"] = .dictionary(settings)
            }
            if configuration != object { project[id] = configuration }
        }
        return changes
    }

    /// Removes the Pods project from a workspace's file list; returns whether the workspace changed.
    static func removePodsProject(
        fromWorkspace workspace: URL, beforeAtomicReplacement: () -> Void = {}
    ) throws -> Bool {
        try removePodsProjectRecoverably(
            fromWorkspace: workspace, beforeAtomicReplacement: beforeAtomicReplacement,
            afterAtomicReplacement: {}) != nil
    }

    /// The post-swap seam verifies serialization across the inode change; production and existing race tests use the
    /// overload above so a trailing closure retains its `beforeAtomicReplacement` meaning.
    static func removePodsProject(
        fromWorkspace workspace: URL, beforeAtomicReplacement: () -> Void,
        afterAtomicReplacement: () -> Void
    ) throws -> Bool {
        try removePodsProjectRecoverably(
            fromWorkspace: workspace, beforeAtomicReplacement: beforeAtomicReplacement,
            afterAtomicReplacement: afterAtomicReplacement) != nil
    }

    /// Removes the Pods reference and retains the exact before/after snapshots required for a later CAS rollback.
    static func removePodsProjectRecoverably(
        fromWorkspace workspace: URL, relativeToWorkspaceRoot workspaceRootDescriptor: Int32? = nil,
        relativeWorkspacePath: String? = nil, beforeAtomicReplacement: () -> Void = {},
        afterAtomicReplacement: () -> Void = {}
    ) throws -> WorkspaceMutation? {
        let file = workspace.appendingPathComponent("contents.xcworkspacedata")
        guard let opened = try openWorkspaceDirectory(
            workspace, relativeToWorkspaceRoot: workspaceRootDescriptor,
            relativeWorkspacePath: relativeWorkspacePath)
        else { return nil }
        let directory = opened.directory
        defer {
            close(directory)
            close(opened.root)
        }
        var openedDirectory = stat()
        guard fstat(directory, &openedDirectory) == 0, openedDirectory.st_mode & S_IFMT == S_IFDIR else {
            throw SwiftPodsError("Cannot inspect the Xcode workspace directory", file: workspace.path)
        }
        // Retain both binding descriptors before the first mutation. Descriptor
        // exhaustion must fail before, rather than after, the workspace swap.
        let anchor = try WorkspaceDirectoryAnchor(opened, status: openedDirectory, file: workspace.path)
        // Atomic replacement changes the contents file's inode. Lock the stable workspace directory for the complete
        // read/prepare/swap/verify transaction; the file lock below remains compatible with older SwiftPods writers.
        guard flock(directory, LOCK_EX | LOCK_NB) == 0 else {
            throw SwiftPodsError(
                "Another process is updating the Xcode workspace: \(String(cString: strerror(errno)))",
                file: workspace.path)
        }
        defer { flock(directory, LOCK_UN) }
        guard let original = try readWorkspace(at: directory, file: file) else { return nil }
        guard let text = String(data: original.data, encoding: .utf8) else {
            throw SwiftPodsError("Xcode workspace data is not valid UTF-8", file: file.path)
        }
        let pattern = #"[ \t]*<FileRef\s+location\s*=\s*"[^"]*Pods/Pods\.xcodeproj">\s*</FileRef>\r?\n"#
        let expression = try NSRegularExpression(pattern: pattern)
        let updated = expression.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        guard updated != text else { return nil }
        let data = Data(updated.utf8)
        guard data.count <= maximumWorkspaceBytes else {
            throw SwiftPodsError("Updated Xcode workspace data exceeds the 16 MiB limit", file: file.path)
        }
        let installed: WorkspaceSnapshot
        do {
            installed = try writeWorkspace(
                data, replacing: original, at: directory, file: file,
                beforeAtomicReplacement: beforeAtomicReplacement, afterAtomicReplacement: afterAtomicReplacement)
        } catch {
            let writeFailure = error
            // A durability/cleanup error can occur after the swap. Restore only when the pathname still contains the
            // exact bytes this invocation prepared; never overwrite a non-cooperating writer.
            if let current = try? readWorkspace(at: directory, file: file), current.data == data {
                do {
                    _ = try writeWorkspace(
                        original.data, replacing: current, at: directory, file: file,
                        beforeAtomicReplacement: {}, afterAtomicReplacement: {})
                } catch {
                    throw SwiftPodsError(
                        "Workspace update failed and its rollback was incomplete: \(writeFailure)",
                        file: file.path, hint: "Rollback also failed: \(error)")
                }
            }
            throw writeFailure
        }
        guard (try? workspacePathStillReferences(
            opened, status: openedDirectory, file: workspace.path)) == true
        else {
            do {
                _ = try writeWorkspace(
                    original.data, replacing: installed, at: directory, file: file,
                    beforeAtomicReplacement: {}, afterAtomicReplacement: {})
            } catch {
                throw SwiftPodsError(
                    "Xcode workspace directory changed and its update could not be rolled back",
                    file: workspace.path, hint: "Rollback failed: \(error)")
            }
            throw SwiftPodsError("Xcode workspace directory changed while it was being updated", file: workspace.path)
        }
        return WorkspaceMutation(
            workspace: workspace, anchor: anchor, original: original, installed: installed)
    }

    private static func withMutationDirectory<T>(
        _ mutation: WorkspaceMutation, requirePathBinding: Bool,
        _ body: (Int32, URL) throws -> T
    ) throws -> T {
        let file = mutation.workspace.appendingPathComponent("contents.xcworkspacedata")
        let directory = try mutation.anchor.openDirectory(file: mutation.workspace.path)
        defer { close(directory) }
        var status = stat()
        guard fstat(directory, &status) == 0, status.st_mode & S_IFMT == S_IFDIR,
            UInt64(status.st_dev) == mutation.anchor.device, UInt64(status.st_ino) == mutation.anchor.inode
        else {
            throw SwiftPodsError(
                "Workspace rollback directory changed; refusing to overwrite it", file: mutation.workspace.path)
        }
        if requirePathBinding {
            guard try mutation.anchor.isStillBound(file: mutation.workspace.path) else {
                throw SwiftPodsError(
                    "Xcode workspace path changed before deintegration committed", file: mutation.workspace.path)
            }
        }
        guard flock(directory, LOCK_EX | LOCK_NB) == 0 else {
            throw SwiftPodsError("Another process is updating the Xcode workspace", file: mutation.workspace.path)
        }
        defer { flock(directory, LOCK_UN) }
        let result = try body(directory, file)
        if requirePathBinding {
            guard try mutation.anchor.isStillBound(file: mutation.workspace.path) else {
                throw SwiftPodsError(
                    "Xcode workspace path changed while deintegration was being verified",
                    file: mutation.workspace.path)
            }
        }
        return result
    }

    /// Workspace XML is untrusted project input: read a stable regular-file snapshot with a practical size cap.
    private static func readWorkspace(
        at directory: Int32, name: String = "contents.xcworkspacedata", file: URL
    ) throws -> WorkspaceSnapshot? {
        let descriptor = name.withCString {
            openat(directory, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw SwiftPodsError("Cannot safely read the Xcode workspace: \(String(cString: strerror(errno)))", file: file.path)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var initial = stat()
        guard fstat(descriptor, &initial) == 0, initial.st_mode & S_IFMT == S_IFREG,
            initial.st_size >= 0, initial.st_size <= maximumWorkspaceBytes
        else {
            throw SwiftPodsError("Xcode workspace data must be a regular file no larger than 16 MiB", file: file.path)
        }
        var data = Data()
        while let chunk = try handle.read(
            upToCount: min(1 << 20, maximumWorkspaceBytes + 1 - data.count)), !chunk.isEmpty
        {
            data.append(chunk)
            guard data.count <= maximumWorkspaceBytes else {
                throw SwiftPodsError("Xcode workspace data exceeds the 16 MiB limit", file: file.path)
            }
        }
        var final = stat()
        guard fstat(descriptor, &final) == 0, final.st_dev == initial.st_dev,
            final.st_ino == initial.st_ino, final.st_mode == initial.st_mode,
            final.st_uid == initial.st_uid, final.st_gid == initial.st_gid,
            final.st_flags == initial.st_flags,
            final.st_nlink == initial.st_nlink, final.st_size == initial.st_size,
            final.st_mtimespec.tv_sec == initial.st_mtimespec.tv_sec,
            final.st_mtimespec.tv_nsec == initial.st_mtimespec.tv_nsec,
            final.st_ctimespec.tv_sec == initial.st_ctimespec.tv_sec,
            final.st_ctimespec.tv_nsec == initial.st_ctimespec.tv_nsec,
            data.count == Int(initial.st_size)
        else { throw SwiftPodsError("Xcode workspace data changed while it was being read", file: file.path) }
        return WorkspaceSnapshot(
            data: data, device: UInt64(initial.st_dev), inode: UInt64(initial.st_ino), size: Int64(initial.st_size),
            modifiedSeconds: Int64(initial.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(initial.st_mtimespec.tv_nsec),
            changedSeconds: Int64(initial.st_ctimespec.tv_sec),
            changedNanoseconds: Int64(initial.st_ctimespec.tv_nsec), mode: UInt32(initial.st_mode),
            owner: UInt32(initial.st_uid), group: UInt32(initial.st_gid), flags: UInt32(initial.st_flags),
            linkCount: UInt64(initial.st_nlink))
    }

    private static func writeWorkspace(
        _ data: Data, replacing original: WorkspaceSnapshot, at directory: Int32, file: URL,
        beforeAtomicReplacement: () -> Void, afterAtomicReplacement: () -> Void
    ) throws -> WorkspaceSnapshot {
        let source = "contents.xcworkspacedata".withCString {
            openat(directory, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard source >= 0 else {
            throw SwiftPodsError("Cannot lock the Xcode workspace: \(String(cString: strerror(errno)))", file: file.path)
        }
        defer {
            flock(source, LOCK_UN)
            close(source)
        }
        guard flock(source, LOCK_EX | LOCK_NB) == 0 else {
            throw SwiftPodsError("Another process is updating the Xcode workspace", file: file.path)
        }
        var sourceStatus = stat()
        guard fstat(source, &sourceStatus) == 0, matches(sourceStatus, snapshot: original) else {
            throw SwiftPodsError("Xcode workspace data changed before SwiftPods acquired its update lock", file: file.path)
        }
        let nonReplaceableFlags = UInt32(UF_IMMUTABLE) | UInt32(UF_APPEND) | UInt32(SF_IMMUTABLE)
            | UInt32(SF_APPEND) | UInt32(SF_NOUNLINK)
        guard original.flags & nonReplaceableFlags == 0 else {
            throw SwiftPodsError("Workspace file has flags that prohibit atomic replacement", file: file.path)
        }
        let contentRepresentationFlags = UInt32(UF_COMPRESSED) | UInt32(SF_SYNTHETIC) | UInt32(SF_FIRMLINK)
        guard original.flags & contentRepresentationFlags == 0 else {
            throw SwiftPodsError(
                "Workspace file uses a storage representation that cannot be safely replaced", file: file.path)
        }
        let temporary = ".contents.xcworkspacedata.swiftpods-" + UUID().uuidString
        let descriptor = temporary.withCString {
            openat(directory, $0, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        }
        guard descriptor >= 0 else {
            throw SwiftPodsError("Cannot create a private workspace update: \(String(cString: strerror(errno)))", file: file.path)
        }
        var renamed = false
        defer {
            close(descriptor)
            if !renamed { temporary.withCString { _ = unlinkat(directory, $0, 0) } }
        }
        // Atomic replacement creates a new inode; retain ACLs, xattrs and permissions rather than silently broadening
        // a private workspace file or discarding its metadata policy.
        let preservedMetadata: BoundedFileSecurityMetadata.Snapshot
        do {
            preservedMetadata = try BoundedFileSecurityMetadata.copy(from: source, to: descriptor)
        } catch {
            throw SwiftPodsError(
                "Cannot preserve bounded workspace file metadata: \(error)", file: file.path)
        }
        guard fchown(descriptor, uid_t(original.owner), gid_t(original.group)) == 0 else {
            throw SwiftPodsError(
                "Cannot preserve workspace file ownership: \(String(cString: strerror(errno)))", file: file.path)
        }
        var failure: Int32?
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count > 0 { offset += count }
                else if count < 0 && errno == EINTR { continue }
                else { failure = count < 0 ? errno : EIO; break }
            }
        }
        if let failure {
            throw SwiftPodsError("Cannot write the workspace: \(String(cString: strerror(failure)))", file: file.path)
        }
        guard fchmod(descriptor, mode_t(original.mode & 0o7777)) == 0 else {
            throw SwiftPodsError("Cannot set workspace file permissions: \(String(cString: strerror(errno)))", file: file.path)
        }
        guard fchflags(descriptor, original.flags) == 0 else {
            throw SwiftPodsError("Cannot preserve workspace file flags: \(String(cString: strerror(errno)))", file: file.path)
        }
        guard fsync(descriptor) == 0 else {
            throw SwiftPodsError("Cannot flush the workspace: \(String(cString: strerror(errno)))", file: file.path)
        }
        var replacementStatus = stat()
        guard fstat(descriptor, &replacementStatus) == 0 else {
            throw SwiftPodsError("Cannot inspect the prepared workspace file", file: file.path)
        }
        guard try readWorkspace(at: directory, file: file) == original else {
            throw SwiftPodsError("Xcode workspace data changed while SwiftPods prepared its update", file: file.path)
        }
        beforeAtomicReplacement()
        do {
            try BoundedFileSecurityMetadata.requireEquivalentMetadata(descriptor, to: preservedMetadata)
        } catch {
            throw SwiftPodsError(
                "Prepared workspace file metadata changed before atomic replacement: \(error)", file: file.path)
        }
        let result = temporary.withCString { temporaryName in
            "contents.xcworkspacedata".withCString {
                name in renameatx_np(directory, temporaryName, directory, name, UInt32(RENAME_SWAP))
            }
        }
        guard result == 0 else {
            throw SwiftPodsError("Cannot replace the workspace: \(String(cString: strerror(errno)))", file: file.path)
        }
        renamed = true
        afterAtomicReplacement()

        let displacedFile = file.deletingLastPathComponent().appendingPathComponent(temporary)
        let displaced = try? readWorkspace(at: directory, name: temporary, file: displacedFile)
        let installed = try? readWorkspace(at: directory, file: file)
        let installedMetadataIsPrepared: Bool
        do {
            try BoundedFileSecurityMetadata.requireEquivalentMetadata(descriptor, to: preservedMetadata)
            installedMetadataIsPrepared = true
        } catch {
            installedMetadataIsPrepared = false
        }
        let installedIsPrepared = installed.map {
            represents(replacementStatus, snapshot: $0) && $0.data == data
                && $0.mode == original.mode && $0.owner == original.owner && $0.group == original.group
                && $0.flags == original.flags && installedMetadataIsPrepared
        } == true
        guard displaced.map({ represents($0, sameFileAs: original) }) == true,
            installedIsPrepared, let installed
        else {
            let rollback = temporary.withCString { temporaryName in
                "contents.xcworkspacedata".withCString {
                    name in renameatx_np(directory, temporaryName, directory, name, UInt32(RENAME_SWAP))
                }
            }
            guard rollback == 0 else {
                throw SwiftPodsError(
                    "Xcode workspace changed during atomic replacement; displaced data was preserved at \(displacedFile.path)",
                    file: file.path)
            }
            renamed = false
            let prepared = try? readWorkspace(at: directory, name: temporary, file: displacedFile)
            var preservedRecovery = true
            if prepared.map({ represents(replacementStatus, snapshot: $0) && $0.data == data }) == true {
                preservedRecovery = temporary.withCString { unlinkat(directory, $0, 0) } != 0
            }
            renamed = true
            throw SwiftPodsError(
                preservedRecovery
                    ? "Xcode workspace changed during atomic replacement; concurrent data was preserved at \(displacedFile.path)"
                    : "Xcode workspace changed during atomic replacement; no changes were written",
                file: file.path)
        }
        guard temporary.withCString({ unlinkat(directory, $0, 0) }) == 0 else {
            throw SwiftPodsError(
                "Workspace was updated, but its previous inode could not be removed: \(String(cString: strerror(errno)))",
                file: displacedFile.path)
        }
        guard fsync(directory) == 0 else {
            throw SwiftPodsError(
                "Cannot flush the Xcode workspace directory: \(String(cString: strerror(errno)))",
                file: file.deletingLastPathComponent().path)
        }
        return installed
    }
}
