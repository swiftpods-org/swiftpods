import Foundation
import SwiftPodsManifest

/// Normalizes framework slices that CocoaPods tolerated but Xcode embeds incorrectly, in SwiftPods' own copy.
///
/// Xcode embeds every framework of a binary target and decides by the binary whether it is static. A static
/// archive wrapped in a single-architecture universal binary is taken for a dynamic library; a macOS-style
/// versioned bundle or a missing Info.plist makes an iOS app bundle invalid. CocoaPods never embedded static
/// frameworks, so SDKs shipped like that worked there.
///
/// A signed XCFramework is never modified: Xcode verifies its signature, and any repair would invalidate it.
enum FrameworkRepair {
    struct Library {
        let identifier: String
        let path: String
        let platform: String
        let platformVariant: String?
    }

    /// Repairs the iOS-family slices of an `.xcframework`; returns one note per repair, or per needed repair
    /// it left out because the XCFramework is signed.
    static func repair(xcframework: URL, deploymentTargets: [PlatformName: String]) throws -> [String] {
        let signed = FileTree.exists(xcframework.appendingPathComponent("_CodeSignature"))
        var notes: [String] = []
        for library in try libraries(of: xcframework) {
            guard library.path.hasSuffix(".framework"), library.platform != "macos", library.platformVariant != "maccatalyst" else {
                continue
            }
            let framework = xcframework.appendingPathComponent(library.identifier).appendingPathComponent(library.path)
            guard FileTree.isDirectory(framework) else {
                throw SwiftPodsError("\(xcframework.lastPathComponent) declares \(library.identifier)/\(library.path), which is missing")
            }
            let name = framework.deletingPathExtension().lastPathComponent
            let label = "\(xcframework.lastPathComponent)/\(library.identifier)/\(library.path)"
            let binary = framework.appendingPathComponent(name)
            let versioned = isVersioned(framework)
            let universal = try singleArchitectureStaticArchive(binary) != nil
            if signed {
                if versioned { notes.append("\(label) is a versioned bundle, but its XCFramework is signed and was left unmodified") }
                if universal {
                    notes.append("\(label) wraps a static library in a universal binary, but its XCFramework is signed and was left unmodified")
                }
                if !versioned, !FileTree.exists(framework.appendingPathComponent("Info.plist")) {
                    notes.append("\(label) has no Info.plist, but its XCFramework is signed and was left unmodified")
                }
                continue
            }
            if versioned {
                try flatten(framework)
                notes.append("\(label): moved the versioned bundle contents to the top level")
            }
            if universal {
                try thin(binary)
                notes.append("\(label): unwrapped a single-architecture universal static library")
            }
            if try addInfoPlist(framework, name: name, minimumOS: deploymentTargets[platform(library.platform)]) {
                notes.append("\(label): added a minimal Info.plist")
            }
        }
        return notes
    }

    static func libraries(of xcframework: URL) throws -> [Library] {
        let file = xcframework.appendingPathComponent("Info.plist")
        guard FileTree.exists(file) else { return [] }
        let data = try Data(contentsOf: file)
        guard let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let entries = info["AvailableLibraries"] as? [[String: Any]]
        else { return [] }
        return try entries.compactMap { entry in
            guard let identifier = entry["LibraryIdentifier"] as? String, let path = entry["LibraryPath"] as? String,
                let platform = entry["SupportedPlatform"] as? String
            else { return nil }
            // The XCFramework comes from the network: its paths must stay inside it.
            let components = (identifier + "/" + path).split(separator: "/", omittingEmptySubsequences: false)
            guard !identifier.contains("/"), !path.hasPrefix("/"), components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
                throw SwiftPodsError("\(xcframework.lastPathComponent) declares a library outside the XCFramework")
            }
            return Library(
                identifier: identifier, path: path, platform: platform,
                platformVariant: entry["SupportedPlatformVariant"] as? String)
        }
    }

    private static func platform(_ supportedPlatform: String) -> PlatformName {
        switch supportedPlatform {
        case "tvos": .tvos
        case "watchos": .watchos
        case "xros": .visionos
        default: .ios
        }
    }

    private static func isVersioned(_ framework: URL) -> Bool {
        FileTree.isDirectory(framework.appendingPathComponent("Versions"))
            && FileTree.exists(framework.appendingPathComponent("Versions/Current"))
    }

    /// Replaces `Versions/Current` symbolic links with the real contents, as iOS bundles are shallow. The bundle's
    /// own Info.plist moves from `Resources/` to the top level, where iOS looks for it.
    private static func flatten(_ framework: URL) throws {
        let fileManager = FileManager.default
        let versions = framework.appendingPathComponent("Versions", isDirectory: true)
        let current = versions.appendingPathComponent("Current").resolvingSymlinksInPath()
        guard current.path.hasPrefix(versions.resolvingSymlinksInPath().path + "/"), FileTree.isDirectory(current) else {
            throw SwiftPodsError("Versions/Current points outside \(framework.lastPathComponent)")
        }
        for item in try fileManager.contentsOfDirectory(atPath: current.path) {
            let destination = framework.appendingPathComponent(item)
            if FileTree.exists(destination) { try fileManager.removeItem(at: destination) }
            try fileManager.moveItem(at: current.appendingPathComponent(item), to: destination)
        }
        try fileManager.removeItem(at: versions)
        let info = framework.appendingPathComponent("Info.plist")
        let resourcesInfo = framework.appendingPathComponent("Resources/Info.plist")
        if !FileTree.exists(info), FileTree.exists(resourcesInfo) {
            try fileManager.moveItem(at: resourcesInfo, to: info)
        }
    }

    /// The offset and size of the only slice of a universal binary when that slice is a static archive.
    private static func singleArchitectureStaticArchive(_ binary: URL) throws -> (offset: UInt64, size: UInt64)? {
        guard let handle = try? FileHandle(forReadingFrom: binary) else { return nil }
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 48) ?? Data()
        func number(_ offset: Int, _ width: Int) -> UInt64 {
            header[offset..<offset + width].reduce(0) { $0 << 8 | UInt64($1) }
        }
        guard header.count >= 48, number(4, 4) == 1 else { return nil }
        let slice: (offset: UInt64, size: UInt64)
        switch number(0, 4) {
        case 0xCAFE_BABE: slice = (number(16, 4), number(20, 4))
        case 0xCAFE_BABF: slice = (number(16, 8), number(24, 8))
        default: return nil
        }
        try handle.seek(toOffset: slice.offset)
        return try handle.read(upToCount: 8) == Data("!<arch>\n".utf8) ? slice : nil
    }

    /// Extracts the only architecture of a universal binary when it is a static archive.
    private static func thin(_ binary: URL) throws {
        guard let slice = try singleArchitectureStaticArchive(binary) else { return }
        let input = try FileHandle(forReadingFrom: binary)
        defer { try? input.close() }
        try input.seek(toOffset: slice.offset)
        guard let data = try input.read(upToCount: Int(slice.size)), data.count == Int(slice.size) else {
            throw SwiftPodsError("Malformed universal binary slice in \(binary.path)")
        }
        try FileTree.replace(binary, with: data)
    }

    private static func addInfoPlist(_ framework: URL, name: String, minimumOS: String?) throws -> Bool {
        let file = framework.appendingPathComponent("Info.plist")
        guard !FileTree.exists(file) else { return false }
        let identifier = "org.swiftpods.binary." + name.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." }
        let plist: [String: Any] = [
            "CFBundleDevelopmentRegion": "en", "CFBundleExecutable": name, "CFBundleIdentifier": identifier,
            "CFBundleInfoDictionaryVersion": "6.0", "CFBundleName": name, "CFBundlePackageType": "FMWK",
            "CFBundleShortVersionString": "1.0", "CFBundleVersion": "1", "MinimumOSVersion": minimumOS ?? "12.0",
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: file)
        return true
    }
}
