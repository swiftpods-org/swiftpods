import Foundation

struct NativeOnDemandResources {
    var files: [URL: Set<String>] = [:]
    var categories: [String: Set<String>] = [:]
    init() {}
    static func declarations(_ raw: Any) throws -> [(tag: String, paths: [String], category: String)] {
        guard let tags = raw as? [String: Any] else {
            throw Diagnostic("SP-SPEC-ODR", stage: "resolve", "on_demand_resources must map tags to resource patterns")
        }
        return try tags.sorted(by: { $0.key < $1.key }).map { tag, raw in
            guard !tag.isEmpty, !tag.contains(where: { $0.isWhitespace }) else {
                throw Diagnostic(
                    "SP-SPEC-ODR", stage: "resolve", "Resource tags must be nonempty and contain no whitespace")
            }
            let value = raw as? [String: Any] ?? ["paths": raw]
            let category = value["category"] as? String ?? "download_on_demand"
            let paths = value["paths"].map { $0 as? [Any] ?? [$0] } ?? []
            guard Set(value.keys).isSubset(of: ["paths", "category"]),
                value["category"] == nil || value["category"] is String,
                ["initial_install", "prefetched", "download_on_demand"].contains(category),
                paths.allSatisfy({ $0 is String || $0 is NSNull })
            else {
                throw Diagnostic(
                    "SP-SPEC-ODR", stage: "resolve", "Invalid on-demand resource paths or category", file: tag)
            }
            let patterns = paths.compactMap { $0 as? String }
            for pattern in patterns { try NativeSpecPaths.validatePath(pattern, file: tag) }
            return (tag, patterns, category)
        }
    }

    init(attributes: [String: Any], root: URL, expandLocalizedDirectories: Bool = true) throws {
        guard let raw = attributes["on_demand_resources"], !(raw is NSNull) else { return }
        for (tag, paths, category) in try Self.declarations(raw) {
            let selected: [URL]
            if expandLocalizedDirectories {
                selected = try NativeFileSelection.resourcePaths(paths, attributes: attributes, root: root)
            } else {
                selected = try NativeFileSelection.paths(paths, attributes: attributes, root: root)
            }
            for path in selected { files[path, default: []].insert(tag) }
            categories[category, default: []].insert(tag)
        }
    }
    mutating func merge(_ other: Self) {
        for (path, tags) in other.files { files[path, default: []].formUnion(tags) }
        for (category, tags) in other.categories { categories[category, default: []].formUnion(tags) }
    }
    var buildSettings: [String: Any] {
        var result: [String: Any] = [:]
        if !files.isEmpty { result["ENABLE_ON_DEMAND_RESOURCES"] = "YES" }
        for (category, setting) in [
            ("initial_install", "ON_DEMAND_RESOURCES_INITIAL_INSTALL_TAGS"),
            ("prefetched", "ON_DEMAND_RESOURCES_PREFETCH_ORDER"),
        ] {
            if let tags = categories[category], !tags.isEmpty { result[setting] = tags.sorted().joined(separator: " ") }
        }
        return result
    }
    func tag(target: String, graph: NativePBX) {
        for phase in graph.objects[target]?["buildPhases"] as? [String] ?? []
        where graph.objects[phase]?["isa"] as? String == "PBXResourcesBuildPhase" {
            for build in graph.objects[phase]?["files"] as? [String] ?? [] {
                guard let reference = graph.objects[build]?["fileRef"] as? String,
                    let path = try? NativeBuildSettings.file(reference, graph: graph), let tags = files[path]
                else { continue }
                var settings = graph.objects[build]?["settings"] as? [String: Any] ?? [:]
                settings["ASSET_TAGS"] = tags.sorted()
                graph.objects[build]?["settings"] = settings
            }
        }
        if let root = graph.root["rootObject"] as? String {
            var attributes = graph.objects[root]?["attributes"] as? [String: Any] ?? [:]
            let tags = Set(nativeStrings(attributes["KnownAssetTags"])).union(categories.values.flatMap { $0 })
            if !tags.isEmpty {
                attributes["KnownAssetTags"] = tags.sorted()
                graph.objects[root]?["attributes"] = attributes
            }
        }
    }
}

extension NativeXcode {
    func onDemandResources(roots: Set<String>, platform: String) throws -> NativeOnDemandResources {
        var result = NativeOnDemandResources()
        for root in roots.sorted() {
            guard let variant = variantPlan?.variants[variantKey(root, platform)], let spec = resolution.specs[root],
                let directory = spec.directory
            else { continue }
            for name in variant.names {
                result.merge(
                    try NativeOnDemandResources(attributes: spec.attributes(name, platform: platform), root: directory))
            }
        }
        return result
    }
}
