import CLibArchive
import CryptoKit
import Darwin
import Foundation

/// Directory trees SwiftPods fingerprints, unpacks and copies.
enum FileTree {
    /// SHA-256 over every entry's relative path, permission bits, kind, size, link target and contents, in path
    /// order. `SwiftPods.lock` records it for package overrides, so changing it invalidates existing locks.
    /// - Parameters:
    ///   - skipped: top-level names left out, such as resolver state, unless their path is listed in `kept`.
    static func digest(
        of directory: URL, skippingTopLevel skipped: Set<String> = [], keeping kept: Set<String> = [],
        validatingLinks: Bool = false
    ) throws -> String {
        let root = directory.standardizedFileURL
        let rootPath = root.path
        guard isDirectory(root) else { throw SwiftPodsError("Cannot read \(rootPath)") }
        let linkRoot = validatingLinks ? try resolvedPath(root) : nil
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil, options: [],
            errorHandler: { _, error in enumerationError = error; return false })
        else { throw SwiftPodsError("Cannot read \(root.path)") }
        var nodes: [(relative: String, url: URL, status: stat)] = []
        for case let url as URL in enumerator {
            let relative = String(url.standardizedFileURL.path.dropFirst(rootPath.count + 1))
            let status = try Self.status(url)
            if let first = relative.split(separator: "/", omittingEmptySubsequences: false).first,
                skipped.contains(String(first)), !kept.contains(relative)
            {
                if status.st_mode & S_IFMT == S_IFDIR { enumerator.skipDescendants() }
                continue
            }
            nodes.append((relative, url, status))
        }
        if let enumerationError { throw SwiftPodsError("Cannot read \(root.path): \(enumerationError)") }
        nodes.sort { $0.relative < $1.relative }

        var hasher = SHA256()
        for node in nodes {
            update(node.relative, into: &hasher)
            let type = node.status.st_mode & S_IFMT
            var mode = UInt64(type == S_IFLNK ? 0 : node.status.st_mode & 0o7777).bigEndian
            withUnsafeBytes(of: &mode) { hasher.update(data: Data($0)) }
            switch type {
            case S_IFDIR:
                update("directory", into: &hasher)
            case S_IFLNK:
                update("symlink", into: &hasher)
                let target = try FileManager.default.destinationOfSymbolicLink(atPath: node.url.path)
                if let linkRoot {
                    try validateLink(node.url, target: target, relative: node.relative, in: linkRoot, excluding: skipped)
                }
                update(target, into: &hasher)
            case S_IFREG:
                update("file", into: &hasher)
                var size = UInt64(node.status.st_size).bigEndian
                withUnsafeBytes(of: &size) { hasher.update(data: Data($0)) }
                let handle = try FileHandle(forReadingFrom: node.url)
                defer { try? handle.close() }
                while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                    hasher.update(data: chunk)
                }
            default:
                throw SwiftPodsError("Unsupported file type at \(node.url.path)")
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func update(_ text: String, into hasher: inout SHA256) {
        let data = Data(text.utf8)
        var length = UInt64(data.count).bigEndian
        withUnsafeBytes(of: &length) { hasher.update(data: Data($0)) }
        hasher.update(data: data)
    }

    static func status(_ url: URL) throws -> stat {
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            throw SwiftPodsError("Cannot inspect \(url.path): \(String(cString: strerror(errno)))")
        }
        return status
    }

    static func exists(_ url: URL) -> Bool {
        var status = stat()
        return lstat(url.path, &status) == 0
    }

    static func isDirectory(_ url: URL) -> Bool {
        var status = stat()
        return lstat(url.path, &status) == 0 && status.st_mode & S_IFMT == S_IFDIR
    }

    /// Atomically replaces a user's file, keeping its permissions.
    static func replace(_ file: URL, with data: Data) throws {
        let permissions = try? FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions]
        try data.write(to: file, options: .atomic)
        if let permissions { try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: file.path) }
    }

    /// Copies a tree without extended attributes, ACLs or flags (Finder metadata breaks code signing), keeping symbolic
    /// links as links and giving files 0644 or 0755 and directories 0755.
    static func copy(_ source: URL, to destination: URL) throws {
        let status = try Self.status(source)
        switch status.st_mode & S_IFMT {
        case S_IFDIR:
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            chmod(destination.path, 0o755)
            for name in try FileManager.default.contentsOfDirectory(atPath: source.path) {
                try copy(source.appendingPathComponent(name), to: destination.appendingPathComponent(name))
            }
        case S_IFLNK:
            try FileManager.default.createSymbolicLink(
                atPath: destination.path, withDestinationPath: FileManager.default.destinationOfSymbolicLink(atPath: source.path))
        case S_IFREG:
            guard copyfile(source.path, destination.path, nil, copyfile_flags_t(COPYFILE_DATA | COPYFILE_EXCL | COPYFILE_NOFOLLOW)) == 0 else {
                throw SwiftPodsError("Cannot copy \(source.path): \(String(cString: strerror(errno)))")
            }
            chmod(destination.path, status.st_mode & 0o111 == 0 ? 0o644 : 0o755)
        default:
            throw SwiftPodsError("Cannot copy special file \(source.path)")
        }
    }

    /// Unpacks a zip or tar archive (optionally gzip, bzip2 or xz compressed) into a new directory.
    ///
    /// Archives come from the network, so entries must stay inside `destination`: absolute paths, `..`, links that
    /// point outside, writing through a link the archive created, hard links to anything but an earlier file, special
    /// files and encrypted entries are rejected. Finder AppleDouble entries (`__MACOSX`, `._*`) are skipped.
    static func unpack(_ archive: URL, into destination: URL) throws {
        guard let reader = archive_read_new() else { throw SwiftPodsError("Cannot read \(archive.lastPathComponent)") }
        defer { archive_read_free(reader) }
        archive_read_support_filter_none(reader)
        archive_read_support_filter_gzip(reader)
        archive_read_support_filter_bzip2(reader)
        archive_read_support_filter_xz(reader)
        archive_read_support_format_tar(reader)
        archive_read_support_format_zip(reader)
        func failure(_ message: String) -> SwiftPodsError {
            let detail = archive_error_string(reader).map { String(cString: $0) }
            return SwiftPodsError(message + (detail.map { ": " + $0 } ?? ""), file: archive.path)
        }
        guard archive_read_open_filename(reader, archive.path, 1 << 16) == ARCHIVE_OK else {
            throw failure("Not a zip or tar archive")
        }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        var kinds: [String: mode_t] = [:]
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            try Interruption.check()
            var entry: OpaquePointer?
            let result = archive_read_next_header(reader, &entry)
            if result == ARCHIVE_EOF { break }
            guard result == ARCHIVE_OK || result == ARCHIVE_WARN, let entry else { throw failure("Cannot read the archive") }
            let format = archive_format(reader) & ARCHIVE_FORMAT_BASE_MASK
            guard format == ARCHIVE_FORMAT_TAR || format == ARCHIVE_FORMAT_ZIP else {
                throw failure("Not a zip or tar archive")
            }
            guard archive_entry_is_encrypted(entry) == 0 else { throw failure("Encrypted archives are not supported") }
            guard let rawPath = archive_entry_pathname_utf8(entry) else { throw failure("An archive path is not UTF-8") }
            let components = try archivePath(String(cString: rawPath), archive: archive)
            if components.isEmpty || components.contains(where: { $0 == "__MACOSX" || $0.hasPrefix("._") }) {
                archive_read_data_skip(reader)
                continue
            }
            let relative = components.joined(separator: "/")
            guard parentsAreDirectories(components, in: destination) else {
                throw SwiftPodsError("Archive entry has a parent that is not a directory: \(relative)", file: archive.path)
            }
            let target = destination.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let existing = exists(target) ? try status(target).st_mode & S_IFMT : nil
            if let existing, existing != S_IFDIR {
                guard kinds[relative] == existing, unlink(target.path) == 0 else {
                    throw SwiftPodsError("Archive cannot replace entry \(relative)", file: archive.path)
                }
            }

            let executable = archive_entry_perm(entry) & 0o111 != 0
            if let hardlink = archive_entry_hardlink_utf8(entry) {
                let sourceComponents = try archivePath(String(cString: hardlink), archive: archive)
                let source = sourceComponents.joined(separator: "/")
                guard parentsAreDirectories(sourceComponents, in: destination) else {
                    throw SwiftPodsError("Archive entry has a parent that is not a directory: \(source)", file: archive.path)
                }
                let sourceFile = destination.appendingPathComponent(source)
                guard kinds[source] == S_IFREG, existing != S_IFDIR,
                    try status(sourceFile).st_mode & S_IFMT == S_IFREG, link(sourceFile.path, target.path) == 0
                else { throw SwiftPodsError("Archive hard link \(relative) does not name an earlier file", file: archive.path) }
                kinds[relative] = S_IFREG
                continue
            }
            switch archive_entry_filetype(entry) {
            case S_IFDIR:
                guard existing == nil || existing == S_IFDIR else {
                    throw SwiftPodsError("Archive entry \(relative) is both a directory and a file", file: archive.path)
                }
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                chmod(target.path, 0o755)
                kinds[relative] = S_IFDIR
            case S_IFREG:
                guard existing != S_IFDIR else {
                    throw SwiftPodsError("Archive entry \(relative) is both a directory and a file", file: archive.path)
                }
                let descriptor = open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, executable ? 0o755 : 0o644)
                guard descriptor >= 0 else {
                    throw SwiftPodsError("Cannot write \(target.path): \(String(cString: strerror(errno)))")
                }
                defer { close(descriptor) }
                while true {
                    let count = archive_read_data(reader, &buffer, buffer.count)
                    if count == 0 { break }
                    guard count > 0 else { throw failure("Cannot read \(relative)") }
                    guard buffer.withUnsafeBytes({ write(descriptor, $0.baseAddress, count) }) == count else {
                        throw SwiftPodsError("Cannot write \(target.path): \(String(cString: strerror(errno)))")
                    }
                }
                fchmod(descriptor, executable ? 0o755 : 0o644)
                kinds[relative] = S_IFREG
            case S_IFLNK:
                guard let raw = archive_entry_symlink_utf8(entry), existing != S_IFDIR else {
                    throw failure("Archive symbolic link \(relative) has no target")
                }
                let link = String(cString: raw)
                guard staysInside(link, from: components) else {
                    throw SwiftPodsError("Archive symbolic link points outside the archive: \(relative) -> \(link)", file: archive.path)
                }
                try FileManager.default.createSymbolicLink(atPath: target.path, withDestinationPath: link)
                kinds[relative] = S_IFLNK
            default:
                throw SwiftPodsError("Archive contains a special file: \(relative)", file: archive.path)
            }
        }
        try validateLinks(in: destination)
    }

    /// Whether every parent of `components` that already exists under `root` is a real directory, not a link or a
    /// file. The file system looks the names up, so it also finds an entry whose name differs only in a way it
    /// ignores, such as case or Unicode normalization, which no comparison of the names themselves matches exactly.
    static func parentsAreDirectories(_ components: [String], in root: URL) -> Bool {
        var parent = root
        for component in components.dropLast() {
            parent.appendPathComponent(component)
            if !exists(parent) { return true }
            guard isDirectory(parent) else { return false }
        }
        return true
    }

    /// Creates a new file, never following a link or replacing an existing entry.
    static func create(_ file: URL, contents: Data, executable: Bool) throws {
        let mode: mode_t = executable ? 0o755 : 0o644
        let descriptor = open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        guard descriptor >= 0 else { throw SwiftPodsError("Cannot create \(file.path): \(String(cString: strerror(errno)))") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        fchmod(descriptor, mode)
        try handle.write(contentsOf: contents)
        try handle.close()
    }

    /// Checks links in a complete extraction, once each link's target is available.
    static func validateLinks(in directory: URL) throws {
        let root = try resolvedPath(directory)
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [],
            errorHandler: { _, error in enumerationError = error; return false })
        else { throw SwiftPodsError("Cannot read \(directory.path)") }
        for case let url as URL in enumerator {
            guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true else { continue }
            let relative = String(url.path.dropFirst(directory.path.count + 1))
            let target = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
            try validateLink(url, target: target, relative: relative, in: root)
        }
        if let enumerationError { throw enumerationError }
    }

    private static func validateLink(
        _ url: URL, target: String, relative: String, in root: String, excluding: Set<String> = []
    ) throws {
        let components = relative.split(separator: "/").map(String.init)
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard staysInside(target, from: components) else { throw SwiftPodsError("Symbolic link escapes its tree at \(relative)") }
        let resolved = try resolvedPath(url)
        guard resolved == root || resolved.hasPrefix(prefix) else {
            throw SwiftPodsError("Symbolic link escapes its tree at \(relative)")
        }
        if let first = resolved.dropFirst(prefix.count).split(separator: "/").first, excluding.contains(first.lowercased()) {
            throw SwiftPodsError("Symbolic link refers to resolver metadata at \(relative)")
        }
    }

    private static func resolvedPath(_ url: URL) throws -> String {
        guard let resolved = url.path.withCString({ realpath($0, nil) }) else {
            throw SwiftPodsError("Cannot resolve \(url.path): \(String(cString: strerror(errno)))")
        }
        defer { free(resolved) }
        guard let path = String(validatingCString: resolved) else { throw SwiftPodsError("Path is not UTF-8: \(url.path)") }
        return path
    }

    /// The components of a relative archive path, without empty and `.` components.
    private static func archivePath(_ path: String, archive: URL) throws -> [String] {
        let components = path.split(separator: "/").map(String.init).filter { $0 != "." }
        guard !path.hasPrefix("/"), !components.contains("..") else {
            throw SwiftPodsError("Archive path leaves the archive: \(path)", file: archive.path)
        }
        return components
    }

    /// Whether a relative link at `components` resolves inside the tree, by its path alone.
    static func staysInside(_ link: String, from components: [String]) -> Bool {
        guard !link.isEmpty, !link.hasPrefix("/") else { return false }
        var depth = components.count - 1
        for part in link.split(separator: "/") where part != "." {
            depth += part == ".." ? -1 : 1
            if depth < 0 { return false }
        }
        return true
    }
}
