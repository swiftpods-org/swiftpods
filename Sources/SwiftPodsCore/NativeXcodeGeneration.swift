import Foundation

extension NativeXcode {
    /// Builds the dependency project in dependency order before user integration.
    func generate() throws {
        try prepareResourceBundleLabels()
        for variant in variantPlan?.variants.values.sorted(by: { $0.label < $1.label }) ?? [] {
            try generateLibraryTarget(variant)
        }
        try connectLibraryTargets()
        try generateSupplementaryTargets()
        try generateConsumerResourceTargets()
        try generateAggregateTargets()
        assembleProjectGraph()
        try developmentSchemes()
        organizeSourceGroups()
        try generateBridgeSupport()
        try podConfigurations()
        refreshHookConfigurations()
    }

    private func connectLibraryTargets() throws {
        for id in targetIDs {
            guard let entry = libraryTargets.first(where: { $0.value == id }),
                let variant = variantPlan?.variants[entry.key],
                let product = graph.objects[id]?["productReference"] as? String,
                let platform = productPlatforms[product], let name = productRoots[product]
            else { continue }
            selectVariant(variant)
            let label = variant.label
            let dynamic = isDynamicProduct(product)
            let requests = variant.actualRequests
            let roots = try dependencyRoots(requests).subtracting([name])
            let dependencies = roots.sorted().compactMap { dependency -> String? in
                guard let target = libraryTargets[variantKey(dependency, platform)] else { return nil }
                return graph.add("dependency:\(id):\(target)", ["isa": "PBXTargetDependency", "target": target])
            }
            let previousDependencies = graph.objects[id]?["dependencies"] as? [String] ?? []
            graph.objects[id]?["dependencies"] = previousDependencies + dependencies
            // Source wrappers must see SDKs supplied by transitive binary pods,
            // including Xcode's selected XCFramework headers and frameworks.
            let sdks = roots.sorted().flatMap { vendorSDKs[variantKey($0, platform)] ?? [] }
            if let phases = graph.objects[id]?["buildPhases"] as? [String],
                let phase = phases.first(where: { graph.objects[$0]?["isa"] as? String == "PBXFrameworksBuildPhase" })
            {
                var files = graph.objects[phase]?["files"] as? [String] ?? []
                let references =
                    sdks.filter { dynamic || $0.isXCFramework }.map { file($0.url.path, type: $0.fileType) }
                    + products.filter {
                        dynamic && matchesProduct($0, roots: roots, platform: platform) && productRoots[$0] != nil
                    }.map(buildReference)
                for reference in references {
                    let build = buildFile(reference, target: label)
                    if !files.contains(build) { files.append(build) }
                }
                graph.objects[phase]?["files"] = files
            }
            let libraryDirectories = librarySearchDirectories(roots, platform: platform)
            let frameworkDirectories = sdks.filter { !$0.isXCFramework && $0.isFramework }.map {
                NativeBuildSetting.literal($0.url.deletingLastPathComponent().path)
            }
            let staticDirectories = sdks.filter { !$0.isXCFramework && !$0.isFramework }.map {
                NativeBuildSetting.literal($0.url.deletingLastPathComponent().path)
            }
            let sdkHeaderDirectories = sdks.filter { !$0.isXCFramework }.compactMap {
                $0.slices.first?.headers.map { NativeBuildSetting.literal($0.path) }
            }
            let searchPaths: [String: [String]] = [
                "FRAMEWORK_SEARCH_PATHS": ["$(BUILT_PRODUCTS_DIR)"] + libraryDirectories + frameworkDirectories,
                "LIBRARY_SEARCH_PATHS": ["$(BUILT_PRODUCTS_DIR)"] + libraryDirectories + staticDirectories,
                "SWIFT_INCLUDE_PATHS": libraryDirectories,
                "HEADER_SEARCH_PATHS": headerSettings(roots, platform: platform) + sdkHeaderDirectories,
            ]
            for config in configurations[label].map({ Array($0.values) }) ?? [] {
                var settings = graph.objects[config]?["buildSettings"] as? [String: Any] ?? [:]
                if !dynamic { excludeStaticSDKLinkInputs(sdks, settings: &settings) }
                for (key, paths) in searchPaths {
                    var values = nativeStrings(settings[key])
                    if values.isEmpty { values = ["$(inherited)"] }
                    for path in paths.map(NativeBuildSetting.path) where !values.contains(path) { values.append(path) }
                    settings[key] = values
                }
                applyCustomModuleMaps(roots, platform: platform, settings: &settings)
                if dynamic {
                    let flags = try consumerLinkerFlags(
                        roots, platform: platform, sources: linkerSources(id, graph: graph), settings: settings)
                    settings["OTHER_LDFLAGS"] = nativeStrings(settings["OTHER_LDFLAGS"]) + flags
                }
                graph.objects[config]?["buildSettings"] = settings
            }
        }
    }

    /// Keep native XCFramework slice preparation without merging the selected
    /// binary into an archive that the consumer links alongside the SDK itself.
    func excludeStaticSDKLinkInputs(_ sdks: [NativeVendorSDK], settings: inout [String: Any]) {
        let paths = sdks.filter(\.isXCFramework).map { NativeBuildSetting.literalPath($0.url.path) }
        guard !paths.isEmpty else { return }
        var exclusions = nativeStrings(settings["EXCLUDED_SOURCE_FILE_NAMES"])
        for path in paths where !exclusions.contains(path) { exclusions.append(path) }
        settings["EXCLUDED_SOURCE_FILE_NAMES"] = exclusions
    }

    private func generateAggregateTargets() throws {
        let targets = manifest["targets"] as? [[String: Any]] ?? []
        for target in targets {
            selectConsumer(target)
            let platform = target["platform"] as? [String: String] ?? [:]
            let name = target["name"] as? String ?? ""
            let requests = try (nativeDependencies(target) + nativeDependencies(target, search: true)).flatMap {
                try NativeDependency(
                    $0, platform: platform["name"] ?? "ios", deployment: platform["deployment_target"] ?? "0"
                ).expandedSelections()
            }
            let roots = try dependencyRoots(requests)
            let label = target["label"] as? String ?? "Pods-" + name
            var producers = roots.sorted().compactMap { libraryTargets[variantKey($0, platform["name"] ?? "ios")] }
            if let resources = consumerResourceTargets[nativeConsumerKey(target)] { producers.append(resources) }
            let deps = producers.map {
                graph.add("aggregate-dependency:" + label + ":" + $0, ["isa": "PBXTargetDependency", "target": $0])
            }
            let id = graph.add(
                "aggregate:" + label,
                [
                    "isa": "PBXAggregateTarget", "name": label, "productName": label,
                    "buildConfigurationList": configList(
                        label,
                        settings: baseSettings(
                            platform: platform["name"] ?? "ios", deployment: platform["deployment_target"] ?? "0")),
                    "buildPhases": [], "dependencies": deps,
                ])
            targetIDs.append(id)
            aggregateTargets[nativeConsumerKey(target)] = id
        }
    }

    private func assembleProjectGraph() {
        let allProducts = targetIDs.compactMap { graph.objects[$0]?["productReference"] as? String }
        let productGroup = graph.add(
            "products", ["isa": "PBXGroup", "name": "Products", "sourceTree": "<group>", "children": allProducts])
        let variants = graph.objects.filter { $0.value["isa"] as? String == "PBXVariantGroup" }
        let localizedChildren = Set(variants.values.flatMap { $0["children"] as? [String] ?? [] })
        let files =
            graph.objects.filter {
                $0.value["isa"] as? String == "PBXFileReference" && !allProducts.contains($0.key)
                    && !localizedChildren.contains($0.key)
            }.map(\.key).sorted() + variants.keys.sorted()
        let group = graph.add(
            "group", ["isa": "PBXGroup", "sourceTree": "<group>", "children": files + [productGroup]])
        var projectAttributes: [String: Any] = ["LastUpgradeCheck": "1600"]
        let assetTags = Set(
            graph.objects.values.flatMap { nativeStrings(($0["settings"] as? [String: Any])?["ASSET_TAGS"]) })
        if !assetTags.isEmpty { projectAttributes["KnownAssetTags"] = assetTags.sorted() }
        if !testTargetHosts.isEmpty {
            projectAttributes["TargetAttributes"] = testTargetHosts.mapValues { ["TestTargetID": $0] }
        }
        let root = graph.add(
            "project",
            [
                "isa": "PBXProject", "attributes": projectAttributes,
                "buildConfigurationList": configList("Pods", settings: [:]), "compatibilityVersion": "Xcode 14.0",
                "developmentRegion": "en", "hasScannedForEncodings": "0", "knownRegions": ["en", "Base"],
                "mainGroup": group, "productRefGroup": productGroup, "projectDirPath": "", "projectRoot": "",
                "targets": targetIDs,
            ])
        graph.root = ["archiveVersion": "1", "objectVersion": "56", "classes": [:], "rootObject": root]
    }

    private func refreshHookConfigurations() {
        for index in hookTargets.indices {
            guard let name = hookTargets[index]["name"] as? String, let mapping = configurations[name] else { continue }
            hookTargets[index]["build_configurations"] = configurationNames.compactMap {
                configuration -> [String: Any]? in
                guard let id = mapping[configuration], let settings = graph.objects[id]?["buildSettings"] else {
                    return nil
                }
                return ["name": configuration, "build_settings": settings]
            }
        }
    }
}
