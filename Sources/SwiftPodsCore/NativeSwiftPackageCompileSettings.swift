import Foundation

/// Only compiler visibility crosses a search-path-only package dependency.
/// No product, linker flag, library path or archive input is exported here.
enum NativeSwiftPackageCompileSettings {
    static let references = [
        "HEADER_SEARCH_PATHS": "SWIFTPODS_SPM_HEADERS",
        "FRAMEWORK_SEARCH_PATHS": "SWIFTPODS_SPM_FRAMEWORKS",
        "OTHER_CFLAGS": "SWIFTPODS_SPM_CFLAGS",
        "OTHER_CPLUSPLUSFLAGS": "SWIFTPODS_SPM_CFLAGS",
        "OTHER_SWIFT_FLAGS": "SWIFTPODS_SPM_SWIFT_FLAGS",
    ]

    struct Destination {
        let sdk: String
        let platform: String
        let variant: String
        let architecture: String
        var manifestPlatform: String {
            variant == "maccatalyst" ? "maccatalyst" : platform == "osx" ? "macos" : platform == "visionos" ? "visionos" : platform
        }
    }

    struct Interface: Equatable {
        var headers: [String] = []
        var frameworks: [String] = []
        var maps = Set<String>()
        var compilerFlags: [String] = []
        var values: [String: [String]] {
            func paths(_ values: [String]) -> [String] {
                // Include and framework lookup order selects the public interface.
                var seen = Set<String>()
                return values.filter { seen.insert($0).inserted }.map(NativeBuildSetting.quoted)
            }
            let flags = maps.sorted().map { "-fmodule-map-file=" + $0 } + compilerFlags
            return [
                "SWIFTPODS_SPM_HEADERS": paths(headers),
                "SWIFTPODS_SPM_FRAMEWORKS": paths(frameworks),
                "SWIFTPODS_SPM_CFLAGS": flags.map(NativeBuildSetting.quoted),
                "SWIFTPODS_SPM_SWIFT_FLAGS": flags.flatMap { ["-Xcc", NativeBuildSetting.quoted($0)] },
            ]
        }
    }

    static func interface(
        _ declarations: [NativeSwiftPackageDeclaration], graph: NativeSwiftPackageGraph,
        destination: Destination, user: NativePBX
    ) throws -> Interface {
        var result = Interface()
        var visited = Set<String>()

        func add(_ target: [String: Any], package: NativeSwiftPackageGraph.Package) throws {
            let name = target["name"] as? String ?? ""
            guard visited.insert(package.directory.path + ":" + name).inserted else { return }
            let kind = target["type"] as? String ?? "regular"
            if kind == "system", let config = target["pkgConfig"] as? String {
                let exported = try NativeSwiftPackagePkgConfig.interface(
                    graph.pkgConfig(config, package: package), directory: package.directory, user: user)
                result.headers += exported.headers
                result.frameworks += exported.frameworks
                result.compilerFlags += exported.compilerFlags
            }
            if kind == "binary" {
                let sdk = try graph.binary(target, package: package)
                if let slice = sdk.slices.first(where: {
                    $0.platform == destination.platform && $0.variant == destination.variant
                        && $0.architectures.contains(destination.architecture)
                }) {
                    if slice.library.pathExtension == "framework" {
                        result.frameworks.append(user.buildSettingPath(slice.library.deletingLastPathComponent()))
                    } else if let headers = slice.headers {
                        result.headers.append(user.buildSettingPath(headers))
                        let map = headers.appendingPathComponent("module.modulemap")
                        if FileManager.default.fileExists(atPath: map.path) {
                            result.maps.insert(user.buildSettingPath(map))
                        } else {
                            result.maps.insert(user.buildSettingPath(try graph.moduleMaps.generated(
                                name: name, headers: headers, identity: package.identity + ":" + name + ":" + slice.identifier)))
                        }
                    }
                }
            } else {
                let directory = try graph.targetDirectory(target, package: package)
                let headers = directory.appendingPathComponent(target["publicHeadersPath"] as? String ?? (kind == "system" ? "." : "include"))
                if FileManager.default.fileExists(atPath: headers.path) {
                    result.headers.append(user.buildSettingPath(headers))
                    let map = headers.appendingPathComponent("module.modulemap")
                    if FileManager.default.fileExists(atPath: map.path) {
                        result.maps.insert(user.buildSettingPath(map))
                    } else {
                        result.maps.insert(user.buildSettingPath(try graph.moduleMaps.generated(
                            name: name, headers: headers, identity: package.identity + ":" + name)))
                    }
                } else {
                    // Swift package targets also expose Xcode's generated Objective-C interface map.
                    let sources = target["sources"] as? [String]
                    let swift = sources?.contains(where: { $0.hasSuffix(".swift") })
                        ?? ((FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? [])
                            .contains { $0.pathExtension == "swift" }
                    if swift { result.maps.insert("$(GENERATED_MODULEMAP_DIR)/" + NativeBuildSetting.scalarLiteral(name) + ".modulemap") }
                }
            }
        }
        for declaration in declarations where !declaration.link {
            let package = try graph.package(declaration.url)
            for entry in try NativeSwiftPackageTargets.list(
                declaration.products, package: package, graph: graph, platform: destination.manifestPlatform)
            { try add(entry.target, package: entry.package) }
        }
        return result
    }

    private static func sdks(_ platform: String) -> [(String, String, String)] {
        [
            "osx": [("macosx", "osx", "device")],
            "ios": [("iphoneos", "ios", "device"), ("iphonesimulator", "ios", "simulator"), ("macosx", "ios", "maccatalyst")],
            "tvos": [("appletvos", "tvos", "device"), ("appletvsimulator", "tvos", "simulator")],
            "watchos": [("watchos", "watchos", "device"), ("watchsimulator", "watchos", "simulator")],
            "visionos": [("xros", "visionos", "device"), ("xrsimulator", "visionos", "simulator")],
        ][platform] ?? []
    }

    static func destinations(_ platform: String, sdkContext: NativeSDKContext) -> [Destination] {
        sdks(platform).flatMap { sdk, platform, variant in
            sdkContext.architectures(sdk, target: variant == "maccatalyst" ? "iosmac" : sdk).map {
                Destination(sdk: sdk, platform: platform, variant: variant, architecture: $0)
            }
        }
    }

    static func apply(
        _ declarations: [NativeSwiftPackageDeclaration], graph: NativeSwiftPackageGraph, platform: String,
        user: NativePBX, sdkContext: NativeSDKContext, settings: inout [String: Any]
    ) throws {
        for key in settings.keys where key.hasPrefix("SWIFTPODS_SPM_") {
            throw Diagnostic("SP-SPM-CONFLICT", stage: "integrate", "Reserved package compiler setting is user-owned: " + key)
        }
        let sdks = sdks(platform)
        var rows: [(destination: Destination, interface: Interface)] = []
        for destination in destinations(platform, sdkContext: sdkContext) {
            rows.append((destination, try interface(declarations, graph: graph, destination: destination, user: user)))
        }
        guard let first = rows.first else { return }
        for variable in first.interface.values.keys.sorted() {
            let base = first.interface.values[variable]!
            let differs = rows.contains { $0.interface.values[variable] != base }
            if !differs {
                settings[variable] = base
                continue
            }
            let catalyst = platform == "ios"
            settings[variable] = catalyst ? "$(" + variable + "_$(IS_MACCATALYST:default=NO))" : ""
            if catalyst { settings[variable + "_NO"] = ""; settings[variable + "_YES"] = "" }
            for (sdk, _, variant) in sdks {
                let selected = rows.filter { $0.destination.sdk == sdk && $0.destination.variant == variant }
                let key = variable + (catalyst ? (variant == "maccatalyst" ? "_YES" : "_NO") : "") + "[sdk=" + sdk + "*]"
                guard let value = selected.first?.interface.values[variable] else { continue }
                if selected.allSatisfy({ $0.interface.values[variable] == value }) {
                    settings[key] = value
                } else {
                    for row in selected { settings[key + "[arch=" + row.destination.architecture + "]"] = row.interface.values[variable]! }
                }
            }
        }
        for (key, variable) in references {
            if key == "OTHER_CPLUSPLUSFLAGS", settings[key] == nil { continue }
            let reference = "$(" + variable + ")"
            var values = nativeStrings(settings[key])
            if values.isEmpty { values = ["$(inherited)"] }
            if !values.contains(reference) { values.append(reference) }
            settings[key] = values
        }
    }

    /// A later user edit to a list must survive removal of our reserved macro.
    static func removingReferences(_ value: Any, key: String) -> Any {
        guard let variable = references[key] else { return value }
        let reference = "$(" + variable + ")"
        if let values = value as? [String] { return values.filter { $0 != reference } }
        if let text = value as? String { return text.replacingOccurrences(of: reference, with: "") }
        return value
    }
}
