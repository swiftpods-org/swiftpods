import Foundation

extension NativeXcode {
    /// Full paths keep exclusions scoped to managed assets, including files with
    /// the same basename in a user's own resource phase. Shared assets remain
    /// enabled if any selected dependency needs them in this configuration.
    func consumerAssetExclusions(eligible: Set<String>, enabled: Set<String>, platform: String) throws -> [String] {
        func assets(_ roots: Set<String>) throws -> Set<String> {
            var paths = Set(try NativeResources.expandedPaths(roots.flatMap { staticResources[variantKey($0, platform)] ?? [] }).map(\.path))
            for sdk in roots.flatMap({ vendorSDKs[variantKey($0, platform)] ?? [] }) {
                paths.insert(sdk.url.path)
                // Xcode links the processed product but its copy phase can
                // resolve directly to the selected library inside the SDK.
                if sdk.isXCFramework {
                    paths.insert("$(BUILT_PRODUCTS_DIR)/" + sdk.productName)
                    paths.formUnion(sdk.slices.map { $0.library.path })
                }
            }
            for product in products where matchesProduct(product, roots: roots, platform: platform) {
                guard !frameworkResourceBundles.contains(product) else { continue }
                guard graph.objects[product]?["explicitFileType"] as? String == "wrapper.cfbundle",
                      let name = graph.objects[product]?["path"] as? String,
                      roots.contains(resourceRoots[name] ?? "") else { continue }
                paths.insert(productBuildPath(product))
            }
            return paths
        }
        return try assets(eligible).subtracting(assets(enabled)).sorted()
    }

    func copyResourceBundles(roots: Set<String>, platform: String, target: String, user: NativePBX) {
        let key = "swiftpods:resources:" + target
        var phases = user.objects[target]?["buildPhases"] as? [String] ?? []
        phases.removeAll { $0 == NativePBX.identifier(key) }; user.objects.removeValue(forKey: NativePBX.identifier(key))
        var files: [String] = []
        for product in products where matchesProduct(product, roots: roots, platform: platform) {
            guard !frameworkResourceBundles.contains(product) else { continue }
            guard let value = graph.objects[product], value["explicitFileType"] as? String == "wrapper.cfbundle",
                  roots.contains(resourceRoots[value["path"] as? String ?? ""] ?? "") else { continue }
            let reference = user.add("swiftpods:product:" + product, consumerProduct(product))
            files.append(user.add("swiftpods:build:" + product, ["isa": "PBXBuildFile", "fileRef": reference]))
        }
        if !files.isEmpty {
            phases.append(user.add(key, ["isa": "PBXCopyFilesBuildPhase", "name": "[SwiftPods] Copy Resource Bundles", "buildActionMask": "2147483647", "runOnlyForDeploymentPostprocessing": "0", "files": files, "dstPath": "", "dstSubfolderSpec": "7"]))
        }
        user.objects[target]?["buildPhases"] = phases
    }
}
