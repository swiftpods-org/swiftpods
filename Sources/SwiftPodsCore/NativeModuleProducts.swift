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
        var interfaces: [String: (names: Set<String>, framework: String?, swiftModule: String?)] = [:]
        var vendorModules: [URL: [String: Set<String>]] = [:]
        var destinations: [String: [NativeSwiftPackageCompileSettings.Destination]] = [:]
        for target in manifest["targets"] as? [[String: Any]] ?? [] {
            selectConsumer(target)
            let platform = target["platform"] as? [String: String] ?? [:]
            let platformName = platform["name"] ?? "ios"
            let searchRequests = try nativeDependencies(target, search: true).flatMap {
                try NativeDependency(
                    $0, platform: platformName, deployment: platform["deployment_target"] ?? "0"
                ).expandedSelections()
            }
            let configured = try configuredDependencyRoots(target)
            let eligible = configured.values.reduce(into: Set<String>()) { $0.formUnion($1) }
            let inherited = try dependencyRoots(searchRequests).subtracting(eligible)
            for configuration in configurationNames {
                let roots = (configured[configuration] ?? []).union(inherited)
                var frameworks: [String: String] = [:]
                var modules: [String: String] = [:]
                var swiftFiles: [String: String] = [:]
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
                    if let file = interface.swiftModule {
                        if let other = swiftFiles[file.lowercased()], other != root {
                            throw Diagnostic(
                                "SP-XCODE-MODULE-CONFLICT", stage: "integrate",
                                "Pods \(other) and \(root) produce the same Swift module file \(file) in \(configuration)",
                                file: target["name"] as? String)
                        }
                        swiftFiles[file.lowercased()] = root
                    }
                    for module in interface.names.sorted() {
                        if let other = modules[module], other != root {
                            throw Diagnostic(
                                "SP-XCODE-MODULE-CONFLICT", stage: "integrate",
                                "Pods \(other) and \(root) provide the same module \(module) in \(configuration)",
                                file: target["name"] as? String)
                        }
                        modules[module] = root
                    }
                }
                guard inspectInterfaces else { continue }
                var seenSDKs = Set<URL>()
                let sdks = roots.sorted().flatMap { vendorSDKs[variantKey($0, platformName)] ?? [] }
                    .filter { seenSDKs.insert($0.url).inserted }
                guard !sdks.isEmpty else { continue }
                if destinations[platformName] == nil {
                    destinations[platformName] = NativeSwiftPackageCompileSettings.destinations(
                        platformName, sdkContext: linkerSDKContext)
                }
                let selectedDestinations = destinations[platformName] ?? []
                var binaryModules = selectedDestinations.map { _ in [String: URL]() }
                for sdk in sdks {
                    if sdk.isFramework,
                        let root = frameworks[(sdk.productName as NSString).deletingPathExtension.lowercased()]
                    {
                        throw Diagnostic(
                            "SP-XCODE-MODULE-CONFLICT", stage: "integrate",
                            "Pod \(root) and vendored SDK provide the same framework product \(sdk.productName) in \(configuration)",
                            file: target["name"] as? String, dependencyChain: [root, sdk.url.path])
                    }
                    for (index, destination) in selectedDestinations.enumerated() {
                        for slice in sdk.slices
                        where (slice.platform == destination.platform || slice.platform == "unknown")
                            && (slice.variant == destination.variant || slice.variant == "unknown")
                            && slice.architectures.contains(destination.architecture)
                        {
                            if vendorModules[sdk.url]?[slice.identifier] == nil {
                                vendorModules[sdk.url, default: [:]][slice.identifier] = try NativeVendorModules.names(
                                    slice)
                            }
                            for module in (vendorModules[sdk.url]?[slice.identifier] ?? []).sorted() {
                                if let root = modules[module] {
                                    throw Diagnostic(
                                        "SP-XCODE-MODULE-CONFLICT", stage: "integrate",
                                        "Pod \(root) and vendored SDK \(sdk.productName) provide the same module \(module) in \(configuration)",
                                        file: target["name"] as? String, dependencyChain: [root, sdk.url.path])
                                }
                                if let owner = binaryModules[index][module], owner != sdk.url {
                                    throw Diagnostic(
                                        "SP-XCODE-MODULE-CONFLICT", stage: "integrate",
                                        "Vendored SDKs provide the same module \(module) in \(configuration) for \(destination.sdk)/\(destination.architecture)",
                                        file: target["name"] as? String, dependencyChain: [owner.path, sdk.url.path])
                                }
                                binaryModules[index][module] = sdk.url
                            }
                        }
                    }
                }
            }
        }
    }

    private func podModuleInterface(
        _ variant: NativePodVariant, spec: NativeSpec, inspectModules: Bool
    ) throws -> (names: Set<String>, framework: String?, swiftModule: String?) {
        guard let directory = spec.directory else { return ([], nil, nil) }
        let attributes = try NativeVariantPlan.attributes(spec, names: variant.names, platform: variant.platform)
        let selection = try NativeLibraryFiles(
            spec: spec, names: variant.names, platform: variant.platform, root: directory)
        let vendors = try selection.paths("vendored_frameworks") + selection.paths("vendored_libraries")
        let binaryOnly = selection.files.isEmpty && !vendors.isEmpty
        let framework = variant.mode == "library" || binaryOnly ? nil : spec.moduleName
        guard inspectModules else { return ([], framework, nil) }
        let supplementary = try variant.supplementary.flatMap { request in
            try NativeFileSelection.sourceFiles(
                spec.supplementaryAttributes(request.name, platform: variant.platform), root: directory)
        }
        let sources = selection.files + supplementary
        let swift = selection.files.contains(where: { $0.pathExtension == "swift" })
        let swiftModule =
            swift && variant.mode == "library"
            ? (variant.scoped ? variant.label + "/" : "") + spec.moduleName + ".swiftmodule" : nil
        var names: Set<String> = swift ? [spec.moduleName] : []
        if let path = attributes["module_map"] as? String {
            try NativeSpecPaths.validatePath(path, stage: "integrate")
            let map = directory.appendingPathComponent(path).standardizedFileURL
            guard FileManager.default.fileExists(atPath: map.path) else {
                throw Diagnostic("SP-SPEC-MODULEMAP", stage: "integrate", "Module map does not exist", file: map.path)
            }
            let contents = try String(contentsOf: map, encoding: .utf8)
            names.formUnion(try NativeClangModuleMap(contents).modules.map { $0.name.components(separatedBy: ".")[0] })
        } else if !binaryOnly && requiresModule(variant, attributes: attributes, sources: sources) {
            let config = NativeSpec.xcconfig(attributes, key: "pod_target_xcconfig")
            if attributes["module_map"] as? Bool != false || config["MODULEMAP_FILE"] != nil {
                names.insert(spec.moduleName)
            }
        }
        return (names, framework, swiftModule)
    }
}
