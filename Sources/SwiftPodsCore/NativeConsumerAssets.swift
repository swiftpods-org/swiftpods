import Foundation

extension NativeXcode {
    /// Bundle copies must finish before post-build scripts that depend on the app's dSYM.
    /// Appending after those scripts creates a cycle through Xcode's Info.plist processing.
    func insertConsumerCopyPhase(_ phase: String, into phases: inout [String], user: NativePBX) {
        let anchors: Set<String> = [
            "PBXHeadersBuildPhase", "PBXSourcesBuildPhase", "PBXFrameworksBuildPhase", "PBXResourcesBuildPhase",
        ]
        let index = phases.lastIndex { anchors.contains(user.objects[$0]?["isa"] as? String ?? "") }
        phases.insert(phase, at: index.map { $0 + 1 } ?? 0)
    }

    /// Full paths keep exclusions scoped to managed assets, including files with
    /// the same basename in a user's own resource phase. Shared assets remain
    /// enabled if any selected dependency needs them in this configuration.
    func consumerAssetExclusions(eligible: Set<String>, enabled: Set<String>, platform: String) throws -> [String] {
        func assets(_ roots: Set<String>) throws -> Set<String> {
            var paths = Set(
                try NativeResources.expandedPaths(roots.flatMap { staticResources[variantKey($0, platform)] ?? [] })
                    .map(\.path))
            let onDemand = try onDemandResources(roots: roots, platform: platform)
            paths.formUnion(try NativeResources.expandedPaths(Array(onDemand.files.keys)).map(\.path))
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
                guard graph.objects[product]?["explicitFileType"] as? String == "wrapper.cfbundle"
                else { continue }
                paths.insert(productBuildPath(product))
            }
            return paths
        }
        return try assets(eligible).subtracting(assets(enabled)).sorted()
    }

}
