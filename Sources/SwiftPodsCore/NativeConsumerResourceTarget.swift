import Foundation

extension NativeXcode {
    /// Xcode compiles loose dependency resources in Pods; the consumer only copies their outputs.
    func generateConsumerResourceTargets() throws {
        for target in manifest["targets"] as? [[String: Any]] ?? [] {
            selectConsumer(target)
            let key = nativeConsumerKey(target)
            let platform = target["platform"] as? [String: String] ?? [:]
            let platformName = platform["name"] ?? "ios"
            let configured = try configuredDependencyRoots(target)
            let normal = configured.mapValues { roots in
                roots.sorted().flatMap { staticResources[variantKey($0, platformName)] ?? [] }
            }
            let onDemand = try configured.mapValues { try onDemandResources(roots: $0, platform: platformName) }
            let label = target["label"] as? String ?? "Pods-" + (target["name"] as? String ?? "")
            let plan = try NativeConditionalResources(
                directory: project.appendingPathComponent("Pods/Target Support Files/" + label),
                normal: normal, configurations: onDemand)
            consumerResourcePlans[key] = plan
            // Asset catalogs must merge with the app's catalogs, and on-demand tags belong to the app target.
            let native = plan.paths.filter {
                !plan.onDemand.files.isEmpty || ["xcassets", "xcstickers"].contains($0.pathExtension)
            }
            consumerNativeResources[key] = native
            let staged = plan.paths.filter { !native.contains($0) }
            guard !staged.isEmpty else { continue }
            let name = label + "-Resources"
            let references = try NativeResources.references(
                staged, owner: name, graph: graph, prefix: "consumer-resources:" + key + ":")
            let product = graph.add(
                "consumer-resources-product:" + key,
                [
                    "isa": "PBXFileReference", "explicitFileType": "wrapper.cfbundle", "path": name + ".bundle",
                    "sourceTree": "BUILT_PRODUCTS_DIR",
                ])
            var settings = baseSettings(platform: platformName, deployment: platform["deployment_target"] ?? "0")
            settings["PRODUCT_NAME"] = name
            settings["PRODUCT_BUNDLE_IDENTIFIER"] = "org.swiftpods.resources." + NativePBX.identifier(key).lowercased()
            settings["DEFINES_MODULE"] = "NO"
            try resourceBundleInfoPlist(name, settings: &settings)
            let list = configList(name, settings: settings)
            let eligible = configured.values.reduce(into: Set<String>()) { $0.formUnion($1) }
            for config in graph.objects[list]?["buildConfigurations"] as? [String] ?? [] {
                let configuration = graph.objects[config]?["name"] as? String ?? "Debug"
                let excluded = try consumerAssetExclusions(
                    eligible: eligible, enabled: configured[configuration] ?? [], platform: platformName)
                let paths = Set(excluded).union(plan.exclusions[configuration] ?? [])
                if !paths.isEmpty {
                    var value = graph.objects[config]?["buildSettings"] as? [String: Any] ?? [:]
                    value["EXCLUDED_SOURCE_FILE_NAMES"] = paths.sorted().map(NativeBuildSetting.literalPath)
                    graph.objects[config]?["buildSettings"] = value
                }
            }
            let id = graph.add(
                "consumer-resources-target:" + key,
                [
                    "isa": "PBXNativeTarget", "name": name, "productName": name, "productReference": product,
                    "productType": "com.apple.product-type.bundle", "buildConfigurationList": list,
                    "buildPhases": [
                        phase(
                            "PBXResourcesBuildPhase", target: name,
                            files: references.map { buildFile($0, target: name) })
                    ],
                    "buildRules": [], "dependencies": [],
                ])
            targetIDs.append(id)
            consumerResourceTargets[key] = id
            consumerResourceProducts[key] = product
            productBuildPaths[product] = name + ".bundle"
        }
    }
}
