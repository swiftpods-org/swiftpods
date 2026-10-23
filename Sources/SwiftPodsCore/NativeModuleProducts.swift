import Foundation

extension NativeXcode {
    /// Static source products cannot be shared safely by a dynamic pod and its consumers.
    func validateStaticSourceDependencies() throws {
        let previous = activeVariants
        let previousVariant = currentVariant
        defer {
            activeVariants = previous
            currentVariant = previousVariant
        }
        for variant in variantPlan?.variants.values.sorted(by: { $0.label < $1.label }) ?? [] {
            selectVariant(variant)
            guard isDynamicLibrary(variant.root, platform: variant.platform) else { continue }
            let dependencies = try dependencyRoots(variant.actualRequests).subtracting([variant.root])
            for root in dependencies.sorted() where !isDynamicLibrary(root, platform: variant.platform) {
                guard let spec = resolution.specs[root], let directory = spec.directory,
                    let dependency = variantPlan?.variants[variantKey(root, variant.platform)]
                else { continue }
                let selection = try NativeLibraryFiles(
                    spec: spec, names: dependency.names, platform: variant.platform, root: directory)
                guard selection.files.contains(where: { NativeFileSelection.objectSources.contains($0.pathExtension) })
                else { continue }
                throw Diagnostic(
                    "SP-XCODE-STATIC-DEPENDENCY", stage: "integrate",
                    "Dynamic pod \(variant.root) depends on static source pod \(root); use static linkage for its consumers",
                    dependencyChain: [variant.root, root])
            }
        }
    }

    /// Independent dynamic wrappers must not each contain the same SDK's state.
    func validateStaticSDKOwnership() throws {
        let previous = activeVariants
        let previousVariant = currentVariant
        defer {
            activeVariants = previous
            currentVariant = previousVariant
        }
        for target in manifest["targets"] as? [[String: Any]] ?? [] {
            selectConsumer(target)
            let platform = (target["platform"] as? [String: String])?["name"] ?? "ios"
            let configured = try configuredDependencyRoots(target)
            for configuration in configurationNames {
                selectConsumer(target)
                let variants = (configured[configuration] ?? []).sorted().compactMap {
                    variantPlan?.variants[variantKey($0, platform)]
                }
                var owners: [URL: String] = [:]
                for variant in variants {
                    selectVariant(variant)
                    guard isDynamicLibrary(variant.root, platform: platform) else { continue }
                    let roots = try dependencyRoots(variant.actualRequests).subtracting([variant.root])
                    let sdks = (vendorSDKs[variant.key] ?? []) + (try consumerVendorSDKs(roots, platform: platform))
                    for sdk in sdks where !sdk.dynamic {
                        if let owner = owners[sdk.url], owner != variant.label {
                            throw Diagnostic(
                                "SP-XCODE-STATIC-SDK-CONFLICT", stage: "integrate",
                                "Dynamic pods \(owner) and \(variant.label) load independent copies of \(sdk.productName) in \(configuration); use static linkage for this consumer",
                                file: target["name"] as? String, dependencyChain: [owner, variant.label])
                        }
                        owners[sdk.url] = variant.label
                    }
                }
            }
        }
    }

    /// Framework products and public modules share a namespace within each consumer/configuration.
    func validateModules(inspectInterfaces: Bool = true) throws {
        let previous = activeVariants
        defer { activeVariants = previous }
        var interfaces: [String: (names: Set<String>, framework: String?)] = [:]
        var vendorModules: [URL: [String: Set<String>]] = [:]
        var destinations: [String: [NativeSwiftPackageCompileSettings.Destination]] = [:]
        for target in manifest["targets"] as? [[String: Any]] ?? [] {
            selectConsumer(target)
            let platform = target["platform"] as? [String: String] ?? [:]
            let platformName = platform["name"] ?? "ios"
            let requests = try nativeDependencies(target).flatMap {
                try NativeDependency(
                    $0, platform: platformName, deployment: platform["deployment_target"] ?? "0"
                ).expandedSelections()
            }
            for configuration in configurationNames {
                let roots = try dependencyRoots(requests.filter { dependencyEnabled($0, configuration: configuration) })
                var frameworks: [String: String] = [:]
                var modules: [String: String] = [:]
                for root in roots.sorted() {
                    guard let spec = resolution.specs[root],
                        let variant = variantPlan?.variants[variantKey(root, platformName)]
                    else { continue }
                    if !inspectInterfaces && variant.mode == "library" { continue }
                    if interfaces[variant.key] == nil {
                        interfaces[variant.key] = try podModuleInterface(
                            variant, spec: spec, inspectModules: inspectInterfaces)
                    }
                    guard let interface = interfaces[variant.key] else { continue }
                    if let product = interface.framework {
                        if let other = frameworks[product.lowercased()], other != root {
                            throw Diagnostic(
                                "SP-XCODE-MODULE-CONFLICT", stage: "integrate",
                                "Pods \(other) and \(root) provide the same framework product \(product) in \(configuration)",
                                file: target["name"] as? String)
                        }
                        frameworks[product.lowercased()] = root
                    }
                    for module in interface.names.sorted() {
                        if let other = modules[module.lowercased()], other != root {
                            throw Diagnostic(
                                "SP-XCODE-MODULE-CONFLICT", stage: "integrate",
                                "Pods \(other) and \(root) provide the same module \(module) in \(configuration)",
                                file: target["name"] as? String)
                        }
                        modules[module.lowercased()] = root
                    }
                }
                guard inspectInterfaces, !modules.isEmpty || !frameworks.isEmpty else { continue }
                let sdks = roots.sorted().flatMap { vendorSDKs[variantKey($0, platformName)] ?? [] }
                guard !sdks.isEmpty else { continue }
                if destinations[platformName] == nil {
                    destinations[platformName] = NativeSwiftPackageCompileSettings.destinations(
                        platformName, sdkContext: linkerSDKContext)
                }
                for sdk in sdks {
                    if sdk.isFramework,
                        let root = frameworks[(sdk.productName as NSString).deletingPathExtension.lowercased()]
                    {
                        throw Diagnostic(
                            "SP-XCODE-MODULE-CONFLICT", stage: "integrate",
                            "Pod \(root) and vendored SDK provide the same framework product \(sdk.productName) in \(configuration)",
                            file: target["name"] as? String, dependencyChain: [root, sdk.url.path])
                    }
                    for slice in sdk.slices
                    where (destinations[platformName] ?? []).contains(where: {
                        (slice.platform == $0.platform || slice.platform == "unknown")
                            && (slice.variant == $0.variant || slice.variant == "unknown")
                            && slice.architectures.contains($0.architecture)
                    }) {
                        if vendorModules[sdk.url]?[slice.identifier] == nil {
                            vendorModules[sdk.url, default: [:]][slice.identifier] = try NativeVendorModules.names(
                                slice)
                        }
                        for module in (vendorModules[sdk.url]?[slice.identifier] ?? []).sorted() {
                            guard let root = modules[module.lowercased()] else { continue }
                            throw Diagnostic(
                                "SP-XCODE-MODULE-CONFLICT", stage: "integrate",
                                "Pod \(root) and vendored SDK \(sdk.productName) provide the same module \(module) in \(configuration)",
                                file: target["name"] as? String, dependencyChain: [root, sdk.url.path])
                        }
                    }
                }
            }
        }
    }

    private func podModuleInterface(
        _ variant: NativePodVariant, spec: NativeSpec, inspectModules: Bool
    ) throws -> (names: Set<String>, framework: String?) {
        guard let directory = spec.directory else { return ([], nil) }
        let attributes = try NativeVariantPlan.attributes(spec, names: variant.names, platform: variant.platform)
        let selection = try NativeLibraryFiles(
            spec: spec, names: variant.names, platform: variant.platform, root: directory)
        if selection.files.isEmpty {
            let vendors = try selection.paths("vendored_frameworks") + selection.paths("vendored_libraries")
            // Binary-only pods do not generate a source module or a framework wrapper.
            if !vendors.isEmpty { return ([], nil) }
        }
        let framework = variant.mode == "library" ? nil : spec.moduleName
        guard inspectModules else { return ([], framework) }
        let supplementary = try variant.supplementary.flatMap { request in
            try NativeFileSelection.sourceFiles(
                spec.supplementaryAttributes(request.name, platform: variant.platform), root: directory)
        }
        let sources = selection.files + supplementary
        var names: Set<String> =
            selection.files.contains(where: { $0.pathExtension == "swift" }) ? [spec.moduleName] : []
        if let path = attributes["module_map"] as? String {
            try NativeSpecPaths.validatePath(path, stage: "integrate")
            let map = directory.appendingPathComponent(path).standardizedFileURL
            guard FileManager.default.fileExists(atPath: map.path) else {
                throw Diagnostic("SP-SPEC-MODULEMAP", stage: "integrate", "Module map does not exist", file: map.path)
            }
            let contents = try String(contentsOf: map, encoding: .utf8)
            names.formUnion(try NativeClangModuleMap(contents).modules.map { $0.name.components(separatedBy: ".")[0] })
        } else if requiresModule(variant, attributes: attributes, sources: sources) {
            let config = NativeSpec.xcconfig(attributes, key: "pod_target_xcconfig")
            if attributes["module_map"] as? Bool != false || config["MODULEMAP_FILE"] != nil {
                names.insert(spec.moduleName)
            }
        }
        return (names, framework)
    }
}
