import Foundation
import SwiftPodsManifest

/// The local Swift package that exposes the Podfile's binaries as products.
struct BinaryPackage {
    static let directoryName = "SwiftPodsBinaries"

    struct Entry {
        let binary: Binary
        let xcframeworks: [URL]
        let resources: [URL]
        let xcframeworkPaths: [String]
        let resourcePaths: [String]
        /// Retains an owned private snapshot until rendering has copied and authenticated every selected artifact.
        let snapshotLease: BinaryStore.SnapshotLease?

        init(
            binary: Binary, xcframeworks: [URL], resources: [URL],
            xcframeworkPaths: [String]? = nil, resourcePaths: [String]? = nil,
            snapshotLease: BinaryStore.SnapshotLease? = nil
        ) {
            self.binary = binary
            self.xcframeworks = xcframeworks
            self.resources = resources
            self.xcframeworkPaths = xcframeworkPaths ?? xcframeworks.map(\.lastPathComponent)
            self.resourcePaths = resourcePaths ?? resources.map(\.lastPathComponent)
            self.snapshotLease = snapshotLease
        }
    }

    let entries: [Entry]
    let platforms: [Platform]
    private let authenticatedContentDigests: [String: String]

    init(entries: [Entry], platforms: [Platform]) throws {
        // Diagnose destination-name collisions before comparing source trees. On the
        // default macOS filesystem canonically equivalent Unicode names can resolve
        // to the same standardized path, but the actionable problem is still the
        // generated package collision rather than an overlapping source selection.
        try Self.validate(entries)
        self.entries = entries
        self.platforms = platforms
        var digests: [String: String] = [:]
        // These keys are used only for filesystem identity/containment comparisons. Keep the original URLs for every
        // read so normalization cannot redirect an artifact to a differently spelled path.
        var selectedTrees: [(owner: Int, selection: BinaryArtifactSelection)] = []
        for (owner, entry) in entries.enumerated() {
            let selections = entry.xcframeworks.map { BinaryArtifactSelection($0, kind: .framework) }
                + entry.resources.map { BinaryArtifactSelection($0, kind: .resource) }
            for selection in selections {
                guard !selectedTrees.contains(where: {
                    selection.overlaps($0.selection)
                        && (owner != $0.owner || !selection.permitsOverlap(with: $0.selection))
                }) else {
                    throw SwiftPodsError(
                        "Binary package contains overlapping artifact directory trees",
                        file: entry.binary.declaredAt.description)
                }
                selectedTrees.append((owner, selection))
            }
        }
        for entry in entries {
            let hasOwnedSnapshot: Bool
            switch entry.binary.source {
            case .local:
                hasOwnedSnapshot = true
            case .remote:
                // Production remote entries always retain BinaryStore's private snapshot. Keep virtual manifest-only
                // entries usable in unit tests, but authenticate every real snapshot across the later copy boundary.
                hasOwnedSnapshot = entry.snapshotLease != nil
            }
            guard hasOwnedSnapshot else { continue }
            for url in entry.xcframeworks + entry.resources {
                // An artifact that cannot be authenticated must stop the install. Encoding the read error into the
                // fingerprint could otherwise let rendering continue with bytes that were never covered by a digest.
                digests[url.path] = try SecureFileTree.digest(of: url)
            }
        }
        authenticatedContentDigests = digests
    }

    /// Binary target names are the frameworks' module names; two binaries cannot ship the same one.
    func validate() throws {
        try Self.validate(entries)
    }

    private static func validate(_ entries: [Entry]) throws {
        var binaryFolders: [String: String] = [:]
        var owners: [String: (binary: String, item: String)] = [:]
        for entry in entries {
            let folderKey = fileSystemKey(entry.binary.name)
            if let existing = binaryFolders[folderKey], existing != entry.binary.name {
                throw SwiftPodsError(
                    "Binary names `\(existing)` and `\(entry.binary.name)` collide on the default macOS filesystem",
                    file: entry.binary.declaredAt.description)
            }
            binaryFolders[folderKey] = entry.binary.name
            for framework in entry.xcframeworks {
                let name = framework.deletingPathExtension().lastPathComponent
                let key = fileSystemKey(name)
                if let owner = owners[key] {
                    throw SwiftPodsError(
                        "Binaries `\(owner.binary)` and `\(entry.binary.name)` contain colliding frameworks "
                            + "\(owner.item).xcframework and \(name).xcframework",
                        file: entry.binary.declaredAt.description,
                        hint: "Select different frameworks with `xcframeworks:`, or declare the shared one once and list it in `dependencies`")
                }
                owners[key] = (entry.binary.name, name)
            }
            for bundle in entry.resources {
                let name = bundle.lastPathComponent
                let key = fileSystemKey(name)
                if let owner = owners[key] {
                    throw SwiftPodsError(
                        "Binaries `\(owner.binary)` and `\(entry.binary.name)` contain colliding resources \(owner.item) and \(name)",
                        file: entry.binary.declaredAt.description)
                }
                owners[key] = (entry.binary.name, name)
            }
        }
    }

    private static func fileSystemKey(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// Where a resource bundle is placed, relative to the package directory.
    static func resourcePath(_ binary: String, _ bundle: URL) -> String {
        "Artifacts/\(binary)/Resources/\(bundle.lastPathComponent)"
    }

    static func linkageTarget(_ binary: String) -> String { binary + "Linkage" }

    /// What the generated package is made from; an unchanged fingerprint means nothing to regenerate.
    var fingerprint: String {
        // Bump when generation or repairs change, so existing packages are regenerated.
        var lines = ["layout 4"] + platforms.map { "platform \($0.name.rawValue) \($0.deploymentTarget ?? "")" }
        for entry in entries {
            let binary = entry.binary
            let source: String
            switch binary.source {
            case .local(let path): source = "local:" + path
            case .remote(_, let sha256): source = "remote-sha256:" + sha256
            }
            lines.append(
                ["binary", binary.name, source, binary.systemFrameworks.joined(separator: ","),
                 binary.libraries.joined(separator: ","), binary.linkerFlags.joined(separator: " "),
                 binary.dependencies.joined(separator: ",")].joined(separator: "|"))
            lines += zip(entry.xcframeworkPaths, entry.xcframeworks).map {
                "framework \($0.0) \(authenticatedContentDigests[$0.1.path] ?? "pinned")"
            }
            lines += zip(entry.resourcePaths, entry.resources).map {
                "resource \($0.0) \(authenticatedContentDigests[$0.1.path] ?? "pinned")"
            }
        }
        return lines.joined(separator: "\n")
    }

    func manifest() -> String {
        func quoted(_ text: String) -> String {
            var result = "\""
            for scalar in text.unicodeScalars {
                switch scalar.value {
                case 0x09: result += "\\t"
                case 0x0A: result += "\\n"
                case 0x0D: result += "\\r"
                case 0x22: result += "\\\""
                case 0x5C: result += "\\\\"
                case 0x00...0x1F, 0x7F...0x9F, 0x2028, 0x2029:
                    result += "\\u{" + String(scalar.value, radix: 16, uppercase: true) + "}"
                default: result.unicodeScalars.append(scalar)
                }
            }
            return result + "\""
        }
        let names: [PlatformName: String] = [.ios: ".iOS", .macos: ".macOS", .tvos: ".tvOS", .watchos: ".watchOS", .visionos: ".visionOS"]
        var lines = [
            "// swift-tools-version: 5.9",
            "// Generated by SwiftPods from the Podfile. Do not edit.",
            "import PackageDescription",
            "",
            "let package = Package(",
            "    name: \(quoted(Self.directoryName)),",
        ]
        let platformItems = platforms.compactMap { platform in
            platform.deploymentTarget.map { "\(names[platform.name]!)(\(quoted($0)))" }
        }
        if !platformItems.isEmpty { lines.append("    platforms: [" + platformItems.joined(separator: ", ") + "],") }
        lines.append("    products: [")
        for entry in entries {
            lines.append("        .library(name: \(quoted(entry.binary.name)), targets: [\(quoted(Self.linkageTarget(entry.binary.name)))]),")
        }
        lines.append("    ],")
        lines.append("    targets: [")
        for entry in entries {
            let binary = entry.binary
            let frameworks = entry.xcframeworks.map { $0.deletingPathExtension().lastPathComponent }
            for framework in entry.xcframeworks {
                let name = framework.deletingPathExtension().lastPathComponent
                lines.append("        .binaryTarget(name: \(quoted(name)), path: \(quoted("Artifacts/\(binary.name)/\(framework.lastPathComponent)"))),")
            }
            let dependencies = (frameworks + binary.dependencies.map(Self.linkageTarget)).map(quoted)
            var settings = binary.systemFrameworks.map { ".linkedFramework(\(quoted($0)))" }
            settings += binary.libraries.map { ".linkedLibrary(\(quoted($0)))" }
            if !binary.linkerFlags.isEmpty {
                settings.append(".unsafeFlags([" + binary.linkerFlags.map(quoted).joined(separator: ", ") + "])")
            }
            lines.append("        .target(")
            lines.append("            name: \(quoted(Self.linkageTarget(binary.name))),")
            lines.append("            dependencies: [" + dependencies.joined(separator: ", ") + "],")
            lines.append("            path: \(quoted("Sources/\(Self.linkageTarget(binary.name))"))" + (settings.isEmpty ? "" : ","))
            if !settings.isEmpty { lines.append("            linkerSettings: [" + settings.joined(separator: ", ") + "]") }
            lines.append("        ),")
        }
        lines.append("    ]")
        lines.append(")")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Writes the package into an empty directory; frameworks are cloned, so this is cheap on APFS.
    /// Returns notes about framework slices it repaired.
    func render(into directory: URL) throws -> [String] {
        var notes: [String] = []
        let minimumOS = platforms.first { $0.name == .ios }?.deploymentTarget
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(manifest().utf8).write(to: directory.appendingPathComponent("Package.swift"))
        for entry in entries {
            let sources = directory.appendingPathComponent("Sources/\(Self.linkageTarget(entry.binary.name))", isDirectory: true)
            try fileManager.createDirectory(at: sources, withIntermediateDirectories: true)
            try Data("// Generated by SwiftPods: links \(entry.binary.name).\n".utf8)
                .write(to: sources.appendingPathComponent("Linkage.swift"))
            let artifacts = directory.appendingPathComponent("Artifacts/\(entry.binary.name)", isDirectory: true)
            try fileManager.createDirectory(at: artifacts, withIntermediateDirectories: true)
            for framework in entry.xcframeworks {
                let copy = artifacts.appendingPathComponent(framework.lastPathComponent)
                try copyAuthenticated(framework, to: copy)
                // Repair only after the copy has been proven byte-for-byte equal to the digest captured at init.
                notes += try FrameworkRepair.repair(xcframework: copy, minimumOS: minimumOS).map { "\(entry.binary.name): " + $0 }
            }
            for bundle in entry.resources {
                let destination = directory.appendingPathComponent(Self.resourcePath(entry.binary.name, bundle))
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try copyAuthenticated(bundle, to: destination)
            }
        }
        try Data(fingerprint.utf8).write(to: directory.appendingPathComponent(".fingerprint"))
        // Do not let the caller's umask or inherited default ACL make generated package content group/other writable.
        try SecureFileTree.normalizePermissions(in: directory)
        return notes
    }

    private func copyAuthenticated(_ source: URL, to destination: URL) throws {
        let expected = authenticatedContentDigests[source.path]
        if let expected {
            let before = try SecureFileTree.digest(of: source)
            guard before == expected else {
                throw SwiftPodsError("Binary artifact changed before it was copied: \(source.path)")
            }
        }
        do {
            try SecureFileTree.copySanitizedTree(from: source, to: destination, limits: .local)
            if let expected {
                let copied = try SecureFileTree.digest(of: destination)
                guard copied == expected else {
                    throw SwiftPodsError("Binary artifact changed while it was being copied: \(source.path)")
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
}
