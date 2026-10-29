import Foundation

/// Normalizes framework slices that CocoaPods tolerated but Xcode embeds incorrectly, in SwiftPods' own copy.
///
/// Xcode embeds every framework of a binary target and decides by the binary whether it is static. A static
/// archive wrapped in a single-architecture universal binary is taken for a dynamic library; a macOS-style
/// versioned bundle or a missing Info.plist makes an iOS app bundle invalid. CocoaPods never embedded static
/// frameworks, so SDKs shipped like that worked there.
enum FrameworkRepair {
    /// Repairs the iOS-family slices of an `.xcframework`; returns one note per repair.
    static func repair(xcframework: URL, minimumOS: String?) throws -> [String] {
        guard let info = NSDictionary(contentsOf: xcframework.appendingPathComponent("Info.plist")),
            let libraries = info["AvailableLibraries"] as? [[String: Any]]
        else { return [] }
        var notes: [String] = []
        for library in libraries {
            guard let identifier = library["LibraryIdentifier"] as? String, let path = library["LibraryPath"] as? String,
                path.hasSuffix(".framework"), library["SupportedPlatform"] as? String != "macos",
                library["SupportedPlatformVariant"] as? String != "maccatalyst"
            else { continue }
            let framework = xcframework.appendingPathComponent(identifier).appendingPathComponent(path)
            let name = framework.deletingPathExtension().lastPathComponent
            let label = "\(xcframework.lastPathComponent)/\(identifier)/\(path)"
            if try flatten(framework) { notes.append("\(label): moved the versioned bundle contents to the top level") }
            if try thin(framework.appendingPathComponent(name)) {
                notes.append("\(label): unwrapped a single-architecture universal static library")
            }
            if try addInfoPlist(framework, name: name, minimumOS: minimumOS) { notes.append("\(label): added a minimal Info.plist") }
        }
        return notes
    }

    /// Replaces `Versions/Current` symlinks with the real contents; iOS bundles are shallow.
    private static func flatten(_ framework: URL) throws -> Bool {
        let fileManager = FileManager.default
        let current = framework.appendingPathComponent("Versions/Current")
        guard fileManager.fileExists(atPath: current.path) else { return false }
        let contents = current.resolvingSymlinksInPath()
        for item in try fileManager.contentsOfDirectory(atPath: contents.path) {
            let destination = framework.appendingPathComponent(item)
            // Does not follow symbolic links, so the link itself is replaced.
            if (try? fileManager.attributesOfItem(atPath: destination.path)) != nil { try fileManager.removeItem(at: destination) }
            try fileManager.moveItem(at: contents.appendingPathComponent(item), to: destination)
        }
        try fileManager.removeItem(at: framework.appendingPathComponent("Versions"))
        return true
    }

    /// Extracts the only architecture of a universal binary when it is a static archive.
    private static func thin(_ binary: URL) throws -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: binary) else { return false }
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
        try handle.seek(toOffset: offset)
        guard try handle.read(upToCount: 8) == Data("!<arch>\n".utf8) else { return false }
        try handle.seek(toOffset: offset)
        let temporary = binary.appendingPathExtension("thin")
        FileManager.default.createFile(atPath: temporary.path, contents: nil)
        let output = try FileHandle(forWritingTo: temporary)
        var remaining = size
        while remaining > 0 {
            let count = Int(min(remaining, 1 << 20))
            try autoreleasepool {
                guard let chunk = try handle.read(upToCount: count), !chunk.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
                try output.write(contentsOf: chunk)
                remaining -= UInt64(chunk.count)
            }
        }
        try output.close()
        _ = try FileManager.default.replaceItemAt(binary, withItemAt: temporary)
        return true
    }

    private static func addInfoPlist(_ framework: URL, name: String, minimumOS: String?) throws -> Bool {
        let file = framework.appendingPathComponent("Info.plist")
        guard !FileManager.default.fileExists(atPath: file.path) else { return false }
        let identifier = "org.swiftpods.binary." + name.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." }
        let plist: [String: Any] = [
            "CFBundleDevelopmentRegion": "en", "CFBundleExecutable": name, "CFBundleIdentifier": identifier,
            "CFBundleInfoDictionaryVersion": "6.0", "CFBundleName": name, "CFBundlePackageType": "FMWK",
            "CFBundleShortVersionString": "1.0", "CFBundleVersion": "1", "MinimumOSVersion": minimumOS ?? "12.0",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: file)
        return true
    }
}
