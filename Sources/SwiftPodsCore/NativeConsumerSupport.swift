import Foundation

extension NativeXcode {
    /// Detach the former per-product integration before writing compact support phases.
    func removeConsumerProductLinks(_ user: NativePBX, target: String) {
        let managed = Set(previousProducts.union(products).map { NativePBX.identifier("swiftpods:build:" + $0) })
        for phase in user.objects[target]?["buildPhases"] as? [String] ?? [] {
            guard let files = user.objects[phase]?["files"] as? [String] else { continue }
            let kept = files.filter { build in
                if managed.contains(build) { return false }
                guard let reference = user.objects[build]?["fileRef"] as? String,
                    let key = user.ownedFileKey(reference, prefix: "swiftpods:vendor:")
                else { return true }
                return build != NativePBX.identifier(key + ":link")
            }
            user.objects[phase]?["files"] = kept
        }
        let obsolete = NativePBX.identifier("swiftpods:conditional-embed:" + target)
        let phases = user.objects[target]?["buildPhases"] as? [String] ?? []
        user.objects[target]?["buildPhases"] = phases.filter { $0 != obsolete }
        user.removeUnreferencedObjects([obsolete])
    }

    func integrateConsumerCopies(
        _ target: [String: Any], targetID: String, configured: [String: Set<String>], user: NativePBX
    ) throws {
        let key = nativeConsumerKey(target)
        let label = target["label"] as? String ?? "Pods-" + (target["name"] as? String ?? "")
        let platform = (target["platform"] as? [String: String])?["name"] ?? "ios"
        let plan = consumerResourcePlans[key]
        let native = Set(consumerNativeResources[key] ?? [])
        var resources: [String: [NativeConsumerCopy]] = [:]
        var frameworks: [String: [NativeConsumerCopy]] = [:]
        for (configuration, roots) in configured {
            resources[configuration] = try consumerBundleCopies(roots: roots, platform: platform)
            if let product = consumerResourceProducts[key], let plan {
                let excluded = Set(
                    try consumerAssetExclusions(
                        eligible: configured.values.reduce(into: []) { $0.formUnion($1) }, enabled: roots,
                        platform: platform)
                )
                .union(plan.exclusions[configuration] ?? [])
                let paths = plan.paths.filter { !native.contains($0) && !excluded.contains($0.path) }
                let productPath = consumerProductPath(product)
                let base = productPath.relative + (platform == "osx" ? "/Contents/Resources/" : "/")
                for output in try NativeConsumerResourceOutputs.paths(paths) {
                    resources[configuration, default: []].append(
                        NativeConsumerCopy(
                            source: NativeConsumerPath(variable: productPath.variable, relative: base + output),
                            destination: output))
                }
            }
            var copies: [NativeConsumerCopy] = []
            for product in products
            where productRoots[product] != nil
                && matchesProduct(product, roots: roots, platform: platform) && isDynamicProduct(product)
            {
                let path = consumerProductPath(product)
                copies.append(
                    NativeConsumerCopy(source: path, destination: URL(fileURLWithPath: path.relative).lastPathComponent)
                )
            }
            var seen = Set<URL>()
            for sdk in roots.sorted().flatMap({ vendorSDKs[variantKey($0, platform)] ?? [] })
            where sdk.dynamic && seen.insert(sdk.url).inserted {
                copies.append(NativeConsumerCopy(source: consumerSDKPath(sdk), destination: sdk.productName))
            }
            frameworks[configuration] = copies
        }
        try consumerCopyPhase(resources, kind: "resources", label: label, target: targetID, user: user)
        try consumerCopyPhase(frameworks, kind: "frameworks", label: label, target: targetID, user: user)
    }

    func consumerBundleCopies(roots: Set<String>, platform: String) throws -> [NativeConsumerCopy] {
        var destinations = Set<String>()
        return try products.filter {
            matchesProduct($0, roots: roots, platform: platform) && !frameworkResourceBundles.contains($0)
                && graph.objects[$0]?["explicitFileType"] as? String == "wrapper.cfbundle"
        }.map { product in
            let name = graph.objects[product]?["path"] as? String ?? ""
            guard destinations.insert(name.lowercased()).inserted else {
                throw Diagnostic(
                    "SP-XCODE-RESOURCE", stage: "integrate",
                    "Multiple dependencies copy the resource bundle " + name + " into the same target")
            }
            return NativeConsumerCopy(source: consumerProductPath(product), destination: name)
        }
    }
}
