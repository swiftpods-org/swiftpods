import Foundation

extension NativeXcode {
    func podModuleIdentities(_ roots: Set<String>, platform: String) -> Set<String> {
        var names = Set(roots.compactMap { root -> String? in
            guard let spec = resolution.specs[root] else { return nil }
            return spec.moduleName
        })
        for sdk in roots.flatMap({ vendorSDKs[variantKey($0, platform)] ?? [] }) {
            var name = (sdk.productName as NSString).deletingPathExtension
            if sdk.productName.hasSuffix(".a"), name.hasPrefix("lib") { name = String(name.dropFirst(3)) }
            names.insert(name)
        }
        return names
    }
    func validateExistingPackages(_ user: NativePBX, target: String, roots: Set<String>, platform: String) throws {
        let identities = podModuleIdentities(roots, platform: platform)
        for dependency in user.objects[target]?["packageProductDependencies"] as? [String] ?? [] {
            if let product = user.objects[dependency]?["productName"] as? String, identities.contains(product) { throw Diagnostic("SP-DUPLICATE-SDK", stage: "integrate", "An existing Swift package and a pod both supply " + product) }
        }
    }
}
