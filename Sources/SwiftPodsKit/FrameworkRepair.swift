import Darwin
import Foundation

struct FrameworkLibraryMetadata: Codable, Equatable {
    let identifier: String
    let path: String
    let platform: String
    let platformVariant: String?
}

/// Normalizes framework slices that CocoaPods tolerated but Xcode embeds incorrectly, in SwiftPods' own copy.
///
/// Xcode embeds every framework of a binary target and decides by the binary whether it is static. A static
/// archive wrapped in a single-architecture universal binary is taken for a dynamic library; a macOS-style
/// versioned bundle or a missing Info.plist makes an iOS app bundle invalid. CocoaPods never embedded static
/// frameworks, so SDKs shipped like that worked there.
enum FrameworkRepair {
    static let maximumInfoPlistBytes = 8 * 1_024 * 1_024
    private static let maximumInfoPlistObjects = 4_096
    private static let maximumInfoPlistDepth = 32
    private static let maximumInfoPlistDecodedBytes = 8 * 1_024 * 1_024
    private static let maximumLibraries = 128
    private static let maximumMetadataStringBytes = 1_024
    private static let maximumLibraryMetadataBytes = 64 * 1_024

    /// Repairs the iOS-family slices of an `.xcframework`; returns one note per repair.
    static func repair(xcframework: URL, minimumOS: String?) throws -> [String] {
        let root = try SecureFileTree.resolvedDirectory(xcframework, allowRootSymlink: false)
        let infoFile = root.appendingPathComponent("Info.plist")
        guard SecureFileTree.existsNoFollow(infoFile) else { return [] }
        let libraries = try withInfoPlistDescriptor(infoFile) {
            try BinaryStore.frameworkLibraries(fromInfoPlistDescriptor: $0)
        }
        var notes: [String] = []
        for library in libraries {
            let identifier = library.identifier
            let path = library.path
            guard path.hasSuffix(".framework"), library.platform != "macos",
                library.platformVariant != "maccatalyst"
            else { continue }
            guard safeComponent(identifier), safeRelativePath(path) else {
                throw SwiftPodsError("XCFramework contains an unsafe library identifier or path")
            }
            let declared = root.appendingPathComponent(identifier).appendingPathComponent(path).standardizedFileURL
            guard SecureFileTree.contains(declared, in: root), SecureFileTree.existsNoFollow(declared) else {
                throw SwiftPodsError("XCFramework declares a library that is outside its bundle or missing")
            }
            let framework = try SecureFileTree.resolvedDirectory(declared, allowRootSymlink: false)
            guard SecureFileTree.contains(framework, in: root) else {
                throw SwiftPodsError("XCFramework library escapes its bundle")
            }
            let name = framework.deletingPathExtension().lastPathComponent
            let label = "\(safeDiagnostic(xcframework.lastPathComponent))/\(identifier)/\(path)"
            if try flatten(framework) { notes.append("\(label): moved the versioned bundle contents to the top level") }
            if try thin(framework.appendingPathComponent(name)) {
                notes.append("\(label): unwrapped a single-architecture universal static library")
            }
            if try addInfoPlist(framework, name: name, minimumOS: minimumOS) { notes.append("\(label): added a minimal Info.plist") }
        }
        return notes
    }

    private static func withInfoPlistDescriptor<Result>(
        _ file: URL, _ operation: (Int32) throws -> Result
    ) throws -> Result {
        let descriptor = file.path.withCString { open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK) }
        guard descriptor >= 0 else {
            throw SwiftPodsError("Cannot safely read XCFramework Info.plist: \(String(cString: strerror(errno)))")
        }
        defer { close(descriptor) }
        var initial = stat()
        guard fstat(descriptor, &initial) == 0, SecureFileTree.isRegularFile(initial),
            initial.st_size >= 0, initial.st_size <= maximumInfoPlistBytes
        else { throw SwiftPodsError("XCFramework Info.plist must be a regular file no larger than 8 MiB") }
        let result = try operation(descriptor)
        var final = stat()
        guard fstat(descriptor, &final) == 0, final.st_dev == initial.st_dev,
            final.st_ino == initial.st_ino, final.st_mode == initial.st_mode,
            final.st_nlink == initial.st_nlink, final.st_size == initial.st_size,
            final.st_mtimespec.tv_sec == initial.st_mtimespec.tv_sec,
            final.st_mtimespec.tv_nsec == initial.st_mtimespec.tv_nsec,
            final.st_ctimespec.tv_sec == initial.st_ctimespec.tv_sec,
            final.st_ctimespec.tv_nsec == initial.st_ctimespec.tv_nsec,
            final.st_uid == initial.st_uid, final.st_gid == initial.st_gid
        else { throw SwiftPodsError("XCFramework Info.plist changed while it was being read") }
        return result
    }

    /// Runs only in the resource-limited, syscall-sandboxed metadata worker. Foundation may temporarily allocate well
    /// beyond the encoded plist size, so the main install process never deserializes attacker-controlled plist graphs.
    static func decodeInfoPlist(descriptor: Int32) throws -> [FrameworkLibraryMetadata] {
        var initial = stat()
        guard fstat(descriptor, &initial) == 0, SecureFileTree.isRegularFile(initial), initial.st_size >= 0,
            initial.st_size <= maximumInfoPlistBytes,
            fcntl(descriptor, F_GETFL) & O_ACCMODE == O_RDONLY
        else { throw SwiftPodsError("Framework metadata worker received an invalid Info.plist") }
        var data = Data(count: Int(initial.st_size))
        var offset = 0
        try data.withUnsafeMutableBytes { bytes in
            while offset < bytes.count {
                let count = pread(
                    descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, off_t(offset))
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw SwiftPodsError("XCFramework Info.plist was truncated while being read") }
                offset += count
            }
        }
        var extra = UInt8()
        var extraCount: Int
        repeat { extraCount = pread(descriptor, &extra, 1, initial.st_size) } while extraCount < 0 && errno == EINTR
        var final = stat()
        guard extraCount == 0, fstat(descriptor, &final) == 0, sameSnapshot(initial, final) else {
            throw SwiftPodsError("XCFramework Info.plist changed while it was decoded")
        }

        let propertyList: Any
        do {
            propertyList = try PropertyListSerialization.propertyList(from: data, format: nil)
        } catch {
            return []
        }
        var budget = DecodedPlistBudget()
        try validateDecodedPropertyList(propertyList, depth: 0, budget: &budget)
        guard let info = propertyList as? [String: Any],
            let rawLibraries = info["AvailableLibraries"] as? [[String: Any]]
        else { return [] }
        guard rawLibraries.count <= maximumLibraries else {
            throw SwiftPodsError("XCFramework Info.plist declares too many libraries")
        }

        var metadataBytes = 0
        return try rawLibraries.compactMap { library in
            guard let identifier = library["LibraryIdentifier"] as? String,
                let path = library["LibraryPath"] as? String,
                let platform = library["SupportedPlatform"] as? String
            else { return nil }
            let variant = library["SupportedPlatformVariant"] as? String
            let values = [identifier, path, platform] + (variant.map { [$0] } ?? [])
            guard values.allSatisfy({ $0.utf8.count <= maximumMetadataStringBytes }) else {
                throw SwiftPodsError("XCFramework Info.plist contains oversized library metadata")
            }
            for value in values {
                let next = metadataBytes.addingReportingOverflow(value.utf8.count)
                guard !next.overflow, next.partialValue <= maximumLibraryMetadataBytes else {
                    throw SwiftPodsError("XCFramework Info.plist library metadata exceeds its limit")
                }
                metadataBytes = next.partialValue
            }
            return FrameworkLibraryMetadata(
                identifier: identifier, path: path, platform: platform, platformVariant: variant)
        }
    }

    private struct DecodedPlistBudget {
        var objects = 0
        var bytes = 0
    }

    private static func validateDecodedPropertyList(
        _ value: Any, depth: Int, budget: inout DecodedPlistBudget
    ) throws {
        guard depth <= maximumInfoPlistDepth else {
            throw SwiftPodsError("XCFramework Info.plist is nested too deeply")
        }
        budget.objects += 1
        guard budget.objects <= maximumInfoPlistObjects else {
            throw SwiftPodsError("XCFramework Info.plist contains too many objects")
        }
        func consume(_ count: Int) throws {
            let next = budget.bytes.addingReportingOverflow(count)
            guard count >= 0, !next.overflow, next.partialValue <= maximumInfoPlistDecodedBytes else {
                throw SwiftPodsError("XCFramework Info.plist decoded data exceeds its limit")
            }
            budget.bytes = next.partialValue
        }
        switch value {
        case let text as String:
            try consume(text.utf8.count)
        case let data as Data:
            try consume(data.count)
        case is NSNumber, is Date:
            try consume(32)
        case let array as [Any]:
            try consume(array.count * 16)
            for item in array {
                try validateDecodedPropertyList(item, depth: depth + 1, budget: &budget)
            }
        case let dictionary as [String: Any]:
            try consume(dictionary.count * 32)
            for (key, item) in dictionary {
                try consume(key.utf8.count)
                try validateDecodedPropertyList(item, depth: depth + 1, budget: &budget)
            }
        default:
            throw SwiftPodsError("XCFramework Info.plist contains an unsupported value")
        }
    }

    private static func sameSnapshot(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_mode == rhs.st_mode
            && lhs.st_uid == rhs.st_uid && lhs.st_gid == rhs.st_gid && lhs.st_nlink == rhs.st_nlink
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    /// Replaces `Versions/Current` symlinks with the real contents; iOS bundles are shallow.
    private static func flatten(_ framework: URL) throws -> Bool {
        let fileManager = FileManager.default
        let versions = framework.appendingPathComponent("Versions", isDirectory: true)
        guard SecureFileTree.existsNoFollow(versions) else { return false }
        let versionStatus = try SecureFileTree.statusNoFollow(versions)
        guard SecureFileTree.isDirectory(versionStatus), !SecureFileTree.isSymbolicLink(versionStatus) else {
            throw SwiftPodsError("Unsafe versioned framework directory: \(versions.path)")
        }
        let current = versions.appendingPathComponent("Current")
        guard SecureFileTree.existsNoFollow(current) else { return false }
        let contents = try SecureFileTree.realURL(current)
        guard SecureFileTree.contains(contents, in: versions),
            SecureFileTree.isDirectory(try SecureFileTree.statusNoFollow(contents))
        else { throw SwiftPodsError("Versions/Current escapes \(framework.lastPathComponent)") }
        for item in try fileManager.contentsOfDirectory(atPath: contents.path) {
            let destination = framework.appendingPathComponent(item)
            // Does not follow symbolic links, so the link itself is replaced.
            if SecureFileTree.existsNoFollow(destination) { try fileManager.removeItem(at: destination) }
            try fileManager.moveItem(at: contents.appendingPathComponent(item), to: destination)
        }
        try fileManager.removeItem(at: versions)
        return true
    }

    /// Extracts the only architecture of a universal binary when it is a static archive.
    private static func thin(_ binary: URL) throws -> Bool {
        let descriptor = binary.path.withCString { open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK) }
        guard descriptor >= 0 else { return false }
        var original = stat()
        guard fstat(descriptor, &original) == 0, SecureFileTree.isRegularFile(original) else {
            close(descriptor)
            return false
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 48) ?? Data()
        func uint32(_ offset: Int) -> UInt64 {
            header[offset..<offset + 4].reduce(0) { $0 << 8 | UInt64($1) }
        }
        func uint64(_ offset: Int) -> UInt64 {
            header[offset..<offset + 8].reduce(0) { $0 << 8 | UInt64($1) }
        }
        guard header.count >= 48, uint32(4) == 1 else { return false }
        let offset: UInt64
        let size: UInt64
        switch uint32(0) {
        case 0xCAFE_BABE: (offset, size) = (uint32(16), uint32(20))
        case 0xCAFE_BABF: (offset, size) = (uint64(16), uint64(24))
        default: return false
        }
        guard original.st_size >= 0, size >= 8, offset <= UInt64(original.st_size),
            size <= UInt64(original.st_size) - offset
        else {
            throw SwiftPodsError("Malformed universal binary slice in \(binary.path)")
        }
        try handle.seek(toOffset: offset)
        guard try handle.read(upToCount: 8) == Data("!<arch>\n".utf8) else { return false }
        try handle.seek(toOffset: offset)
        var template = Array(binary.deletingLastPathComponent()
            .appendingPathComponent(".\(binary.lastPathComponent).thin.XXXXXX").path.utf8CString)
        let outputDescriptor = mkostemp(&template, O_CLOEXEC)
        guard outputDescriptor >= 0 else {
            throw SwiftPodsError("Cannot create a private temporary file for \(binary.path): \(String(cString: strerror(errno)))")
        }
        guard fchmod(outputDescriptor, original.st_mode & 0o777) == 0 else {
            close(outputDescriptor)
            throw SwiftPodsError("Cannot set permissions on a private temporary file for \(binary.path): \(String(cString: strerror(errno)))")
        }
        let end = template.firstIndex(of: 0) ?? template.endIndex
        let temporaryPath = String(decoding: template[..<end].map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let temporary = URL(fileURLWithPath: temporaryPath)
        let output = FileHandle(fileDescriptor: outputDescriptor, closeOnDealloc: true)
        var keepTemporary = true
        defer {
            try? output.close()
            if keepTemporary { try? FileManager.default.removeItem(at: temporary) }
        }
        var remaining = size
        while remaining > 0 {
            let count = Int(min(remaining, 1 << 20))
            try autoreleasepool {
                guard let chunk = try handle.read(upToCount: count), !chunk.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
                try output.write(contentsOf: chunk)
                remaining -= UInt64(chunk.count)
            }
        }
        var final = stat()
        guard fstat(descriptor, &final) == 0, final.st_dev == original.st_dev,
            final.st_ino == original.st_ino, final.st_mode == original.st_mode,
            final.st_nlink == original.st_nlink, final.st_size == original.st_size,
            final.st_mtimespec.tv_sec == original.st_mtimespec.tv_sec,
            final.st_mtimespec.tv_nsec == original.st_mtimespec.tv_nsec,
            final.st_ctimespec.tv_sec == original.st_ctimespec.tv_sec,
            final.st_ctimespec.tv_nsec == original.st_ctimespec.tv_nsec
        else { throw SwiftPodsError("Framework binary changed while it was being repaired: \(binary.path)") }
        var outputStatus = stat()
        guard fstat(outputDescriptor, &outputStatus) == 0, SecureFileTree.isRegularFile(outputStatus),
            outputStatus.st_nlink == 1, outputStatus.st_size >= 0, UInt64(outputStatus.st_size) == size
        else { throw SwiftPodsError("Thinned framework binary has an unexpected size") }
        try output.close()
        guard rename(temporary.path, binary.path) == 0 else {
            throw SwiftPodsError("Cannot replace \(binary.path): \(String(cString: strerror(errno)))")
        }
        keepTemporary = false
        return true
    }

    private static func addInfoPlist(_ framework: URL, name: String, minimumOS: String?) throws -> Bool {
        let file = framework.appendingPathComponent("Info.plist")
        if SecureFileTree.existsNoFollow(file) {
            let status = try SecureFileTree.statusNoFollow(file)
            guard SecureFileTree.isRegularFile(status) else { throw SwiftPodsError("Unsafe framework Info.plist at \(file.path)") }
            return false
        }
        let identifier = "org.swiftpods.binary." + name.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." }
        let plist: [String: Any] = [
            "CFBundleDevelopmentRegion": "en", "CFBundleExecutable": name, "CFBundleIdentifier": identifier,
            "CFBundleInfoDictionaryVersion": "6.0", "CFBundleName": name, "CFBundlePackageType": "FMWK",
            "CFBundleShortVersionString": "1.0", "CFBundleVersion": "1", "MinimumOSVersion": minimumOS ?? "12.0",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: file, options: .withoutOverwriting)
        return true
    }

    private static func safeComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/")
            && value.utf8.count <= Int(NAME_MAX) && safeDiagnosticScalars(value)
    }

    private static func safeRelativePath(_ value: String) -> Bool {
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        return !value.hasPrefix("/") && value.utf8.count < Int(PATH_MAX) && components.count <= 32
            && safeDiagnosticScalars(value) && components.allSatisfy {
                !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= Int(NAME_MAX)
            }
    }

    private static func safeDiagnosticScalars(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy {
            $0.value >= 0x20 && $0.value != 0x7f && !(0x80...0x9f).contains($0.value)
                && $0.value != 0x2028 && $0.value != 0x2029
        }
    }

    private static func safeDiagnostic(_ value: String) -> String {
        safeDiagnosticScalars(value) && value.utf8.count <= Int(NAME_MAX) ? value : "XCFramework"
    }
}
