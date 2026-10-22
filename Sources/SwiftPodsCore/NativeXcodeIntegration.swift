import Foundation

extension NativeXcode {
    func integrate() throws -> [URL] {
        let workspaceUpdates = try prepareWorkspaces()
        var written = try removeOmittedConsumers()
        var packageRecords = integrationSettings["_swift_packages"] as? [String: [String: Any]] ?? [:]
        var packages: [String: NativeSwiftPackageIntegrator] = [:]
        for (path, user) in userProjects {
            let integrator = NativeSwiftPackageIntegrator()
            try integrator.prepare(user, record: packageRecords[path])
            packages[path] = integrator
        }
        var originalAttributes: [String: [String: Any]] = [:]
        var swiftRuntimePath: String?
        let previousAttributes = integrationSettings["_project_attributes"] as? [String: [String: Any]] ?? [:]
        for user in userProjects.values {
            try removePreviousAggregateIntegration(user)
            if let root = user.root["rootObject"] as? String {
                let current = user.objects[root]?["attributes"] as? [String: Any] ?? [:]
                let restored = try NativeIntegrationSettings.restore(
                    current, record: previousAttributes[user.url.path] ?? [:])
                user.objects[root]?["attributes"] = restored
                originalAttributes[user.url.path] = restored
            }
        }
        for target in manifest["targets"] as? [[String: Any]] ?? [] {
            selectConsumer(target)
            let path = try projectPath(target)
            let name = target["name"] as? String ?? ""
            guard let user = userProjects[path.path],
                let targetID = user.objects.first(where: {
                    $0.value["isa"] as? String == "PBXNativeTarget" && $0.value["name"] as? String == name
                })?.key
            else {
                throw Diagnostic(
                    "SP-XCODE-TARGET", stage: "integrate", "Target \(name) does not exist", file: path.path)
            }
            let group = (user.root["rootObject"] as? String).flatMap { user.objects[$0]?["mainGroup"] as? String }
            let platform = target["platform"] as? [String: String] ?? [:]
            let searchRequests = try nativeDependencies(target, search: true).flatMap {
                try NativeDependency(
                    $0, platform: platform["name"] ?? "ios", deployment: platform["deployment_target"] ?? "0"
                ).expandedSelections()
            }
            let configuredRoots = try configuredDependencyRoots(target)
            let eligibleRoots = configuredRoots.values.reduce(into: Set<String>()) { $0.formUnion($1) }
            let searchRoots = try dependencyRoots(searchRequests).union(eligibleRoots)
            if let aggregate = aggregateTargets[nativeConsumerKey(target)] {
                let portal = user.add(
                    "swiftpods:pods-project",
                    user.relativeFileReference(
                        project.appendingPathComponent("Pods/Pods.xcodeproj"), type: "wrapper.pb-project"))
                let label = target["label"] as? String ?? "Pods-" + name
                let proxy = user.add(
                    "swiftpods:aggregate-proxy:" + targetID,
                    [
                        "isa": "PBXContainerItemProxy", "containerPortal": portal, "proxyType": "1",
                        "remoteGlobalIDString": aggregate, "remoteInfo": label,
                    ])
                let dependency = user.add(
                    "swiftpods:aggregate-dependency:" + targetID,
                    ["isa": "PBXTargetDependency", "name": label, "targetProxy": proxy])
                var dependencies = user.objects[targetID]?["dependencies"] as? [String] ?? []
                if !dependencies.contains(dependency) { dependencies.append(dependency) }
                user.objects[targetID]?["dependencies"] = dependencies
                if let group {
                    var children = user.objects[group]?["children"] as? [String] ?? []
                    if !children.contains(portal) { children.append(portal) }
                    user.objects[group]?["children"] = children
                }
            }
            removePreviousVariantDependencies(user, target: targetID)
            let targetSDKs = eligibleRoots.sorted().flatMap {
                vendorSDKs[variantKey($0, platform["name"] ?? "ios")] ?? []
            }
            let searchSDKs = searchRoots.sorted().flatMap {
                vendorSDKs[variantKey($0, platform["name"] ?? "ios")] ?? []
            }
            let usesSwift = eligibleRoots.contains {
                activeVariants[$0].flatMap { variantPlan?.variants[$0] }?.swiftVersion != nil
            }
            if usesSwift && swiftRuntimePath == nil { swiftRuntimePath = try swiftRuntimeSearchPath() }
            try validateExistingPackages(
                user, target: targetID, roots: eligibleRoots, platform: platform["name"] ?? "ios")
            var sdkNames: [String: String] = [:]
            for sdk in targetSDKs {
                if let before = sdkNames[sdk.productName], before != sdk.url.path {
                    throw Diagnostic(
                        "SP-DUPLICATE-SDK", stage: "integrate", "Two vendored SDKs supply \(sdk.productName)",
                        file: sdk.url.path)
                }
                sdkNames[sdk.productName] = sdk.url.path
            }
            removeConsumerProductLinks(user, target: targetID)
            var phases = user.objects[targetID]?["buildPhases"] as? [String] ?? []
            let frameworkPhase =
                phases.first { user.objects[$0]?["isa"] as? String == "PBXFrameworksBuildPhase" }
                ?? user.add(
                    "swiftpods:frameworkphase:" + targetID,
                    [
                        "isa": "PBXFrameworksBuildPhase", "buildActionMask": "2147483647",
                        "runOnlyForDeploymentPostprocessing": "0", "files": [],
                    ])
            if !phases.contains(frameworkPhase) { phases.append(frameworkPhase) }
            let check = user.add(
                "swiftpods:manifest:" + targetID,
                [
                    "isa": "PBXShellScriptBuildPhase", "name": "[CP] Check Pods Manifest.lock",
                    "buildActionMask": "2147483647", "runOnlyForDeploymentPostprocessing": "0", "files": [],
                    "inputPaths": ["$(PODS_PODFILE_DIR_PATH)/Podfile.lock", "$(PODS_ROOT)/Manifest.lock"],
                    "outputPaths": ["$(DERIVED_FILE_DIR)/swiftpods-manifest.txt"], "shellPath": "/bin/sh",
                    "shellScript":
                        "set -eu\ncmp \"${PODS_PODFILE_DIR_PATH}/Podfile.lock\" \"${PODS_ROOT}/Manifest.lock\"\nprintf OK > \"${SCRIPT_OUTPUT_FILE_0}\"\n",
                ])
            if !phases.contains(check) { phases.insert(check, at: 0) }
            user.objects[targetID]?["buildPhases"] = phases
            let configuredOnDemand = try configuredRoots.mapValues {
                try onDemandResources(roots: $0, platform: platform["name"] ?? "ios")
            }
            let resourcePlan =
                try consumerResourcePlans[nativeConsumerKey(target)]
                ?? NativeConditionalResources(directory: project, normal: [:], configurations: [:])
            try NativeResources.apply(
                (consumerNativeResources[nativeConsumerKey(target)] ?? []) + bridgeSupportResource(target),
                target: targetID, graph: user, allowMissing: Set(bridgeSupportResource(target)),
                ungrouped: Set(resourcePlan.onDemand.files.keys))
            resourcePlan.onDemand.tag(target: targetID, graph: user)
            try integrateConsumerCopies(target, targetID: targetID, configured: configuredRoots, user: user)
            NativeScriptPhase.apply(try NativeScriptPhase.parse(target["script_phases"]), target: targetID, graph: user)
            applyInputOutputOptions(targetID, graph: user)
            let list = user.objects[targetID]?["buildConfigurationList"] as? String
            for config in list.flatMap({ user.objects[$0]?["buildConfigurations"] as? [String] }) ?? [] {
                let recordKey = path.path + ":" + config
                let original = try NativeIntegrationSettings.restore(
                    user.objects[config]?["buildSettings"] as? [String: Any] ?? [:],
                    record: integrationSettings[recordKey] as? [String: Any] ?? [:])
                var settings = original
                let configuration = user.objects[config]?["name"] as? String ?? "Debug"
                settings.merge(configuredOnDemand[configuration]?.buildSettings ?? [:]) { _, new in new }
                for key in ["FRAMEWORK_SEARCH_PATHS", "LIBRARY_SEARCH_PATHS", "SWIFT_INCLUDE_PATHS"] {
                    var values = nativeStrings(settings[key])
                    if values.isEmpty { values = ["$(inherited)"] }
                    if !values.contains("$(BUILT_PRODUCTS_DIR)") { values.append("$(BUILT_PRODUCTS_DIR)") }
                    for directory in librarySearchDirectories(searchRoots, platform: platform["name"] ?? "ios")
                    where !values.contains(directory) { values.append(directory) }
                    settings[key] = values
                }
                for (key, paths) in [
                    "FRAMEWORK_SEARCH_PATHS": searchSDKs.filter { !$0.isXCFramework && $0.isFramework }.map {
                        $0.url.deletingLastPathComponent().path
                    },
                    "LIBRARY_SEARCH_PATHS": searchSDKs.filter { !$0.isXCFramework && !$0.isFramework }.map {
                        $0.url.deletingLastPathComponent().path
                    },
                    "HEADER_SEARCH_PATHS": searchSDKs.filter { !$0.isXCFramework }.compactMap {
                        $0.slices.first?.headers?.path
                    },
                ] {
                    var values = nativeStrings(settings[key])
                    if values.isEmpty { values = ["$(inherited)"] }
                    let additions = paths.map {
                        NativeBuildSetting.path(user.buildSettingPath(URL(fileURLWithPath: $0)))
                    }.filter { !values.contains($0) }
                    let index = values.firstIndex(of: "$(BUILT_PRODUCTS_DIR)") ?? values.endIndex
                    values.insert(contentsOf: additions, at: index)
                    settings[key] = values
                }
                if usesSwift, let swiftRuntimePath {
                    // Clang-only consumers do not get Swift's back-deployment search paths from Xcode.
                    var libraries = nativeStrings(settings["LIBRARY_SEARCH_PATHS"])
                    for path in [swiftRuntimePath, "$(SDKROOT)/usr/lib/swift"]
                    where !libraries.contains(path) {
                        libraries.append(path)
                    }
                    settings["LIBRARY_SEARCH_PATHS"] = libraries
                    let wrappers: Set<String> = [
                        "com.apple.product-type.application", "com.apple.product-type.app-extension",
                        "com.apple.product-type.framework", "com.apple.product-type.bundle",
                        "com.apple.product-type.bundle.unit-test", "com.apple.product-type.bundle.ui-testing",
                    ]
                    if wrappers.contains(user.objects[targetID]?["productType"] as? String ?? ""),
                        settings["ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES"] == nil
                    {
                        settings["ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES"] = "YES"
                    }
                }
                var headerPaths = nativeStrings(settings["HEADER_SEARCH_PATHS"])
                if headerPaths.isEmpty { headerPaths = ["$(inherited)"] }
                let publicHeaders = headerSettings(searchRoots, platform: platform["name"] ?? "ios")
                for directory in publicHeaders + searchSDKs.compactMap(consumerSDKHeaders)
                where !headerPaths.contains(directory) { headerPaths.append(directory) }
                settings["HEADER_SEARCH_PATHS"] = headerPaths
                if hasConsumerDynamicProducts(eligibleRoots, platform: platform["name"] ?? "ios") {
                    var runpaths = nativeStrings(settings["LD_RUNPATH_SEARCH_PATHS"])
                    if runpaths.isEmpty { runpaths = ["$(inherited)"] }
                    let frameworkPath =
                        platform["name"] == "osx" ? "@executable_path/../Frameworks" : "@executable_path/Frameworks"
                    if !runpaths.contains(frameworkPath) { runpaths.append(frameworkPath) }
                    settings["LD_RUNPATH_SEARCH_PATHS"] = runpaths
                }
                if settings["ALWAYS_SEARCH_USER_PATHS"] == nil { settings["ALWAYS_SEARCH_USER_PATHS"] = "NO" }
                settings["PODS_ROOT"] = user.buildSettingPath(project.appendingPathComponent("Pods"))
                settings["PODS_PODFILE_DIR_PATH"] = user.buildSettingPath(project)
                if original["GCC_PREPROCESSOR_DEFINITIONS"] == nil
                    || nativeStrings(original["GCC_PREPROCESSOR_DEFINITIONS"]).contains(where: {
                        $0.contains("$(inherited)")
                    })
                {
                    var definitions = nativeStrings(settings["GCC_PREPROCESSOR_DEFINITIONS"])
                    if definitions.isEmpty { definitions = ["$(inherited)"] }
                    if !definitions.contains("COCOAPODS=1") { definitions.append("COCOAPODS=1") }
                    settings["GCC_PREPROCESSOR_DEFINITIONS"] = definitions
                }
                let enabled = configuredRoots[configuration] ?? eligibleRoots
                applyCustomModuleMaps(
                    searchRoots.subtracting(eligibleRoots).union(enabled), platform: platform["name"] ?? "ios",
                    settings: &settings)
                let excludedAssets = Set(
                    try consumerAssetExclusions(
                        eligible: eligibleRoots, enabled: enabled, platform: platform["name"] ?? "ios")
                )
                .union(resourcePlan.exclusions[configuration] ?? []).sorted()
                if !excludedAssets.isEmpty {
                    var exclusions = nativeStrings(settings["EXCLUDED_SOURCE_FILE_NAMES"])
                    if exclusions.isEmpty { exclusions = ["$(inherited)"] }
                    for asset in excludedAssets {
                        // Physical exclusions are absolute; product paths already contain Xcode expressions.
                        let expression =
                            asset.utf8.first == 47 ? user.buildSettingPath(URL(fileURLWithPath: asset)) : asset
                        let value = NativeBuildSetting.quoted(expression)
                        if !exclusions.contains(value) { exclusions.append(value) }
                    }
                    settings["EXCLUDED_SOURCE_FILE_NAMES"] = exclusions
                }
                var linker = nativeStrings(settings["OTHER_LDFLAGS"]).filter { $0 != "$(SWIFTPODS_CONFIG_LDFLAGS)" }
                var configurationValues = user.objects[config]!
                configurationValues["buildSettings"] = settings
                let linkerScope = try NativeBuildSettings.resolvedScopes(
                    configurationValues, graph: user, targetName: name).targetScope
                var linkerSettings = settings
                for key in ["LINK_WITH_STANDARD_LIBRARIES", "CLANG_CXX_LIBRARY", "LD", "LDPLUSPLUS"] {
                    linkerSettings[key] = try linkerScope.expandedValue(key)
                }
                let dependencyFlags = try consumerLinkerFlags(
                    enabled, platform: platform["name"] ?? "ios", sources: [],
                    settings: linkerSettings, hasCXXSources: linkerHasCXXSources(targetID, graph: user))
                if !dependencyFlags.isEmpty {
                    if linker.isEmpty { linker = ["$(inherited)"] }
                    linker += dependencyFlags
                }
                if manifest["set_arc_compatibility_flag"] as? Bool == true,
                    enabled.contains(where: { root in
                        guard let spec = resolution.specs[root],
                            let variant = variantPlan?.variants[variantKey(root, platform["name"] ?? "ios")]
                        else { return false }
                        return
                            (try? NativeVariantPlan.attributes(
                                spec, names: variant.names, platform: platform["name"] ?? "ios")["requires_arc"]
                            as? Bool) != false
                    }), !linker.contains("-fobjc-arc")
                {
                    if linker.isEmpty { linker = ["$(inherited)"] }
                    linker.append("-fobjc-arc")
                }
                let productFlags = try consumerProductLinkerFlags(enabled, platform: platform["name"] ?? "ios")
                if !productFlags.isEmpty {
                    if linker.isEmpty { linker = ["$(inherited)"] }
                    linker += productFlags
                }
                settings.removeValue(forKey: "SWIFTPODS_CONFIG_LDFLAGS")
                if !linker.isEmpty {
                    settings["OTHER_LDFLAGS"] = linker
                } else {
                    settings.removeValue(forKey: "OTHER_LDFLAGS")
                }
                for root in enabled.sorted() {
                    if let spec = resolution.specs[root],
                        let variant = variantPlan?.variants[variantKey(root, platform["name"] ?? "ios")]
                    {
                        let attributes = try NativeVariantPlan.attributes(
                            spec, names: variant.names, platform: platform["name"] ?? "ios")
                        settings = NativeBuildSettings.addingConsumerSettings(
                            NativeSpec.xcconfig(attributes, key: "user_target_xcconfig"), to: settings,
                            original: original)
                    }
                }
                if !searchRoots.isEmpty {
                    settings["SWIFT_INCLUDE_PATHS"] = nativeStrings(settings["SWIFT_INCLUDE_PATHS"]) + publicHeaders
                }
                settings = try consumerConfiguration(
                    target, configuration: config, user: user, recordKey: recordKey, original: original,
                    settings: settings)
                user.objects[config]?["buildSettings"] = settings
                integrationSettings[recordKey] = try NativeIntegrationSettings.record(before: original, after: settings)
            }
            try packages[path.path]!.integrate(
                target["packages"] as? [[String: Any]] ?? [], targetID: targetID, user: user,
                installedModules: podModuleIdentities(eligibleRoots, platform: platform["name"] ?? "ios"))
        }
        var attributeRecords: [String: [String: Any]] = [:]
        for user in userProjects.values {
            if let root = user.root["rootObject"] as? String {
                attributeRecords[user.url.path] = try NativeIntegrationSettings.record(
                    before: originalAttributes[user.url.path] ?? [:],
                    after: user.objects[root]?["attributes"] as? [String: Any] ?? [:])
            }
        }
        integrationSettings["_project_attributes"] = attributeRecords
        for (path, user) in userProjects {
            packageRecords[path] = packages[path]!.finish(user)
            pruneSourceObjects(user)
            pruneVendorObjects(user)
            pruneSupportObjects(user)
            try user.save()
            written.append(user.url)
        }
        integrationSettings["_swift_packages"] = packageRecords
        for update in workspaceUpdates {
            try update.save()
            workspaceFingerprints[update.path.path] = try FileFingerprint.tree(update.path)
            written.append(update.path)
        }
        integrationSettings["_configuration_path_encoding"] = 1
        integrationSettings["_products"] = previousProducts.union(products).sorted()
        try FileManager.default.createDirectory(
            at: integrationSettingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try jsonData(integrationSettings).writeIfChanged(to: integrationSettingsURL, options: .atomic)
        written.append(integrationSettingsURL)
        return written
    }
    private func isVendorBuild(_ id: String, user: NativePBX) -> Bool {
        guard let reference = user.objects[id]?["fileRef"] as? String,
            let key = user.ownedFileKey(reference, prefix: "swiftpods:vendor:")
        else { return false }
        return [NativePBX.identifier(key + ":link"), NativePBX.identifier(key + ":embed")].contains(id)
    }
    private func pruneSourceObjects(_ user: NativePBX) {
        let candidates = previousProducts.union(products)
        let builds = Set(
            candidates.flatMap {
                [NativePBX.identifier("swiftpods:build:" + $0), NativePBX.identifier("swiftpods:embed:" + $0)]
            }
        ).union(
            user.objects.filter { $0.value["isa"] as? String == "PBXNativeTarget" }.keys.flatMap { target in
                candidates.map { NativePBX.identifier("swiftpods:bundle-build:" + target + ":" + $0) }
            })
        let usedBuilds = Set(user.objects.values.flatMap { $0["files"] as? [String] ?? [] })
        for id in builds.subtracting(usedBuilds) { user.objects.removeValue(forKey: id) }
        let usedReferences = Set(user.objects.values.compactMap { $0["fileRef"] as? String })
        for id in candidates.map({ NativePBX.identifier("swiftpods:product:" + $0) }) where !usedReferences.contains(id)
        {
            user.objects.removeValue(forKey: id)
            for group in Array(user.objects.keys) {
                if let children = user.objects[group]?["children"] as? [String] {
                    user.objects[group]?["children"] = children.filter { $0 != id }
                }
            }
        }
    }
    private func pruneSupportObjects(_ user: NativePBX) {
        let prefix = user.url.path + ":"
        let kept = Set(
            (integrationSettings["_support_configurations"] as? [String: String] ?? [:])
                .filter { $0.key.hasPrefix(prefix) }.values)
        for id in user.objects.keys {
            guard user.isGeneratedConfigurationReference(id), !kept.contains(id)
            else { continue }
            let used = user.objects.values.contains { object in
                !["PBXGroup", "PBXVariantGroup"].contains(object["isa"] as? String ?? "")
                    && object.values.contains { ($0 as? String) == id || ($0 as? [String])?.contains(id) == true }
            }
            guard !used else { continue }
            user.objects.removeValue(forKey: id)
            for group in Array(user.objects.keys) {
                if let children = user.objects[group]?["children"] as? [String] {
                    user.objects[group]?["children"] = children.filter { $0 != id }
                }
            }
        }
    }

    private func swiftRuntimeSearchPath() throws -> String {
        // TOOLCHAIN_DIR can select an auxiliary Metal toolchain while Clang links.
        // Locate the selected Swift compiler instead, including custom toolchains.
        let result = try ToolProcess.run("/usr/bin/xcrun", ["--find", "swiftc"])
        guard result.status == 0, let output = String(data: result.output, encoding: .utf8) else {
            throw Diagnostic("SP-SWIFT-TOOLCHAIN", stage: "integrate", "Cannot locate the Swift compiler")
        }
        let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/"), !path.utf8.contains(0) else {
            throw Diagnostic("SP-SWIFT-TOOLCHAIN", stage: "integrate", "Invalid Swift compiler path", file: path)
        }
        let libraries = URL(fileURLWithPath: path).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("lib/swift")
        guard FileManager.default.fileExists(atPath: libraries.path) else {
            throw Diagnostic(
                "SP-SWIFT-TOOLCHAIN", stage: "integrate", "Swift runtime libraries are missing", file: libraries.path)
        }
        return NativeBuildSetting.path(NativeBuildSetting.literal(libraries.path) + "/$(PLATFORM_NAME)")
    }

    private func pruneVendorObjects(_ user: NativePBX) {
        let usedBuilds = Set(user.objects.values.flatMap { $0["files"] as? [String] ?? [] })
        for id in Array(user.objects.keys) where isVendorBuild(id, user: user) && !usedBuilds.contains(id) {
            user.objects.removeValue(forKey: id)
        }
        let usedReferences = Set(user.objects.values.compactMap { $0["fileRef"] as? String })
        for id in user.objects.keys {
            guard user.ownedFileKey(id, prefix: "swiftpods:vendor:") != nil, !usedReferences.contains(id)
            else { continue }
            user.objects.removeValue(forKey: id)
            for group in Array(user.objects.keys) {
                if let children = user.objects[group]?["children"] as? [String], children.contains(id) {
                    user.objects[group]?["children"] = children.filter { $0 != id }
                }
            }
        }
    }
}
