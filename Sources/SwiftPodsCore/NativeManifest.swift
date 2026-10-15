import Foundation

/// Analyze consumer projects before resolving platform-constrained dependencies.
enum NativeManifest {
    static func analyze(_ manifest: [String: Any], project: URL, integrate: Bool) throws -> [String: Any] {
        for key in ["project", "workspace"]
        where manifest[key] != nil && !(manifest[key] is NSNull) && !(manifest[key] is String) {
            throw Diagnostic("SP-DSL-PROJECT", stage: "analyze", key + " must be a path string")
        }
        if let sources = manifest["sources"], !(sources is [String]) {
            throw Diagnostic("SP-DSL-SOURCE", stage: "analyze", "Sources must be URL strings")
        }
        var result = manifest
        var projects: [String: NativePBX] = [:]
        result["targets"] = try (manifest["targets"] as? [[String: Any]] ?? []).map { original -> [String: Any] in
            var target = original
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
                return try NativeBuildSettings.resolved(
                    config, graph: graph,
                    base: NativeBuildSettings.resolved(base, graph: graph, missingGeneratedRoot: generated),
                    missingGeneratedRoot: generated)
            }
            target["project"] =
                path.path.hasPrefix(project.path + "/")
                ? String(path.path.dropFirst(project.path.count + 1)) : path.resolvingSymlinksInPath().path
            if target["platform"] == nil {
                let platforms: [(String, String, String)] = [
                    ("osx", "macosx", "MACOSX_DEPLOYMENT_TARGET"), ("ios", "iphone", "IPHONEOS_DEPLOYMENT_TARGET"),
                    ("tvos", "appletv", "TVOS_DEPLOYMENT_TARGET"), ("watchos", "watch", "WATCHOS_DEPLOYMENT_TARGET"),
                    ("visionos", "xr", "XROS_DEPLOYMENT_TARGET"),
                ]
                let detected = settings.compactMap { value -> (String, String)? in
                    let sdk = value["SDKROOT"] as? String ?? ""
                    guard
                        let entry = platforms.first(where: {
                            sdk.contains($0.1) || (["", "auto"].contains(sdk) && value[$0.2] != nil)
                        }), let minimum = value[entry.2] as? String, (try? PodVersion(minimum)) != nil
                    else { return nil }
                    return (entry.0, minimum)
                }
                guard !detected.isEmpty, Set(detected.map { $0.0 }).count == 1 else {
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
