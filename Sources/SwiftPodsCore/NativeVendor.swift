import Foundation

struct NativeVendorSlice {
    let identifier: String
    let library: URL
    let headers: URL?
    let platform: String
    let variant: String
    let architectures: Set<String>
    let binary: URL
    let linkage: String
}

/// Validates SDK identities independently of the reference engine. Xcode's
/// native ProcessXCFramework step selects the actual build destination slice.
struct NativeVendorSDK {
    let url: URL
    let slices: [NativeVendorSlice]
    let fileType: String
    let productName: String
    var dynamic: Bool { slices.first?.linkage == "dynamic" }
    var isFramework: Bool { slices.first?.library.pathExtension == "framework" }
    var isXCFramework: Bool { url.pathExtension == "xcframework" }

    init(_ input: URL) throws {
        url = input.standardizedFileURL
        let root = input.resolvingSymlinksInPath()
        var parsed: [NativeVendorSlice] = []
        if input.pathExtension == "xcframework" {
            let info = try Self.plist(input.appendingPathComponent("Info.plist"))
            guard info["XCFrameworkFormatVersion"] as? String == "1.0",
                let libraries = info["AvailableLibraries"] as? [[String: Any]], !libraries.isEmpty
            else {
                throw Diagnostic(
                    "SP-XCFRAMEWORK-METADATA", stage: "integrate",
                    "XCFramework needs format 1.0 and AvailableLibraries", file: input.path)
            }
            var identifiers = Set<String>()
            for library in libraries {
                guard let identifier = library["LibraryIdentifier"] as? String, !identifier.utf8.contains(47),
                    identifiers.insert(identifier).inserted,
                    let path = library["LibraryPath"] as? String,
                    let platform = library["SupportedPlatform"] as? String,
                    let normalized = [
                        "ios": "ios", "macos": "osx", "tvos": "tvos", "watchos": "watchos", "xros": "visionos",
                        "visionos": "visionos",
                    ][platform],
                    let arches = library["SupportedArchitectures"] as? [String], !arches.isEmpty,
                    Set(arches).count == arches.count,
                    arches.allSatisfy({ $0.range(of: #"\A[A-Za-z0-9_]+\z"#, options: .regularExpression) != nil })
                else {
                    throw Diagnostic(
                        "SP-XCFRAMEWORK-METADATA", stage: "integrate",
                        "Invalid library identifier, platform or architectures", file: input.path)
                }
                let variant = library["SupportedPlatformVariant"] as? String ?? "device"
                guard ["device", "simulator", "maccatalyst"].contains(variant),
                    variant != "maccatalyst" || normalized == "ios"
                else {
                    throw Diagnostic(
                        "SP-XCFRAMEWORK-METADATA", stage: "integrate", "Unsupported XCFramework platform variant",
                        file: input.path)
                }
                let directory = try Self.contained(identifier, in: root)
                let payload = try Self.contained(path, in: directory)
                let binary = try Self.binary(payload)
                let inspected = try BinaryInspection.inspect(binary)
                let linkage = try Self.linkage(inspected, file: binary)
                let metadataArches = Set(arches)
                // Vendors may leave additional architectures in the universal
                // binary; only those advertised by the XCFramework are selectable.
                guard metadataArches.isSubset(of: Set(inspected.map(\.architecture))),
                    inspected.allSatisfy({
                        ($0.platform == "unknown" || $0.platform == normalized)
                            && ($0.variant == "unknown" || $0.variant == variant)
                    })
                else {
                    throw Diagnostic(
                        "SP-XCFRAMEWORK-BINARY", stage: "integrate",
                        "XCFramework metadata differs from its Mach-O architectures/platform/variant", file: binary.path
                    )
                }
                let headers = try (library["HeadersPath"] as? String).map { try Self.contained($0, in: directory) }
                if let headers, (try headers.resourceValues(forKeys: [.isDirectoryKey])).isDirectory != true {
                    throw Diagnostic(
                        "SP-XCFRAMEWORK-METADATA", stage: "integrate", "HeadersPath must identify a directory",
                        file: headers.path)
                }
                parsed.append(
                    NativeVendorSlice(
                        identifier: identifier, library: payload, headers: headers, platform: normalized,
                        variant: variant, architectures: metadataArches, binary: binary, linkage: linkage))
            }
            fileType = "wrapper.xcframework"
        } else {
            let binary = try Self.binary(input)
            let inspected = try BinaryInspection.inspect(binary)
            let linkage = try Self.linkage(inspected, file: binary)
            let groups = Dictionary(grouping: inspected, by: { $0.platform + ":" + $0.variant })
            for key in groups.keys.sorted() {
                let entries = groups[key]!
                parsed.append(
                    NativeVendorSlice(
                        identifier: key, library: input,
                        headers: input.pathExtension == "framework" ? input.appendingPathComponent("Headers") : nil,
                        platform: entries[0].platform, variant: entries[0].variant,
                        architectures: Set(entries.map(\.architecture)), binary: binary, linkage: linkage))
            }
            fileType =
                input.pathExtension == "framework"
                ? "wrapper.framework" : linkage == "static" ? "archive.ar" : "compiled.mach-o.dylib"
        }
        guard let first = parsed.first,
            parsed.allSatisfy({
                $0.linkage == first.linkage && $0.library.lastPathComponent == first.library.lastPathComponent
            })
        else {
            throw Diagnostic(
                "SP-XCFRAMEWORK-METADATA", stage: "integrate", "All slices must have the same product name and linkage",
                file: input.path)
        }
        for (index, slice) in parsed.enumerated() {
            for other in parsed.dropFirst(index + 1)
            where other.platform == slice.platform && other.variant == slice.variant {
                guard slice.architectures.isDisjoint(with: other.architectures) else {
                    throw Diagnostic(
                        "SP-XCFRAMEWORK-AMBIGUOUS", stage: "integrate",
                        "Multiple slices advertise the same platform/variant/architecture", file: input.path)
                }
            }
        }
        slices = parsed
        productName = first.library.lastPathComponent
    }
    func select(platform: String, variant: String, architectures: Set<String>) throws -> NativeVendorSlice {
        guard !architectures.isEmpty else {
            throw Diagnostic("SP-XCFRAMEWORK-ARCH", stage: "integrate", "A build architecture is required")
        }
        let matches = slices.filter {
            ($0.platform == platform || $0.platform == "unknown") && ($0.variant == variant || $0.variant == "unknown")
                && architectures.isSubset(of: $0.architectures)
        }
        guard matches.count == 1 else {
            throw Diagnostic(
                "SP-XCFRAMEWORK-SLICE", stage: "integrate",
                "Expected one slice for \(platform)/\(variant) [\(architectures.sorted().joined(separator: ", "))], found \(matches.count)",
                file: url.path)
        }
        return matches[0]
    }
    func supports(platform: String) -> Bool { slices.contains { $0.platform == platform || $0.platform == "unknown" } }
    private static func linkage(_ slices: [BinarySlice], file: URL) throws -> String {
        let kinds = Set(slices.map(\.kind))
        guard kinds.count == 1, let kind = kinds.first, ["static", "dynamic"].contains(kind) else {
            throw Diagnostic(
                "SP-VENDOR-BINARY", stage: "integrate", "Expected a static archive or dynamic library", file: file.path)
        }
        return kind
    }
    private static func plist(_ file: URL) throws -> [String: Any] {
        guard let data = try? Data(contentsOf: file),
            let value = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else {
            throw Diagnostic(
                "SP-XCFRAMEWORK-METADATA", stage: "integrate", "Cannot read SDK property list", file: file.path)
        }
        return value
    }
    private static func binary(_ library: URL) throws -> URL {
        guard ["framework", "a", "dylib"].contains(library.pathExtension) else {
            throw Diagnostic(
                "SP-VENDOR-FORMAT", stage: "integrate", "Supported SDKs are frameworks, static libraries and dylibs",
                file: library.path)
        }
        if library.pathExtension != "framework" { return library }
        let name = library.deletingPathExtension().lastPathComponent
        let shallow = library.appendingPathComponent("Info.plist")
        let info =
            FileManager.default.fileExists(atPath: shallow.path)
            ? shallow : library.appendingPathComponent("Resources/Info.plist")
        let executable =
            FileManager.default.fileExists(atPath: info.path)
            ? try plist(info)["CFBundleExecutable"] as? String ?? name : name
        return try contained(executable, in: library.resolvingSymlinksInPath())
    }
    private static func contained(_ relative: String, in root: URL) throws -> URL {
        guard !relative.isEmpty, relative.utf8.first != 47, !relative.utf8.contains(where: { $0 == 10 || $0 == 13 }),
            !(relative as NSString).pathComponents.contains(where: { $0 == ".." || $0 == "." })
        else {
            throw Diagnostic("SP-XCFRAMEWORK-PATH", stage: "integrate", "SDK path escapes its library", file: relative)
        }
        let file = root.appendingPathComponent(relative).standardizedFileURL
        guard NativePath.isDescendant(file.resolvingSymlinksInPath(), of: root.resolvingSymlinksInPath()),
            FileManager.default.fileExists(atPath: file.path)
        else {
            throw Diagnostic(
                "SP-XCFRAMEWORK-PATH", stage: "integrate", "SDK file is missing or escapes its library", file: file.path
            )
        }
        return file
    }
}
