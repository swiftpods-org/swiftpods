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
        var headers = Set<String>()
        var frameworks = Set<String>()
        var maps = Set<String>()
        var values: [String: [String]] {
            let flags = maps.sorted().map { "-fmodule-map-file=" + $0 }
            return [
                "SWIFTPODS_SPM_HEADERS": headers.sorted().map(NativeBuildSetting.quoted),
                "SWIFTPODS_SPM_FRAMEWORKS": frameworks.sorted().map(NativeBuildSetting.quoted),
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

        func visitProduct(_ name: String, package: NativeSwiftPackageGraph.Package) throws {
            let document = try graph.manifest(package)
            guard let product = (document["products"] as? [[String: Any]])?.first(where: { $0["name"] as? String == name }),
                let targets = product["targets"] as? [String]
            else { throw Diagnostic("SP-SPM-PRODUCT", stage: "integrate", "Package product not found: " + name, file: package.location) }
            for target in targets { try visitTarget(target, package: package) }
        }

        func visitTarget(_ name: String, package: NativeSwiftPackageGraph.Package) throws {
            guard visited.insert(package.directory.path + ":" + name).inserted else { return }
            let document = try graph.manifest(package)
            let targets = document["targets"] as? [[String: Any]] ?? []
            guard let target = targets.first(where: { $0["name"] as? String == name }) else {
                throw Diagnostic("SP-SPM-TARGET", stage: "integrate", "Package target not found: " + name, file: package.location)
            }
            if target["type"] as? String == "binary" {
                let sdk = try graph.binary(target, package: package)
                if let slice = sdk.slices.first(where: {
                    $0.platform == destination.platform && $0.variant == destination.variant
                        && $0.architectures.contains(destination.architecture)
                }) {
                    if slice.library.pathExtension == "framework" {
                        result.frameworks.insert(user.buildSettingPath(slice.library.deletingLastPathComponent()))
                    } else if let headers = slice.headers {
                        result.headers.insert(user.buildSettingPath(headers))
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
                let kind = target["type"] as? String ?? "regular"
                let directory = try graph.targetDirectory(target, package: package)
                let headers = directory.appendingPathComponent(target["publicHeadersPath"] as? String ?? (kind == "system" ? "." : "include"))
                if FileManager.default.fileExists(atPath: headers.path) {
                    result.headers.insert(user.buildSettingPath(headers))
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
            for dependency in target["dependencies"] as? [[String: Any]] ?? [] {
                guard let values = (dependency["target"] ?? dependency["byName"] ?? dependency["product"]) as? [Any],
                    let dependencyName = values.first as? String
                else { throw Diagnostic("SP-SPM-DEPENDENCY", stage: "integrate", "Invalid package target dependency", file: name) }
                if let condition = values.last as? [String: Any], let platforms = condition["platformNames"] as? [String],
                    !platforms.isEmpty && !platforms.contains(destination.manifestPlatform)
                { continue }
                if let condition = values.last as? [String: Any], condition.contains(where: {
                    $0.key != "platformNames" && !($0.value is NSNull)
                        && ($0.value as? [Any])?.isEmpty != true && ($0.value as? [String: Any])?.isEmpty != true
                }) {
                    throw Diagnostic("SP-SPM-CONDITION", stage: "integrate", "Unsupported package dependency condition", file: name)
                }
                if dependency["target"] != nil || (dependency["byName"] != nil && targets.contains { $0["name"] as? String == dependencyName }) {
                    try visitTarget(dependencyName, package: package)
                } else {
                    if dependency["product"] != nil, values.count > 2,
                        let aliases = values[2] as? [String: String], !aliases.isEmpty
                    {
                        throw Diagnostic("SP-SPM-ALIASES", stage: "integrate", "Module aliases cannot be exported as Objective-C compiler interfaces", file: dependencyName)
                    }
                    let explicit = values.count > 1 ? values[1] as? String : nil
                    var matches: [NativeSwiftPackageGraph.Package] = []
                    for entry in try graph.dependencies(package) {
                        if let explicit, ![entry.package.identity, entry.name ?? ""].contains(where: { $0.lowercased() == explicit.lowercased() }) { continue }
                        if (try graph.manifest(entry.package)["products"] as? [[String: Any]] ?? []).contains(where: { $0["name"] as? String == dependencyName }) {
                            matches.append(entry.package)
                        }
                    }
                    guard matches.count == 1, let resolved = matches.first else {
                        throw Diagnostic("SP-SPM-PRODUCT", stage: "integrate", "Dependency product is missing or ambiguous: " + dependencyName, file: package.location)
                    }
                    try visitProduct(dependencyName, package: resolved)
                }
            }
        }
        for declaration in declarations where !declaration.link {
            let package = try graph.package(declaration.url)
            for product in declaration.products { try visitProduct(product, package: package) }
        }
        return result
    }

    static func apply(
        _ declarations: [NativeSwiftPackageDeclaration], graph: NativeSwiftPackageGraph, platform: String,
        user: NativePBX, sdkContext: NativeSDKContext, settings: inout [String: Any]
    ) throws {
        for key in settings.keys where key.hasPrefix("SWIFTPODS_SPM_") {
            throw Diagnostic("SP-SPM-CONFLICT", stage: "integrate", "Reserved package compiler setting is user-owned: " + key)
        }
        let sdks: [(String, String, String)] = [
            "osx": [("macosx", "osx", "device")],
            "ios": [("iphoneos", "ios", "device"), ("iphonesimulator", "ios", "simulator"), ("macosx", "ios", "maccatalyst")],
            "tvos": [("appletvos", "tvos", "device"), ("appletvsimulator", "tvos", "simulator")],
            "watchos": [("watchos", "watchos", "device"), ("watchsimulator", "watchos", "simulator")],
            "visionos": [("xros", "visionos", "device"), ("xrsimulator", "visionos", "simulator")],
        ][platform] ?? []
        var rows: [(destination: Destination, interface: Interface)] = []
        for (sdk, platform, variant) in sdks {
            for architecture in sdkContext.architectures(sdk, target: variant == "maccatalyst" ? "iosmac" : sdk) {
                let destination = Destination(sdk: sdk, platform: platform, variant: variant, architecture: architecture)
                rows.append((destination, try interface(declarations, graph: graph, destination: destination, user: user)))
            }
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
