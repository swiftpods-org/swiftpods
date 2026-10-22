import Foundation

extension NativeXcode {
    func podModuleIdentities(_ roots: Set<String>, platform: String) throws -> Set<String> {
        var names = Set<String>()
        for root in roots.sorted() {
            guard let spec = resolution.specs[root], let directory = spec.directory,
                let variant = variantPlan?.variants[variantKey(root, platform)]
            else { continue }
            let attributes = try NativeVariantPlan.attributes(spec, names: variant.names, platform: platform)
            let selection = try NativeLibraryFiles(
                spec: spec, names: variant.names, platform: platform, root: directory)
            let swift = selection.files.contains { $0.pathExtension == "swift" }
            if let path = attributes["module_map"] as? String {
                let contents = try String(contentsOf: directory.appendingPathComponent(path), encoding: .utf8)
                names.formUnion(
                    try NativeClangModuleMap(contents).modules.map { $0.name.components(separatedBy: ".")[0] })
            } else if (attributes["module_map"] as? Bool != false || variant.mode != "library")
                && requiresModule(variant, attributes: attributes, sources: selection.files)
            {
                names.insert(spec.moduleName)
            }
            if swift { names.insert(spec.moduleName) }
        }
        for sdk in roots.flatMap({ vendorSDKs[variantKey($0, platform)] ?? [] }) {
            var name = (sdk.productName as NSString).deletingPathExtension
            if sdk.productName.hasSuffix(".a"), name.hasPrefix("lib") { name = String(name.dropFirst(3)) }
            names.insert(name)
        }
        return names
    }
    private func packageProducts(_ user: NativePBX, target: String) -> [String] {
        let linked = user.objects[target]?["packageProductDependencies"] as? [String] ?? []
        let built = (user.objects[target]?["dependencies"] as? [String] ?? []).compactMap {
            user.objects[$0]?["productRef"] as? String
        }
        return (linked + built).filter { user.objects[$0]?["isa"] as? String == "XCSwiftPackageProductDependency" }
    }

    /// Product names do not reveal the modules supplied by their selected targets.
    func packagesNeedModuleValidation(_ user: NativePBX, target: String, roots: Set<String>, platform: String) -> Bool {
        !roots.isEmpty && !packageProducts(user, target: target).isEmpty
    }

    func validateExistingPackages(
        _ user: NativePBX, target: String, roots: Set<String>, platform: String, graph: NativeSwiftPackageGraph?
    ) throws {
        let identities = try podModuleIdentities(roots, platform: platform)
        guard let graph, !identities.isEmpty else { return }
        for dependency in packageProducts(user, target: target) {
            guard let value = user.objects[dependency], let product = value["productName"] as? String else { continue }
            let package: NativeSwiftPackageGraph.Package
            if let reference = value["package"] as? String, let object = user.objects[reference] {
                if let location = object["repositoryURL"] as? String {
                    package = try graph.package(location)
                } else if let relative = object["relativePath"] as? String {
                    let location = URL(
                        fileURLWithPath: NativeBuildSetting.decodedLiteral(relative), relativeTo: user.sourceRoot)
                    package = try graph.package(location.standardizedFileURL.path)
                } else {
                    throw Diagnostic(
                        "SP-SPM-PACKAGE", stage: "integrate", "Package reference has no location", file: user.url.path)
                }
            } else {
                let matches = try graph.packages.filter {
                    (try graph.manifest($0)["products"] as? [[String: Any]] ?? []).contains {
                        $0["name"] as? String == product
                    }
                }
                guard matches.count == 1, let resolved = matches.first else {
                    throw Diagnostic(
                        "SP-SPM-PRODUCT", stage: "integrate", "Package product is missing or ambiguous: " + product)
                }
                package = resolved
            }
            for destination in NativeSwiftPackageCompileSettings.destinations(platform, sdkContext: linkerSDKContext) {
                let modules = try NativeSwiftPackageModules.names(
                    product, package: package, graph: graph, destination: destination)
                if let duplicate = identities.intersection(modules).sorted().first {
                    throw Diagnostic(
                        "SP-DUPLICATE-SDK", stage: "integrate",
                        "A Swift package and a pod both supply module " + duplicate,
                        file: user.url.path)
                }
            }
        }
    }
}
