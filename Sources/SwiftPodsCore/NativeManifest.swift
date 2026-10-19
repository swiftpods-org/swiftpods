import Foundation

/// Analyze consumer projects before resolving platform-constrained dependencies.
enum NativeManifest {
    /// Accept only the historical path spelling; every other evaluated declaration
    /// still participates in the digest, including dynamic dependency requirements.
    static func legacyProjectChecksums(
        _ contract: [String: Any], project: URL, ownership: [String: Any]
    ) throws -> Set<String> {
        var origins = [URL(fileURLWithPath: project.path, isDirectory: true)]
        if let previous = NativeIntegrationLocation.previousRoot(ownership) { origins.append(previous) }
        let owned = NativeIntegrationSettings.projectPaths(ownership).sorted()
        var checksums = Set<String>()
        for origin in origins {
            var legacy = contract
            var changed = false
            legacy["targets"] = (contract["targets"] as? [[String: Any]] ?? []).map { original -> [String: Any] in
                var target = original
                guard let relative = original["project"] as? String, relative.utf8.first != 47 else { return target }
                let path = URL(fileURLWithPath: relative, relativeTo: origin).standardizedFileURL
                // Reproduce the old grapheme-based decision only for lock migration.
                guard !path.path.hasPrefix(origin.path + "/") else {
                    return target
                }
                let previous = owned.first {
                    URL(fileURLWithPath: $0).deletingLastPathComponent().path == path.path
                }.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path }
                target["project"] = previous ?? path.resolvingSymlinksInPath().path
                changed = true
                return target
            }
            if changed { checksums.insert(digest(try jsonData(legacy))) }
        }
        return checksums
    }

    static func analyze(
        _ manifest: [String: Any], project: URL, integrate: Bool,
        sdkContext: NativeSDKContext = NativeSDKContext()
    ) throws -> [String: Any] {
        for key in ["project", "workspace"]
        where manifest[key] != nil && !(manifest[key] is NSNull) && !(manifest[key] is String) {
            throw Diagnostic("SP-DSL-PROJECT", stage: "analyze", key + " must be a path string")
        }
        if let sources = manifest["sources"], !(sources is [String]) {
            throw Diagnostic("SP-DSL-SOURCE", stage: "analyze", "Sources must be URL strings")
        }
        var result = manifest
        var projects: [String: NativePBX] = [:]
        let receipt = project.appendingPathComponent("Pods/Target Support Files/SwiftPods-Integration.json")
        let previousRoot =
            FileManager.default.fileExists(atPath: receipt.path)
            ? NativeIntegrationLocation.previousRoot(try readObject(receipt)) : nil
        result["targets"] = try (manifest["targets"] as? [[String: Any]] ?? []).map { original -> [String: Any] in
            var target = original
            _ = try NativeSwiftPackageDeclaration.list(target["packages"], file: target["name"] as? String)
            if let path = target["project"], !(path is String) {
                throw Diagnostic("SP-DSL-PROJECT", stage: "analyze", "Project must be a path string")
            }
            if !integrate {
                guard target["platform"] != nil else {
                    throw Diagnostic(
                        "SP-PLATFORM-MISSING", stage: "analyze",
                        "Specify a platform when user project integration is disabled", file: target["name"] as? String)
                }
                return target
            }
            let path: URL
            if let name = target["project"] as? String ?? manifest["project"] as? String {
                let supplied = URL(fileURLWithPath: name, relativeTo: project).standardizedFileURL
                path = supplied.pathExtension == "xcodeproj" ? supplied : supplied.appendingPathExtension("xcodeproj")
            } else {
                let found = try FileManager.default.contentsOfDirectory(at: project, includingPropertiesForKeys: nil)
                    .filter { $0.pathExtension == "xcodeproj" }
                guard found.count == 1 else {
                    throw Diagnostic(
                        "SP-XCODE-AMBIGUOUS", stage: "analyze", "Specify project 'Name.xcodeproj' in the Podfile")
                }
                path = found[0]
            }
            let graph =
                try projects[path.path] ?? NativePBX(path.appendingPathComponent("project.pbxproj"), existing: true)
            projects[path.path] = graph
            if let previousRoot {
                try NativeIntegrationLocation.relocateGeneratedConfigurations(graph, from: previousRoot, to: project)
            }
            guard
                let native = graph.objects.values.first(where: {
                    $0["isa"] as? String == "PBXNativeTarget" && $0["name"] as? String == target["name"] as? String
                })
            else {
                throw Diagnostic(
                    "SP-XCODE-TARGET", stage: "analyze", "Consumer target does not exist",
                    file: target["name"] as? String)
            }
            let configs = configurations(native, graph: graph)
            let root = graph.objects[graph.root["rootObject"] as? String ?? ""] ?? [:]
            let projectConfigs = configurations(root, graph: graph)
            let settings = try configs.map { config -> [String: Any] in
                let base = projectConfigs.first { $0["name"] as? String == config["name"] as? String } ?? [:]
                let generated = project.appendingPathComponent("Pods/Target Support Files")
                let scope = try NativeBuildSettings.resolvedScopes(
                    config, inheriting: base, graph: graph,
                    missingGeneratedRoot: generated, sdkContext: sdkContext, targetName: native["name"] as? String
                ).targetScope
                var values = scope.values
                for key in [
                    "MACOSX_DEPLOYMENT_TARGET", "IPHONEOS_DEPLOYMENT_TARGET", "TVOS_DEPLOYMENT_TARGET",
                    "WATCHOS_DEPLOYMENT_TARGET", "XROS_DEPLOYMENT_TARGET", "SWIFT_VERSION",
                ] {
                    values[key] = try scope.expandedValue(key)
                }
                let sdk = try scope.expandedValue("SDKROOT", undefinedAsEmpty: true)
                // SDK conditions use empty substitutions, but lexical platform fallback
                // must retain unresolved references unless a real SDK confirms the path.
                if let sdk, !sdk.isEmpty, sdk != "auto",
                    sdkContext.canonicalName(sdk, relativeTo: graph.sourceRoot) == nil
                {
                    values["SDKROOT"] = try scope.expandedValue("SDKROOT")
                } else {
                    values["SDKROOT"] = sdk
                }
                return values
            }
            if let components = NativePath.relativeComponents(of: path, to: project), !components.isEmpty {
                target["project"] = components.joined(separator: "/")
            } else {
                target["project"] = path.resolvingSymlinksInPath().path
            }
            if target["platform"] == nil {
                let platforms: [(String, String, String)] = [
                    ("osx", "macosx", "MACOSX_DEPLOYMENT_TARGET"), ("ios", "iphone", "IPHONEOS_DEPLOYMENT_TARGET"),
                    ("tvos", "appletv", "TVOS_DEPLOYMENT_TARGET"), ("watchos", "watch", "WATCHOS_DEPLOYMENT_TARGET"),
                    ("visionos", "xr", "XROS_DEPLOYMENT_TARGET"),
                ]
                let detected = settings.compactMap { value -> (String, String)? in
                    let supplied = value["SDKROOT"] as? String ?? ""
                    let sdk = sdkContext.name(supplied, relativeTo: graph.sourceRoot)
                    let matches = platforms.filter {
                        ["", "auto"].contains(supplied)
                            ? !(value[$0.2] as? String ?? "").isEmpty : sdk.hasPrefix($0.1)
                    }
                    guard
                        matches.count == 1, let entry = matches.first,
                        let minimum = value[entry.2] as? String, (try? PodVersion(minimum)) != nil
                    else { return nil }
                    return (entry.0, minimum)
                }
                guard !detected.isEmpty, detected.count == settings.count, Set(detected.map { $0.0 }).count == 1 else {
                    throw Diagnostic(
                        "SP-PLATFORM-MISSING", stage: "analyze",
                        "Cannot infer one platform and deployment target from the consumer's build configurations",
                        file: target["name"] as? String)
                }
                let minimum = try detected.map { try PodVersion($0.1) }.min()!
                target["platform"] = ["name": detected[0].0, "deployment_target": minimum.description]
            }
            if target["swift_version"] == nil {
                let versions = Set(settings.compactMap { $0["SWIFT_VERSION"] as? String }.filter { !$0.isEmpty })
                guard versions.count <= 1 else {
                    throw Diagnostic(
                        "SP-SWIFT-VERSION-CONFLICT", stage: "analyze",
                        "Consumer configurations specify multiple Swift versions: "
                            + versions.sorted().joined(separator: ", "), file: target["name"] as? String)
                }
                target["swift_version"] = versions.first
            }
            return target
        }
        return result
    }
    private static func configurations(_ object: [String: Any], graph: NativePBX) -> [[String: Any]] {
        (graph.objects[object["buildConfigurationList"] as? String ?? ""]?["buildConfigurations"] as? [String] ?? [])
            .compactMap { graph.objects[$0] }
    }
}
