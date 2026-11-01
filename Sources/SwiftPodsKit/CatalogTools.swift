import Darwin
import Foundation
import SwiftPodsManifest

/// Commands for working with catalogs rather than projects.
public enum CatalogTools {
    private static let maximumEntryBytes = 1024 * 1024
    private static let maximumAggregateEntryBytes = 64 * 1024 * 1024
    private static let maximumInventoryEntries = 4_096
    private static let maximumInventoryDepth = 32
    private static let maximumEnumerationProblems = 1_024
    private static let maximumSearchSources = 32
    private static let maximumSearchCandidates = 256

    private struct FileIdentity {
        let device: dev_t
        let inode: ino_t
    }

    private struct InventoryFile {
        let components: [String]
        let directories: [FileIdentity]
        let identity: FileIdentity

        var relativePath: String { components.joined(separator: "/") }
    }

    /// Retains the opened `Packages` directory so enumeration and reads stay anchored to one directory inode.
    private final class Inventory {
        let packages: URL
        let descriptor: Int32
        var files: [InventoryFile] = []
        var problems: [String] = []
        private var omittedProblems = false

        init(packages: URL, descriptor: Int32 = -1) {
            self.packages = packages
            self.descriptor = descriptor
        }

        deinit {
            if descriptor >= 0 { close(descriptor) }
        }

        func addProblem(_ problem: String) {
            if problems.count < CatalogTools.maximumEnumerationProblems {
                problems.append(problem)
            } else {
                omittedProblems = true
            }
        }

        func finish() {
            if omittedProblems { problems.append("Additional catalog enumeration errors were omitted") }
            files.sort { $0.relativePath < $1.relativePath }
            problems.sort()
        }
    }

    private struct DirectoryNames {
        var valid: [String] = []
        var invalidUTF8 = 0
    }

    private static func names(in descriptor: Int32, maximum: Int) throws -> DirectoryNames {
        let duplicate = openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard duplicate >= 0, let directory = fdopendir(duplicate) else {
            if duplicate >= 0 { close(duplicate) }
            throw SwiftPodsError("Cannot enumerate catalog directory: \(String(cString: strerror(errno)))")
        }
        defer { closedir(directory) }
        var result = DirectoryNames()
        errno = 0
        while result.valid.count + result.invalidUTF8 < maximum, let entry = readdir(directory) {
            var bytes = entry.pointee.d_name
            let name = withUnsafeBytes(of: &bytes) { raw -> String? in
                guard let base = raw.baseAddress else { return nil }
                return String(validatingCString: base.assumingMemoryBound(to: CChar.self))
            }
            guard let name else {
                result.invalidUTF8 += 1
                errno = 0
                continue
            }
            if name != "." && name != ".." { result.valid.append(name) }
            errno = 0
        }
        guard result.valid.count + result.invalidUTF8 == maximum || errno == 0 else {
            throw SwiftPodsError("Cannot enumerate catalog directory: \(String(cString: strerror(errno)))")
        }
        result.valid.sort()
        return result
    }

    private static func isSafeCatalogComponent(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 4_096 && !name.contains("/") && !name.contains("\\")
            && !name.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f }
    }

    @discardableResult
    private static func enumerate(
        _ descriptor: Int32, components: [String], directories: [FileIdentity],
        inventory: Inventory, entryCount: inout Int
    ) -> Bool {
        let remaining = max(maximumInventoryEntries - entryCount, 0)
        let directoryNames: DirectoryNames
        do {
            directoryNames = try names(in: descriptor, maximum: remaining + 1)
        } catch {
            let label = components.isEmpty ? "Packages" : components.joined(separator: "/")
            inventory.addProblem("\(label): cannot enumerate: \(error)")
            return true
        }
        for _ in 0..<directoryNames.invalidUTF8 {
            entryCount += 1
            guard entryCount <= maximumInventoryEntries else {
                inventory.addProblem("Packages contains more than \(maximumInventoryEntries) entries; catalog lint stopped")
                return false
            }
            inventory.addProblem("Packages contains an entry whose name is not valid UTF-8")
        }
        for name in directoryNames.valid {
            entryCount += 1
            guard entryCount <= maximumInventoryEntries else {
                inventory.addProblem("Packages contains more than \(maximumInventoryEntries) entries; catalog lint stopped")
                return false
            }
            guard isSafeCatalogComponent(name) else {
                inventory.addProblem(
                    "Packages contains a catalog entry name with controls, backslashes, or more than 4096 bytes")
                continue
            }
            let childComponents = components + [name]
            let label = childComponents.joined(separator: "/")
            guard childComponents.count <= maximumInventoryDepth else {
                inventory.addProblem(
                    "\(label): catalog entries cannot be nested more than \(maximumInventoryDepth) levels")
                continue
            }
            var linked = stat()
            guard name.withCString({ fstatat(descriptor, $0, &linked, AT_SYMLINK_NOFOLLOW) }) == 0 else {
                inventory.addProblem("\(label): cannot inspect the catalog entry: \(String(cString: strerror(errno)))")
                continue
            }
            switch linked.st_mode & S_IFMT {
            case S_IFREG:
                inventory.files.append(InventoryFile(
                    components: childComponents, directories: directories,
                    identity: FileIdentity(device: linked.st_dev, inode: linked.st_ino)))
            case S_IFDIR:
                let child = name.withCString {
                    openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
                }
                guard child >= 0 else {
                    inventory.addProblem("\(label): cannot safely open catalog directory: \(String(cString: strerror(errno)))")
                    continue
                }
                var opened = stat()
                guard fstat(child, &opened) == 0, opened.st_mode & S_IFMT == S_IFDIR,
                    opened.st_dev == linked.st_dev, opened.st_ino == linked.st_ino
                else {
                    close(child)
                    inventory.addProblem("\(label): catalog directory changed while it was being opened")
                    continue
                }
                let shouldContinue = enumerate(
                    child, components: childComponents,
                    directories: directories + [FileIdentity(device: opened.st_dev, inode: opened.st_ino)],
                    inventory: inventory, entryCount: &entryCount)
                close(child)
                if !shouldContinue { return false }
            case S_IFLNK:
                inventory.addProblem("\(label): catalog entries cannot be symbolic links")
            default:
                inventory.addProblem("\(label): catalog entries must be regular files")
            }
        }
        return true
    }

    private static func inventory(_ directory: URL) -> Inventory {
        let packages = directory.appendingPathComponent("Packages", isDirectory: true)
        let descriptor = packages.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else {
            let result = Inventory(packages: packages)
            result.addProblem("Packages cannot be inspected: \(String(cString: strerror(errno)))")
            result.finish()
            return result
        }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFDIR else {
            close(descriptor)
            let result = Inventory(packages: packages)
            result.addProblem("Packages must be a regular directory, not a symbolic link or special file")
            result.finish()
            return result
        }
        let result = Inventory(packages: packages, descriptor: descriptor)
        var entryCount = 0
        enumerate(descriptor, components: [], directories: [], inventory: result, entryCount: &entryCount)
        result.finish()
        return result
    }

    private static func fileURL(_ file: InventoryFile, in inventory: Inventory) -> URL {
        file.components.reduce(inventory.packages) { $0.appendingPathComponent($1) }
    }

    private static func entryText(
        _ file: InventoryFile, in inventory: Inventory, remainingAggregateBytes: inout Int
    ) throws -> String {
        let url = fileURL(file, in: inventory)
        guard inventory.descriptor >= 0, !file.components.isEmpty,
            file.directories.count == file.components.count - 1
        else { throw SwiftPodsError("Invalid catalog inventory entry", file: url.path) }
        var openedDirectories: [Int32] = []
        defer { for descriptor in openedDirectories.reversed() { close(descriptor) } }
        var parent = inventory.descriptor
        for (index, component) in file.components.dropLast().enumerated() {
            let descriptor = component.withCString {
                openat(parent, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            }
            guard descriptor >= 0 else {
                throw SwiftPodsError(
                    "Cannot safely open catalog directory: \(String(cString: strerror(errno)))", file: url.path)
            }
            var status = stat()
            let expected = file.directories[index]
            guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFDIR,
                status.st_dev == expected.device, status.st_ino == expected.inode
            else {
                close(descriptor)
                throw SwiftPodsError("Catalog directory changed after enumeration", file: url.path)
            }
            openedDirectories.append(descriptor)
            parent = descriptor
        }
        let name = file.components[file.components.count - 1]
        let descriptor = name.withCString { openat(parent, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK) }
        guard descriptor >= 0 else {
            throw SwiftPodsError("Cannot safely read catalog entry: \(String(cString: strerror(errno)))", file: url.path)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
            status.st_dev == file.identity.device, status.st_ino == file.identity.inode
        else { throw SwiftPodsError("Catalog entry changed after enumeration", file: url.path) }
        guard status.st_size >= 0, status.st_size <= maximumEntryBytes else {
            throw SwiftPodsError("Catalog entry is larger than \(maximumEntryBytes) bytes", file: url.path)
        }
        guard status.st_size <= Int64(remainingAggregateBytes) else {
            remainingAggregateBytes = 0
            throw SwiftPodsError(
                "Catalog entries exceed the \(maximumAggregateEntryBytes)-byte aggregate limit", file: url.path)
        }
        var data = Data()
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            guard chunk.count <= maximumEntryBytes - data.count else {
                throw SwiftPodsError("Catalog entry is larger than \(maximumEntryBytes) bytes", file: url.path)
            }
            guard chunk.count <= remainingAggregateBytes else {
                remainingAggregateBytes = 0
                throw SwiftPodsError(
                    "Catalog entries exceed the \(maximumAggregateEntryBytes)-byte aggregate limit", file: url.path)
            }
            data.append(chunk)
            remainingAggregateBytes -= chunk.count
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
            Int64(data.count) == status.st_size
        else {
            throw SwiftPodsError("Catalog entry changed while it was being read", file: url.path)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw SwiftPodsError("Catalog entry is not valid UTF-8", file: url.path)
        }
        return text
    }

    /// Every file under a catalog's `Packages/` directory, at any depth, sorted by path.
    static func files(_ directory: URL) -> [URL] {
        let inventory = inventory(directory)
        return inventory.files.map { fileURL($0, in: inventory) }
    }

    /// Problems in a catalog checkout: unreadable entries, names that differ from file names, duplicates.
    public static func lint(_ directory: URL) -> [String] {
        let packages = directory.appendingPathComponent("Packages", isDirectory: true)
        guard FileManager.default.fileExists(atPath: packages.path) else { return ["\(packages.path) does not exist"] }
        let inventory = inventory(directory)
        var problems = inventory.problems
        var names: [String: String] = [:]
        var locations: [String: String] = [:]
        var remainingAggregateBytes = maximumAggregateEntryBytes
        for file in inventory.files {
            let label = file.relativePath
            let url = fileURL(file, in: inventory)
            guard url.pathExtension == "podfile" else {
                problems.append("\(label): catalog files end in .podfile")
                continue
            }
            let expected = url.deletingPathExtension().lastPathComponent
            do {
                let entry = try CatalogEntry.parse(
                    try entryText(file, in: inventory, remainingAggregateBytes: &remainingAggregateBytes),
                    file: url.path, source: directory.path)
                if entry.name != expected { problems.append("\(label): declares `\(entry.name)`, expected `\(expected)`") }
                if let other = names[entry.name.lowercased()] {
                    problems.append("\(label): `\(entry.name)` is already declared by \(other)")
                }
                names[entry.name.lowercased()] = label
                if let url = entry.url {
                    let location = PackageLocation.fetchIdentity(url)
                    if let other = locations[location] {
                        problems.append("\(label): \(url) is already declared by \(other)")
                    }
                    locations[location] = label
                }
            } catch let error as ManifestError {
                problems.append(error.description)
            } catch {
                problems.append("\(label): \(error)")
            }
        }
        return problems
    }

    /// Catalog entries whose name contains `text`, case-insensitively.
    public static func search(
        _ text: String, sources: [Source], runner: CommandRunner = ProcessRunner(), cache: URL? = nil, update: Bool = false
    ) throws -> [CatalogEntry] {
        guard isSafeSearchText(text) else {
            throw SwiftPodsError("Catalog search text cannot be empty, contain control characters or exceed 4096 bytes")
        }
        guard sources.count <= maximumSearchSources else {
            throw SwiftPodsError("Catalog search cannot use more than \(maximumSearchSources) sources")
        }
        guard sources.allSatisfy({ PackageLocation.isSafeCatalogSource($0.url) }) else {
            throw SwiftPodsError("Catalog search received an unsafe source URL")
        }
        let catalog = GitCatalog(cache: cache ?? GitCatalog.defaultCache, runner: runner, update: update, offline: false)
        let needle = text.precomposedStringWithCanonicalMapping.lowercased().precomposedStringWithCanonicalMapping
        var candidates: [(source: Source, name: String)] = []
        for source in sources {
            for name in try catalog.names(source) {
                let key = name.precomposedStringWithCanonicalMapping.lowercased().precomposedStringWithCanonicalMapping
                guard key.contains(needle) else { continue }
                guard candidates.count < maximumSearchCandidates else {
                    throw SwiftPodsError(
                        "Catalog search matches more than \(maximumSearchCandidates) packages",
                        hint: "Use a more specific search term")
                }
                candidates.append((source, name))
            }
        }
        // Count every candidate before reading any blob. A broad query against an untrusted catalog therefore cannot
        // start an unbounded sequence of `git cat-file` processes and entry parses before the cap is discovered.
        var result: [CatalogEntry] = []
        result.reserveCapacity(candidates.count)
        for candidate in candidates {
            if let entry = try catalog.entry(named: candidate.name, in: [candidate.source]) { result.append(entry) }
        }
        return result
    }

    private static func isSafeSearchText(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.count <= 4_096 && !text.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0)
        }
    }
}
