import Foundation

extension NativeXcode {
    /// Builds one library variant and its headers, resources and binary dependencies.
    func generateLibraryTarget(_ variant: NativePodVariant) throws {
        selectVariant(variant)
        let platform = variant.platform
        let name = variant.root
        guard let spec = resolution.specs[name], let directory = spec.directory else { return }
        let requests = try variant.names.map {
            try NativeDependency(["name": $0], platform: platform, deployment: variant.consumerDeployment)
        }
        let attributes = try NativeVariantPlan.attributes(spec, names: variant.names, platform: platform)
        let selection = try NativeLibraryFiles(spec: spec, names: variant.names, platform: platform, root: directory)
        let sdks = vendorSDKs[variant.key] ?? []
        // A binary-only pod must not produce an empty framework that shadows its SDK's module
        // or collides with the product extracted by Xcode's ProcessXCFramework step.
        let binaryOnly = selection.files.isEmpty && !sdks.isEmpty
        let targetName = variant.label
        var module = spec.moduleName
        if attributes["module_name"] == nil, module.first?.isNumber == true { module = "_" + module }
        guard module.range(of: #"\A[A-Za-z_][A-Za-z0-9_]*\z"#, options: .regularExpression) != nil else {
            throw Diagnostic("SP-XCODE-MODULE", stage: "integrate", "Invalid module name", file: name)
        }
        let mode = variant.mode
        let useFramework = mode != "library" && !binaryOnly
        let dynamic = useFramework && mode == "dynamic"
        var productName = useFramework ? module : targetName
        if binaryOnly {
            // Linker search paths can expose SDKs and products from other pods.
            var reservedNames = Set(
                vendorSDKs.values.flatMap { $0 }.filter { !$0.isFramework }.map {
                    ($0.productName as NSString).deletingPathExtension.lowercased()
                })
            reservedNames.formUnion(
                (variantPlan?.variants.values.filter { $0.key != variant.key } ?? []).map {
                    ("lib" + $0.label).lowercased()
                })
            reservedNames.formUnion(products.compactMap {
                (graph.objects[$0]?["path"] as? String).map { ($0 as NSString).deletingPathExtension.lowercased() }
            })
            while reservedNames.contains(("lib" + productName).lowercased()) { productName += "-SwiftPods" }
        }
        let productFilename = useFramework ? module + ".framework" : "lib" + productName + ".a"
        let minimum =
            (attributes["platforms"] as? [String: Any])?[platform] as? String ?? attributes["deployment_target"]
            as? String ?? variant.consumerDeployment
        var settings = baseSettings(platform: platform, deployment: minimum)
        settings["HEADERMAP_INCLUDES_PROJECT_HEADERS"] = "NO"
        if variant.scoped {
            settings["CONFIGURATION_BUILD_DIR"] =
                "$(BUILD_DIR)/$(CONFIGURATION)$(EFFECTIVE_PLATFORM_NAME)/" + targetName
        }
        if let arc = attributes["requires_arc"] as? Bool { settings["CLANG_ENABLE_OBJC_ARC"] = arc ? "YES" : "NO" }
        settings.merge(NativeSpec.xcconfig(attributes, key: "pod_target_xcconfig")) { _, new in new }
        if variant.applicationExtensionAPIOnly { settings["APPLICATION_EXTENSION_API_ONLY"] = "YES" }
        if variant.scoped && dynamic {
            // Xcode's shared intermediate TBD directory uses the module
            // name, so its stub can shadow a different static variant.
            settings["GENERATE_INTERMEDIATE_TEXT_BASED_STUBS"] = "NO"
            settings["EAGER_LINKING"] = "NO"
        }
        settings["PRODUCT_NAME"] = productName
        settings["PRODUCT_MODULE_NAME"] = module
        settings["PODS_ROOT"] = NativeBuildSetting.scalarLiteral(project.appendingPathComponent("Pods").path)
        settings["PODS_PODFILE_DIR_PATH"] = NativeBuildSetting.scalarLiteral(project.path)
        settings["PODS_TARGET_SRCROOT"] = NativeBuildSetting.scalarLiteral(directory.path)
        settings["PRODUCT_BUNDLE_IDENTIFIER"] = "org.swiftpods." + module.replacingOccurrences(of: "_", with: "-")
        settings["SWIFT_VERSION"] = variant.swiftVersion ?? "5.0"
        if inhibitWarnings(variant) {
            settings["GCC_WARN_INHIBIT_ALL_WARNINGS"] = "YES"
            settings["SWIFT_SUPPRESS_WARNINGS"] = "YES"
            // Swift rejects combining -suppress-warnings with -warnings-as-errors.
            // Honor the manifest's explicit opt-in for this SDK only.
            settings["SWIFT_TREAT_WARNINGS_AS_ERRORS"] = "NO"
        }
        if manifest["set_arc_compatibility_flag"] as? Bool == true, attributes["requires_arc"] as? Bool != false {
            let flags = nativeStrings(settings["OTHER_LDFLAGS"])
            settings["OTHER_LDFLAGS"] = (flags.isEmpty ? ["$(inherited)"] : flags) + ["-fobjc-arc"]
        }
        if useFramework { settings["MACH_O_TYPE"] = dynamic ? "mh_dylib" : "staticlib" }
        if dynamic { settings["LD_DYLIB_INSTALL_NAME"] = "@rpath/$(EXECUTABLE_PATH)" }
        if !selection.compilerFlags.isEmpty {
            let flags = nativeStrings(settings["OTHER_CFLAGS"])
            settings["OTHER_CFLAGS"] =
                (flags.isEmpty ? ["$(inherited)"] : flags) + selection.compilerFlags
        }
        let all = selection.files
        let supplementarySources = try variant.supplementary.flatMap { request -> [URL] in
            let own = try spec.supplementaryAttributes(request.name, platform: platform)
            return try NativeFileSelection.sourceFiles(own, root: directory)
        }
        let modular =
            !binaryOnly && requiresModule(variant, attributes: attributes, sources: all + supplementarySources)
        let disabledFrameworkMap =
            useFramework && attributes["module_map"] as? Bool == false
            && !all.contains(where: { $0.pathExtension == "swift" }) && settings["MODULEMAP_FILE"] == nil
        settings["DEFINES_MODULE"] = modular && !disabledFrameworkMap ? "YES" : "NO"
        try compileSettings(attributes, root: directory, label: targetName, settings: &settings)
        var sources: [String] = []
        var headers: [String] = []
        for source in all {
            let reference = file(source.path)
            if NativeFileSelection.headers.contains(source.pathExtension) {
                // Archives expose headers through the sandbox's mappings;
                // a Headers phase would flatten them into usr/local/include.
                if useFramework {
                    headers.append(buildFile(reference, target: targetName, settings: selection.headerSettings(source)))
                }
            } else if NativeFileSelection.compilableSources.contains(source.pathExtension) {
                sources.append(buildFile(reference, target: targetName, settings: selection.sourceSettings(source)))
            }
        }
        // Metal emits GPU libraries, not Mach-O objects. A shader-only framework
        // still needs a CPU object for Xcode to create its linkable binary.
        if !all.contains(where: { NativeFileSelection.objectSources.contains($0.pathExtension) }) {
            let dummy = project.appendingPathComponent("Pods/Target Support Files/" + targetName + "/dummy.m")
            try FileManager.default.createDirectory(
                at: dummy.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("void swiftpods_\(module)_dummy(void) {}\n".utf8).writeIfChanged(to: dummy)
            sources.append(buildFile(file(dummy.path), target: targetName))
        }
        let linkedFrameworks = nativeStrings(attributes["frameworks"])
        let weakFrameworks = nativeStrings(attributes["weak_frameworks"])
        var frameworks = (dynamic ? linkedFrameworks + weakFrameworks : []).map { framework in
            buildFile(
                file(
                    "System/Library/Frameworks/" + framework + ".framework", type: "wrapper.framework",
                    sourceTree: "SDKROOT"), target: targetName,
                settings: weakFrameworks.contains(framework) ? ["ATTRIBUTES": ["Weak"]] : [:])
        }
        for sdk in sdks where (dynamic && sdk.dynamic) || sdk.isXCFramework {
            frameworks.append(buildFile(file(sdk.url.path, type: sdk.fileType), target: targetName))
        }
        // Dynamic products force-load static SDKs once; XCFramework references
        // still prepare the selected slice without adding another link input.
        excludeStaticSDKLinkInputs(dynamic ? sdks.filter { !$0.dynamic } : sdks, settings: &settings)
        settings["OTHER_LDFLAGS"] =
            ["$(inherited)"] + nativeStrings(settings["OTHER_LDFLAGS"])
            + (dynamic ? [] : NativeBuildSettings.libraryFlags(
                nativeStrings(attributes["libraries"]), sources: all, settings: settings, linkingWithClang: false))
        if dynamic && sdks.contains(where: { !$0.dynamic }) {
            let flags = nativeStrings(settings["OTHER_LDFLAGS"])
            if !flags.contains("-ObjC") { settings["OTHER_LDFLAGS"] = flags + ["-ObjC"] }
        }
        // Recursive pod-root search would expose headers from every
        // XCFramework slice, bypassing Xcode's destination selection.
        let headerDirectories = Set(
            all.filter { NativeFileSelection.headers.contains($0.pathExtension) }.map {
                $0.deletingLastPathComponent().path
            }
        ).sorted()
        for (key, paths) in [
            "HEADER_SEARCH_PATHS": [
                directory.path, project.appendingPathComponent(headerDirectory(name, platform: platform)).path,
            ] + headerDirectories + sdks.filter { !$0.isXCFramework }.compactMap { $0.slices.first?.headers?.path },
            "FRAMEWORK_SEARCH_PATHS": sdks.filter { !$0.isXCFramework && $0.isFramework }.map {
                $0.url.deletingLastPathComponent().path
            },
            "LIBRARY_SEARCH_PATHS": sdks.filter { !$0.isXCFramework && !$0.isFramework }.map {
                $0.url.deletingLastPathComponent().path
            },
        ] {
            var values = nativeStrings(settings[key])
            if values.isEmpty { values = ["$(inherited)"] }
            for path in paths.map(NativeBuildSetting.literalPath) where !values.contains(path) { values.append(path) }
            settings[key] = values
        }
        if !useFramework {
            try installLibraryHeaders(
                variant, attributes: attributes, selection: selection,
                moduleAttributes: spec.attributes(spec.name, platform: platform), directory: directory, module: module,
                modular: modular, settings: &settings)
        }
        if useFramework && attributes["module_map"] == nil {
            let support = project.appendingPathComponent("Pods/Target Support Files/" + targetName)
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            let umbrella = support.appendingPathComponent(module + "-umbrella.h")
            let publicHeaders = selection.publicHeaders.sorted { $0.path < $1.path }
            let includes: [String] = try publicHeaders.map { header in
                let path = try selection.headerPath(header)
                return "#include <" + module + "/" + path + ">"
            }
            let content =
                "#ifdef __OBJC__\n#import <Foundation/Foundation.h>\n#endif\n"
                + includes.joined(separator: "\n") + "\n"
            try Data(umbrellaHeader(content, variant: variant).utf8).writeIfChanged(to: umbrella, options: .atomic)
            headers.append(buildFile(file(umbrella.path), target: targetName, settings: ["ATTRIBUTES": ["Public"]]))
            let modulemap = support.appendingPathComponent(module + ".modulemap")
            try Data(
                ("framework module " + module + " { umbrella header \"" + umbrella.lastPathComponent
                    + "\" export * module * { export * } }\n").utf8
            ).writeIfChanged(to: modulemap, options: .atomic)
            settings["MODULEMAP_FILE"] = NativeBuildSetting.literal(modulemap.path)
        }
        if useFramework, let additional = attributes["info_plist"] as? [String: Any] {
            let info = project.appendingPathComponent("Pods/Target Support Files/" + targetName + "/Info.plist")
            try FileManager.default.createDirectory(
                at: info.deletingLastPathComponent(), withIntermediateDirectories: true)
            var plist: [String: Any] = [
                "CFBundleExecutable": "$(EXECUTABLE_NAME)", "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)",
                "CFBundleName": "$(PRODUCT_NAME)", "CFBundlePackageType": "FMWK", "CFBundleVersion": "1",
                "CFBundleShortVersionString": spec.version.description,
            ]
            plist.merge(additional) { _, new in new }
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).writeIfChanged(
                to: info, options: .atomic)
            settings["INFOPLIST_FILE"] = NativeBuildSetting.literal(info.path)
            settings["GENERATE_INFOPLIST_FILE"] = "NO"
        }
        let product = graph.add(
            "product:" + targetName,
            [
                "isa": "PBXFileReference", "explicitFileType": useFramework ? "wrapper.framework" : "archive.ar",
                "path": productFilename,
                "sourceTree": "BUILT_PRODUCTS_DIR",
            ])
        products.append(product)
        productRoots[product] = name
        productPlatforms[product] = platform
        productVariants[product] = variant.key
        productBuildPaths[product] =
            (variant.scoped ? targetName + "/" : "")
            + productFilename
        let list = configList(targetName, settings: settings)
        let identifier = graph.add(
            "target:" + targetName,
            [
                "isa": "PBXNativeTarget", "name": targetName, "productName": productName, "productReference": product,
                "productType": useFramework
                    ? "com.apple.product-type.framework" : "com.apple.product-type.library.static",
                "buildConfigurationList": list,
                "buildPhases": [
                    phase("PBXHeadersBuildPhase", target: targetName, files: headers),
                    phase("PBXSourcesBuildPhase", target: targetName, files: sources),
                    phase("PBXFrameworksBuildPhase", target: targetName, files: frameworks),
                ], "buildRules": [], "dependencies": [],
            ])
        var scriptRequests = Set<String>()
        let scripts = try requests.filter { scriptRequests.insert($0.name).inserted }.flatMap {
            try spec.scriptPhases(for: $0)
        }
        targetIDs.append(identifier)
        targetOwners[identifier] = name
        libraryTargets[variantKey(name, platform)] = identifier
        if useFramework {
            let paths = try Dictionary(
                uniqueKeysWithValues: selection.publicHeaders.union(selection.privateHeaders).map {
                    ($0, try selection.headerPath($0))
                })
            try mapFrameworkHeaders(
                selection.publicHeaders, paths: paths, target: identifier, label: targetName,
                visibility: .publicHeaders)
            try mapFrameworkHeaders(
                selection.privateHeaders, paths: paths, target: identifier, label: targetName,
                visibility: .privateHeaders)
        }
        NativeScriptPhase.apply(scripts, target: identifier, graph: graph)
        let directPaths = try selection.paths("resources")
        if dynamic {
            let refs = try NativeResources.references(directPaths, owner: targetName, graph: graph)
            if !refs.isEmpty {
                var phases = graph.objects[identifier]?["buildPhases"] as? [String] ?? []
                phases.append(
                    phase(
                        "PBXResourcesBuildPhase", target: targetName,
                        files: refs.map { buildFile($0, target: targetName) }))
                graph.objects[identifier]?["buildPhases"] = phases
            }
        } else {
            staticResources[variantKey(name, platform)] = directPaths
        }
        var bundleProducts = Set<String>()
        for (bundle, paths) in try selection.resourceBundles().sorted(by: { $0.key < $1.key }) {
            guard bundle.range(of: #"\A[A-Za-z0-9_][A-Za-z0-9_.+-]*\z"#, options: .regularExpression) != nil else {
                throw Diagnostic(
                    "SP-XCODE-RESOURCE", stage: "integrate", "Invalid resource bundle name", file: name)
            }
            guard bundleProducts.insert(bundle.lowercased()).inserted else {
                throw Diagnostic(
                    "SP-XCODE-RESOURCE", stage: "integrate", "Resource bundle product name is already used",
                    file: bundle)
            }
            let bundleIdentity = try resourceBundleIdentity(bundle, variant: variant.key, owner: name)
            let bundleLabel = resourceBundleLabels[bundleIdentity] ?? targetName + "-" + bundle
            let resourceReferences = try NativeResources.references(
                paths, owner: bundleLabel,
                graph: graph)
            let resources = resourceReferences.map { buildFile($0, target: bundleLabel) }
            let bundleProduct = graph.add(
                "resource-bundle-product:" + bundleIdentity,
                [
                    "isa": "PBXFileReference", "explicitFileType": "wrapper.cfbundle", "path": bundle + ".bundle",
                    "sourceTree": "BUILT_PRODUCTS_DIR",
                ])
            var bundleSettings = baseSettings(platform: platform, deployment: minimum).merging([
                "PRODUCT_NAME": bundle, "PRODUCT_BUNDLE_IDENTIFIER": "org.swiftpods.$(PRODUCT_NAME:rfc1034identifier)",
            ]) { _, new in new }
            bundleSettings["CONFIGURATION_BUILD_DIR"] =
                "$(BUILD_DIR)/$(CONFIGURATION)$(EFFECTIVE_PLATFORM_NAME)/" + targetName
            try resourceBundleInfoPlist(bundleLabel, settings: &bundleSettings)
            let bundleTarget = graph.add(
                "resource-bundle-target:" + bundleIdentity,
                [
                    "isa": "PBXNativeTarget", "name": bundleLabel, "productName": bundle,
                    "productReference": bundleProduct, "productType": "com.apple.product-type.bundle",
                    "buildConfigurationList": configList(bundleLabel, settings: bundleSettings),
                    "buildPhases": [phase("PBXResourcesBuildPhase", target: bundleLabel, files: resources)],
                    "buildRules": [], "dependencies": [],
                ])
            products.append(bundleProduct)
            productPlatforms[bundleProduct] = platform
            targetIDs.append(bundleTarget)
            targetOwners[bundleTarget] = name
            self.resources.append(bundle + ".bundle")
            resourceBundleRoots[bundleProduct] = name
            productVariants[bundleProduct] = variant.key
            resourceBundleTargets[variant.key, default: []].append(bundleTarget)
            productBuildPaths[bundleProduct] = targetName + "/" + bundle + ".bundle"
            let resourceDependency = graph.add(
                "dependency:" + identifier + ":" + bundleTarget,
                ["isa": "PBXTargetDependency", "target": bundleTarget])
            var resourceDependencies = graph.objects[identifier]?["dependencies"] as? [String] ?? []
            resourceDependencies.append(resourceDependency)
            graph.objects[identifier]?["dependencies"] = resourceDependencies
            if dynamic {
                frameworkResourceBundles.insert(bundleProduct)
                var phases = graph.objects[identifier]?["buildPhases"] as? [String] ?? []
                let resourcePhase =
                    phases.first { graph.objects[$0]?["isa"] as? String == "PBXResourcesBuildPhase" }
                    ?? phase("PBXResourcesBuildPhase", target: targetName, files: [])
                var files = graph.objects[resourcePhase]?["files"] as? [String] ?? []
                files.append(buildFile(buildReference(bundleProduct), target: targetName))
                graph.objects[resourcePhase]?["files"] = files
                if !phases.contains(resourcePhase) { phases.append(resourcePhase) }
                graph.objects[identifier]?["buildPhases"] = phases
            }
        }
    }
}
