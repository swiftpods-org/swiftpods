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

    /// Modules may share a name only across separate consumers or configurations.
    func validateModules() throws {
        let previous = activeVariants
        defer { activeVariants = previous }
        var libraryModules: [String: Bool] = [:]
        for target in manifest["targets"] as? [[String: Any]] ?? [] {
            selectConsumer(target)
            let platform = target["platform"] as? [String: String] ?? [:]
            let requests = try nativeDependencies(target).flatMap {
                try NativeDependency(
                    $0, platform: platform["name"] ?? "ios", deployment: platform["deployment_target"] ?? "0"
                )
                .expandedSelections()
            }
            for configuration in configurationNames {
                let roots = try dependencyRoots(requests.filter { dependencyEnabled($0, configuration: configuration) })
                var modules: [String: String] = [:]
                for root in roots.sorted() {
                    guard let spec = resolution.specs[root],
                        let variant = variantPlan?.variants[variantKey(root, platform["name"] ?? "ios")]
                    else { continue }
                    if variant.mode == "library" {
                        if libraryModules[variant.key] == nil {
                            libraryModules[variant.key] = try exportsLibraryModule(variant, spec: spec)
                        }
                        guard libraryModules[variant.key] == true else { continue }
                    }
                    let module = spec.moduleName.lowercased()
                    if let other = modules[module], other != root {
                        throw Diagnostic(
                            "SP-XCODE-MODULE-CONFLICT", stage: "integrate",
                            "Pods \(other) and \(root) provide the same module \(spec.moduleName) in \(configuration)",
                            file: target["name"] as? String)
                    }
                    modules[module] = root
                }
            }
        }
    }

    private func exportsLibraryModule(_ variant: NativePodVariant, spec: NativeSpec) throws -> Bool {
        guard let directory = spec.directory else { return false }
        let attributes = try NativeVariantPlan.attributes(spec, names: variant.names, platform: variant.platform)
        let selection = try NativeLibraryFiles(
            spec: spec, names: variant.names, platform: variant.platform, root: directory)
        if selection.files.isEmpty {
            let vendors = try selection.paths("vendored_frameworks") + selection.paths("vendored_libraries")
            // Binary-only pods do not generate a source module for their archive wrapper.
            if !vendors.isEmpty { return false }
        }
        let supplementary = try variant.supplementary.flatMap { request in
            try NativeFileSelection.sourceFiles(
                spec.supplementaryAttributes(request.name, platform: variant.platform), root: directory)
        }
        let sources = selection.files + supplementary
        if selection.files.contains(where: { $0.pathExtension == "swift" }) { return true }
        guard requiresModule(variant, attributes: attributes, sources: sources) else { return false }
        let config = NativeSpec.xcconfig(attributes, key: "pod_target_xcconfig")
        return attributes["module_map"] as? Bool != false || config["MODULEMAP_FILE"] != nil
    }
}
