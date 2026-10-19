import Foundation

func nativeConsumerKey(_ target: [String: Any]) -> String {
    target["label"] as? String ?? target["name"] as? String ?? ""
}

struct NativePodVariant {
    let key: String
    let root: String
    let platform: String
    let consumerDeployment: String
    var mode: String
    let names: [String]
    let sourceSignature: String
    let actualRequests: [NativeDependency]
    var supplementary: [NativeDependency]
    var bindings: [String: String]
    var label: String
    var scoped: Bool
    var swiftVersion: String? = nil
    var consumerTargets: [String] = []
    var consumerKeys: [String] = []
    var headerScope: String {
        String(
            digest(
                Data(
                    (root + platform + consumerDeployment + mode + names.joined(separator: ":") + sourceSignature
                        + (swiftVersion ?? "")).utf8)
            ).prefix(16))
    }
}

/// Resolution chooses versions globally. Build variants retain each consumer's
/// selected specs and build type instead of unioning unrelated consumers.
struct NativeVariantPlan {
    var variants: [String: NativePodVariant] = [:]
    var consumers: [String: [String: String]] = [:]

    init(manifest: [String: Any], resolution: NativeResolution) throws {
        let targets = manifest["targets"] as? [[String: Any]] ?? []
        var records: [(name: String, bindings: [String: String])] = []
        for target in targets {
            let platform = target["platform"] as? [String: String] ?? [:]
            let name = platform["name"] ?? "ios"
            let deployment = platform["deployment_target"] ?? "0"
            let direct = try
                ((target["dependencies"] as? [[String: Any]] ?? [])
                + (target["search_dependencies"] as? [[String: Any]] ?? [])).flatMap {
                    try NativeDependency($0, platform: name, deployment: deployment).expandedSelections()
                }
            let requests = try Self.closure(direct, resolution: resolution)
            var bindings: [String: String] = [:]
            for root in Set(requests.map(\.root)).sorted() {
                guard let spec = resolution.specs[root] else { continue }
                let library = try requests.filter { try $0.root == root && spec.kind($0.name) == .library }
                let selected = Set(library.map(\.name)).sorted()
                let attributes = try Self.attributes(spec, names: selected, platform: name)
                let mode =
                    target["frameworks"] as? String == nil
                    ? "library"
                    : attributes["static_framework"] as? Bool == true ? "static" : target["frameworks"] as! String
                var identity: [String: Any] = [
                    "root": root, "platform": name, "deployment": deployment, "mode": mode, "specs": selected,
                ]
                if (manifest["options"] as? [String: Any])?["deduplicate_targets"] as? Bool == false {
                    identity["consumer"] = nativeConsumerKey(target)
                }
                let key = root + ":" + name + ":" + digest(try jsonData(identity))
                bindings[root] = key
                let supplementary = try requests.filter { try $0.root == root && spec.kind($0.name) != .library }
                if var existing = variants[key] {
                    let old = Set(existing.supplementary.map(\.name))
                    existing.supplementary += supplementary.filter { !old.contains($0.name) }
                    variants[key] = existing
                } else {
                    variants[key] = NativePodVariant(
                        key: key, root: root, platform: name, consumerDeployment: deployment, mode: mode,
                        names: selected, sourceSignature: digest(try jsonData(spec.data)), actualRequests: library,
                        supplementary: supplementary, bindings: [:], label: root, scoped: false)
                }
            }
            records.append((nativeConsumerKey(target), bindings))
        }
        // Keep the established key for unambiguous root/platform combinations.
        let groups = Dictionary(grouping: variants.values, by: { $0.root + ":" + $0.platform })
        var remap: [String: String] = [:]
        for (base, group) in groups {
            for variant in group { remap[variant.key] = group.count == 1 ? base : variant.key }
        }
        let original = variants
        variants = [:]
        for (key, variant) in original {
            let mapped = remap[key]!
            variants[mapped] = NativePodVariant(
                key: mapped, root: variant.root, platform: variant.platform,
                consumerDeployment: variant.consumerDeployment, mode: variant.mode, names: variant.names,
                sourceSignature: variant.sourceSignature, actualRequests: variant.actualRequests,
                supplementary: variant.supplementary, bindings: [:], label: variant.label,
                scoped: groups[variant.root + ":" + variant.platform]!.count > 1)
            let names = Set(records.filter { $0.bindings[variant.root] == key }.map(\.name))
            variants[mapped]?.consumerKeys = names.sorted()
            variants[mapped]?.consumerTargets = targets.filter { names.contains(nativeConsumerKey($0)) }.compactMap {
                $0["name"] as? String
            }.sorted()
            if let spec = resolution.specs[variant.root] {
                variants[mapped]?.swiftVersion = try NativeSwiftVersion.select(
                    spec: spec, targets: targets.filter { names.contains(nativeConsumerKey($0)) })
            }
        }
        for record in records {
            let bindings = record.bindings.mapValues { remap[$0]! }
            consumers[record.name] = bindings
            for key in bindings.values where variants[key]?.bindings.isEmpty == true {
                variants[key]?.bindings = bindings
            }
        }
        // A shared pod target uses the smallest compatible dependency variant,
        // independently of which consumer happened to be analyzed first.
        let orderedKeys = records.flatMap { record in
            record.bindings.keys.sorted().compactMap { remap[record.bindings[$0]!] }
        }
        for variant in Array(variants.values) {
            let required = try Self.closure(variant.actualRequests + variant.supplementary, resolution: resolution)
            for root in Set(required.map(\.root)) where root != variant.root {
                let selected = Set(
                    try required.filter { try $0.root == root && resolution.specs[root]!.kind($0.name) == .library }
                        .map(\.name))
                let candidates = variants.values.filter { candidate in
                    candidate.root == root && candidate.platform == variant.platform
                        && candidate.consumerDeployment == variant.consumerDeployment
                        && (candidate.mode == variant.mode
                            || resolution.specs[root]?.data["static_framework"] as? Bool == true
                                && candidate.mode == "static")
                        && selected.isSubset(of: Set(candidate.names))
                }.sorted { left, right in
                    let a = left.names.count + left.supplementary.count
                    let b = right.names.count + right.supplementary.count
                    if a != b { return a < b }
                    let x = orderedKeys.firstIndex(of: left.key) ?? Int.max
                    let y = orderedKeys.firstIndex(of: right.key) ?? Int.max
                    return x == y ? left.key < right.key : x < y
                }
                if let dependency = candidates.first { variants[variant.key]?.bindings[root] = dependency.key }
            }
        }
        for (root, group) in Dictionary(grouping: variants.values, by: \.root) {
            let labels = try NativeVariantLabels.labels(
                group, spec: resolution.specs[root]!,
                deduplicate: (manifest["options"] as? [String: Any])?["deduplicate_targets"] as? Bool != false)
            for variant in group {
                variants[variant.key]?.label = labels[variant.key]!
            }
        }
        for group in Dictionary(grouping: variants.values, by: \.label).values where group.count > 1 {
            for variant in group {
                variants[variant.key]?.label += "-" + String(digest(Data(variant.key.utf8)).prefix(16))
            }
        }
        let frameworks = variants.values.filter { $0.mode != "library" }
        for group in Dictionary(
            grouping: frameworks,
            by: {
                $0.platform + ":" + resolution.specs[$0.root]!.moduleName.lowercased()
            }
        ).values where Set(group.map(\.root)).count > 1 {
            for variant in group { variants[variant.key]?.scoped = true }
        }
    }

    static func closure(_ direct: [NativeDependency], resolution: NativeResolution) throws -> [NativeDependency] {
        var queue = direct
        var requests: [NativeDependency] = []
        var seen = Set<String>()
        while true {
            while let request = queue.popLast() {
                guard seen.insert(request.name).inserted else { continue }
                guard let spec = resolution.specs[request.root] else {
                    throw Diagnostic(
                        "SP-XCODE-SPEC", stage: "integrate", "Resolved dependency is missing", file: request.name)
                }
                requests.append(request)
                queue += try spec.dependencies(for: request)
            }
            let supplementary = try Set(
                requests.filter { try resolution.specs[$0.root]!.kind($0.name) != .library }.map(\.root))
            let libraries = try Set(
                requests.filter { try resolution.specs[$0.root]!.kind($0.name) == .library }.map(\.root))
            guard let missing = supplementary.subtracting(libraries).sorted().first,
                let request = requests.first(where: { $0.root == missing })
            else { break }
            queue.append(
                try NativeDependency(["name": missing], platform: request.platform, deployment: request.deployment))
        }
        return requests.sorted { $0.name < $1.name }
    }
    static func attributes(_ spec: NativeSpec, names: [String], platform: String) throws -> [String: Any] {
        var result: [String: Any] = [:]
        let selected = Set(names)
        let ancestors = Set(
            names.flatMap { name -> [String] in
                let parts = NativePodName.components(name)
                return (1...parts.count).map { parts.prefix($0).joined(separator: "/") }
            })
        for name in ancestors.sorted(by: {
            (NativePodName.components($0).count, $0) < (NativePodName.components($1).count, $1)
        }
        ) {
            let node = try spec.nodes(name).last!.data
            func eligible(_ key: String) -> Bool {
                selected.contains(name) || NativeAttributeContract.inherited.contains(key)
            }
            result = NativeSpec.merge(result, node.filter { eligible($0.key) })
            if let specific = node[platform] as? [String: Any] {
                result = NativeSpec.merge(result, specific.filter { eligible($0.key) || $0.key == "deployment_target" })
            }
        }
        return result
    }
}

extension NativeXcode {
    func requiresModule(_ variant: NativePodVariant, attributes: [String: Any], sources: [URL]) -> Bool {
        if variant.mode != "library" || sources.contains(where: { $0.pathExtension == "swift" }) { return true }
        let config = NativeSpec.xcconfig(attributes, key: "pod_target_xcconfig")
        if config["DEFINES_MODULE"] as? String == "YES" || attributes["module_map"] is String { return true }
        return (manifest["targets"] as? [[String: Any]] ?? []).contains { target in
            guard variantPlan?.consumers[nativeConsumerKey(target)]?[variant.root] == variant.key else { return false }
            let dependencies = (target["dependencies"] as? [[String: Any]] ?? []).filter {
                ($0["name"] as? String).map(NativePodName.root) == variant.root
            }
            let explicit = dependencies.compactMap { ($0["options"] as? [String: Any])?["modular_headers"] as? Bool }
            return explicit.contains(true) || (!explicit.contains(false) && target["modular_headers"] as? Bool == true)
        }
    }
    func selectConsumer(_ target: [String: Any]) {
        activeVariants = variantPlan?.consumers[nativeConsumerKey(target)] ?? [:]
    }
    func selectVariant(_ variant: NativePodVariant) {
        activeVariants = variant.bindings
        currentVariant = variant.key
    }
    func matchesProduct(_ product: String, roots: Set<String>, platform: String) -> Bool {
        guard productPlatforms[product] == platform else { return false }
        let root = productRoots[product] ?? resourceBundleRoots[product] ?? ""
        guard roots.contains(root) else { return false }
        return productVariants[product].map { $0 == variantKey(root, platform) } ?? true
    }
    func consumerProduct(_ product: String) -> [String: Any] {
        var value = graph.objects[product] ?? [:]
        if let path = productBuildPaths[product] {
            value["path"] = "$(CONFIGURATION)$(EFFECTIVE_PLATFORM_NAME)/" + path
            value["sourceTree"] = "BUILD_DIR"
        }
        return value
    }
    func buildReference(_ product: String) -> String {
        productBuildPaths[product] == nil ? product : graph.add("variant-file:" + product, consumerProduct(product))
    }
    func productBuildPath(_ product: String) -> String {
        if let path = productBuildPaths[product] {
            return "$(BUILD_DIR)/$(CONFIGURATION)$(EFFECTIVE_PLATFORM_NAME)/" + path
        }
        return "$(BUILT_PRODUCTS_DIR)/" + (graph.objects[product]?["path"] as? String ?? "")
    }
    func librarySearchDirectories(_ roots: Set<String>, platform: String) -> [String] {
        Array(
            Set(
                roots.compactMap { root -> String? in
                    guard let variant = variantPlan?.variants[variantKey(root, platform)] else { return nil }
                    return "$(BUILD_DIR)/$(CONFIGURATION)$(EFFECTIVE_PLATFORM_NAME)"
                        + (variant.scoped ? "/" + variant.label : "")
                })
        ).sorted()
    }
    func headerDirectory(_ root: String, platform: String, visibility: HeaderVisibility = .publicHeaders) -> String {
        "Pods/Headers/" + visibility.rawValue + (platformNames.count > 1 ? "/" + platform : "")
            + (variantPlan?.variants[variantKey(root, platform)].map { "/" + $0.headerScope } ?? "")
    }
    func headerSettings(_ roots: Set<String>, platform: String) -> [String] {
        Array(
            Set(
                roots.map {
                    let expression = "$(PODS_ROOT)" + headerDirectory($0, platform: platform).dropFirst(4)
                    // A list-form lookup would consume backslashes from PODS_ROOT.
                    return project.path.contains("\\") ? NativeBuildSetting.quoted(expression) : expression
                })
        ).sorted()
    }

    func consumerVariantDependencies(_ user: NativePBX, target: String, roots: Set<String>, platform: String) {
        let managed = Set(
            previousProducts.union(products).map {
                NativePBX.identifier("swiftpods:variant-dependency:" + target + ":" + $0)
            })
        var dependencies = (user.objects[target]?["dependencies"] as? [String] ?? []).filter { !managed.contains($0) }
        for product in products
        where productBuildPaths[product] != nil && matchesProduct(product, roots: roots, platform: platform) {
            guard let producer = graph.objects.first(where: { $0.value["productReference"] as? String == product }),
                let owner = targetOwners[producer.key]
            else { continue }
            let path = multipleProjects ? projectForPod(owner) : project.appendingPathComponent("Pods/Pods.xcodeproj")
            let portal = user.add(
                "swiftpods:variant-project:" + owner,
                [
                    "isa": "PBXFileReference", "path": NativeBuildSetting.literal(path.path),
                    "sourceTree": "<absolute>",
                    "lastKnownFileType": "wrapper.pb-project",
                ])
            let key = "swiftpods:variant-dependency:" + target + ":" + product
            let name = producer.value["name"] as? String ?? owner
            let proxy = user.add(
                key + ":proxy",
                [
                    "isa": "PBXContainerItemProxy", "containerPortal": portal, "proxyType": "1",
                    "remoteGlobalIDString": producer.key, "remoteInfo": name,
                ])
            dependencies.append(user.add(key, ["isa": "PBXTargetDependency", "name": name, "targetProxy": proxy]))
        }
        user.objects[target]?["dependencies"] = dependencies
        let used = Set(user.objects.values.flatMap { $0["dependencies"] as? [String] ?? [] })
        for dependency in managed.subtracting(used) {
            if let proxy = user.objects[dependency]?["targetProxy"] as? String {
                let portal = user.objects[proxy]?["containerPortal"] as? String
                user.objects.removeValue(forKey: proxy)
                if let portal, !user.objects.values.contains(where: { $0["containerPortal"] as? String == portal }) {
                    user.objects.removeValue(forKey: portal)
                }
            }
            user.objects.removeValue(forKey: dependency)
        }
    }
}
