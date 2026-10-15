import Foundation

extension NativeXcode {
    func integrate() throws -> [URL] {
        let packages = NativeSwiftPackageIntegrator(
            installedModules: Set(
                resolution.specs.values.map {
                    $0.data["module_name"] as? String ?? $0.name
                }))
        var originalAttributes: [String: [String: Any]] = [:]
        let previousAttributes = integrationSettings["_project_attributes"] as? [String: [String: Any]] ?? [:]
        for user in userProjects.values {
            removePreviousAggregateIntegration(user)
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
            var linked: [String] = []
            var embedded: [String] = []
            let platform = target["platform"] as? [String: String] ?? [:]
            let requests = try (target["dependencies"] as? [[String: Any]] ?? []).flatMap {
                try NativeDependency(
                    $0, platform: platform["name"] ?? "ios", deployment: platform["deployment_target"] ?? "0"
                ).expandedSelections()
            }
            let searchRequests = try nativeDependencies(target, search: true).flatMap {
                try NativeDependency(
                    $0, platform: platform["name"] ?? "ios", deployment: platform["deployment_target"] ?? "0"
                ).expandedSelections()
            }
            var configuredRoots: [String: Set<String>] = [:]
            for configuration in configurationNames {
                configuredRoots[configuration] = try dependencyRoots(
                    requests.filter { dependencyEnabled($0, configuration: configuration) })
            }
            let eligibleRoots = configuredRoots.values.reduce(into: Set<String>()) { $0.formUnion($1) }
            let searchRoots = try dependencyRoots(searchRequests).union(eligibleRoots)
            let conditionalRoots = eligibleRoots.subtracting(
                configuredRoots.values.reduce(eligibleRoots) { $0.intersection($1) })
            if let aggregate = aggregateTargets[nativeConsumerKey(target)] {
                let portal = user.add(
                    "swiftpods:pods-project",
                    [
                        "isa": "PBXFileReference", "path": project.appendingPathComponent("Pods/Pods.xcodeproj").path,
                        "sourceTree": "<absolute>", "lastKnownFileType": "wrapper.pb-project",
                    ])
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
            consumerVariantDependencies(
                user, target: targetID, roots: eligibleRoots, platform: platform["name"] ?? "ios")
            for product in products
            where graph.objects[product]?["explicitFileType"] as? String != "wrapper.cfbundle"
                && matchesProduct(product, roots: eligibleRoots, platform: platform["name"] ?? "ios")
            {
                let value = consumerProduct(product)
                let reference = user.add("swiftpods:product:" + product, value)
                let build = user.add("swiftpods:build:" + product, ["isa": "PBXBuildFile", "fileRef": reference])
                if !conditionalRoots.contains(productRoots[product] ?? "") { linked.append(build) }
                let dynamicTarget = graph.objects.values.first { $0["productReference"] as? String == product }
                if let list = dynamicTarget?["buildConfigurationList"] as? String,
                    let config = (graph.objects[list]?["buildConfigurations"] as? [String])?.first,
                    (graph.objects[config]?["buildSettings"] as? [String: Any])?["MACH_O_TYPE"] as? String
                        == "mh_dylib", !conditionalRoots.contains(productRoots[product] ?? "")
                {
                    embedded.append(
                        user.add(
                            "swiftpods:embed:" + product,
                            [
                                "isa": "PBXBuildFile", "fileRef": reference,
                                "settings": ["ATTRIBUTES": ["CodeSignOnCopy", "RemoveHeadersOnCopy"]],
                            ]))
                }
                if let group {
                    var children = user.objects[group]?["children"] as? [String] ?? []
                    if !children.contains(reference) { children.append(reference) }
                    user.objects[group]?["children"] = children
                }
            }
            let targetSDKs = eligibleRoots.sorted().flatMap {
                vendorSDKs[variantKey($0, platform["name"] ?? "ios")] ?? []
            }
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
                let key = "swiftpods:vendor:" + sdk.url.path
                let reference = user.add(
                    key,
                    [
                        "isa": "PBXFileReference", "path": sdk.url.path, "sourceTree": "<absolute>",
                        "lastKnownFileType": sdk.fileType,
                    ])
                let build = user.add(key + ":link", ["isa": "PBXBuildFile", "fileRef": reference])
                if !linked.contains(build) { linked.append(build) }
                if sdk.dynamic {
                    embedded.append(
                        user.add(
                            key + ":embed",
                            [
                                "isa": "PBXBuildFile", "fileRef": reference,
                                "settings": ["ATTRIBUTES": ["CodeSignOnCopy", "RemoveHeadersOnCopy"]],
                            ]))
                }
                if let group {
                    var children = user.objects[group]?["children"] as? [String] ?? []
                    if !children.contains(reference) { children.append(reference) }
                    user.objects[group]?["children"] = children
                }
            }
            var phases = user.objects[targetID]?["buildPhases"] as? [String] ?? []
            let frameworkPhase =
                phases.first { user.objects[$0]?["isa"] as? String == "PBXFrameworksBuildPhase" }
                ?? user.add(
                    "swiftpods:frameworkphase:" + targetID,
                    [
                        "isa": "PBXFrameworksBuildPhase", "buildActionMask": "2147483647",
                        "runOnlyForDeploymentPostprocessing": "0", "files": [],
                    ])
            let managedLinks = Set(
                previousProducts.union(products).map { NativePBX.identifier("swiftpods:build:" + $0) })
            var files = (user.objects[frameworkPhase]?["files"] as? [String] ?? []).filter {
                !isVendorBuild($0, user: user) && !managedLinks.contains($0)
            }

            for file in linked where !files.contains(file) { files.append(file) }
            user.objects[frameworkPhase]?["files"] = files
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
            let onDemand = try onDemandResources(roots: eligibleRoots, platform: platform["name"] ?? "ios")
            try NativeResources.apply(
                eligibleRoots.sorted().flatMap { staticResources[variantKey($0, platform["name"] ?? "ios")] ?? [] }
                    + onDemand.files.keys.sorted(by: { $0.path < $1.path }) + bridgeSupportResource(target),
                target: targetID, graph: user, allowMissing: Set(bridgeSupportResource(target)))
            onDemand.tag(target: targetID, graph: user)
            copyResourceBundles(roots: eligibleRoots, platform: platform["name"] ?? "ios", target: targetID, user: user)
            phases = user.objects[targetID]?["buildPhases"] as? [String] ?? phases
            let embedID = NativePBX.identifier("swiftpods:embedphase:" + targetID)
            phases.removeAll { $0 == embedID }
            user.objects.removeValue(forKey: embedID)
            if !embedded.isEmpty {
                let embed = user.add(
                    "swiftpods:embedphase:" + targetID,
                    [
                        "isa": "PBXCopyFilesBuildPhase", "name": "[SwiftPods] Embed Frameworks",
                        "buildActionMask": "2147483647", "runOnlyForDeploymentPostprocessing": "0", "files": embedded,
                        "dstPath": "", "dstSubfolderSpec": "10",
                    ])
                if !phases.contains(embed) { phases.append(embed) }
            }
            user.objects[targetID]?["buildPhases"] = phases
            try conditionalEmbeds(
                conditionalRoots, configured: configuredRoots, platform: platform["name"] ?? "ios", target: targetID,
                user: user)
            NativeScriptPhase.apply(try NativeScriptPhase.parse(target["script_phases"]), target: targetID, graph: user)
            applyInputOutputOptions(targetID, graph: user)
            let list = user.objects[targetID]?["buildConfigurationList"] as? String
            for config in list.flatMap({ user.objects[$0]?["buildConfigurations"] as? [String] }) ?? [] {
                let recordKey = path.path + ":" + config
                let original = try NativeIntegrationSettings.restore(
                    user.objects[config]?["buildSettings"] as? [String: Any] ?? [:],
                    record: integrationSettings[recordKey] as? [String: Any] ?? [:])
                var settings = original
                settings.merge(onDemand.buildSettings) { _, new in new }
                for key in ["FRAMEWORK_SEARCH_PATHS", "LIBRARY_SEARCH_PATHS", "SWIFT_INCLUDE_PATHS"] {
                    var values = nativeStrings(settings[key])
                    if values.isEmpty { values = ["$(inherited)"] }
                    if !values.contains("$(BUILT_PRODUCTS_DIR)") { values.append("$(BUILT_PRODUCTS_DIR)") }
                    for directory in librarySearchDirectories(searchRoots, platform: platform["name"] ?? "ios")
                    where !values.contains(directory) { values.append(directory) }
                    settings[key] = values
                }
                for (key, paths) in [
                    "FRAMEWORK_SEARCH_PATHS": targetSDKs.filter { !$0.isXCFramework && $0.isFramework }.map {
                        $0.url.deletingLastPathComponent().path
                    },
                    "LIBRARY_SEARCH_PATHS": targetSDKs.filter { !$0.isXCFramework && !$0.isFramework }.map {
                        $0.url.deletingLastPathComponent().path
                    },
                    "HEADER_SEARCH_PATHS": targetSDKs.filter { !$0.isXCFramework }.compactMap {
                        $0.slices.first?.headers?.path
                    },
                ] {
                    var values = nativeStrings(settings[key])
                    if values.isEmpty { values = ["$(inherited)"] }
                    for path in paths.map(NativeBuildSetting.path) where !values.contains(path) { values.append(path) }
                    settings[key] = values
                }
                var headerPaths = nativeStrings(settings["HEADER_SEARCH_PATHS"])
                if headerPaths.isEmpty { headerPaths = ["$(inherited)"] }
                let publicHeaders = headerSettings(searchRoots, platform: platform["name"] ?? "ios")
                for directory in publicHeaders where !headerPaths.contains(directory) { headerPaths.append(directory) }
                settings["HEADER_SEARCH_PATHS"] = headerPaths
                if !embedded.isEmpty || !conditionalRoots.isEmpty {
                    var runpaths = nativeStrings(settings["LD_RUNPATH_SEARCH_PATHS"])
                    if runpaths.isEmpty { runpaths = ["$(inherited)"] }
                    let frameworkPath =
                        platform["name"] == "osx" ? "@executable_path/../Frameworks" : "@executable_path/Frameworks"
                    if !runpaths.contains(frameworkPath) { runpaths.append(frameworkPath) }
                    settings["LD_RUNPATH_SEARCH_PATHS"] = runpaths
                }
                if settings["ALWAYS_SEARCH_USER_PATHS"] == nil { settings["ALWAYS_SEARCH_USER_PATHS"] = "NO" }
                settings["PODS_ROOT"] = project.appendingPathComponent("Pods").path
                settings["PODS_PODFILE_DIR_PATH"] = project.path
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
                let configuration = user.objects[config]?["name"] as? String ?? "Debug"
                let enabled = configuredRoots[configuration] ?? eligibleRoots
                let excludedAssets = try consumerAssetExclusions(
                    eligible: eligibleRoots, enabled: enabled, platform: platform["name"] ?? "ios")
                if !excludedAssets.isEmpty {
                    var exclusions = nativeStrings(settings["EXCLUDED_SOURCE_FILE_NAMES"])
                    if exclusions.isEmpty { exclusions = ["$(inherited)"] }
                    for asset in excludedAssets {
                        let value = NativeBuildSetting.quoted(asset)
                        if !exclusions.contains(value) { exclusions.append(value) }
                    }
                    settings["EXCLUDED_SOURCE_FILE_NAMES"] = exclusions
                }
                let conditionalProducts = products.filter {
                    productRoots[$0] != nil
                        && matchesProduct(
                            $0, roots: conditionalRoots.intersection(enabled), platform: platform["name"] ?? "ios")
                }
                var flags: [String] = []
                for product in conditionalProducts {
                    let path = graph.objects[product]?["path"] as? String ?? ""
                    if path.hasSuffix(".framework") {
                        flags += ["-framework", "\"" + String(path.dropLast(10)) + "\""]
                    } else {
                        flags.append("-l\"" + String(path.dropFirst(3).dropLast(2)) + "\"")
                    }
                }
                var linker = nativeStrings(settings["OTHER_LDFLAGS"]).filter { $0 != "$(SWIFTPODS_CONFIG_LDFLAGS)" }
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
                if !flags.isEmpty {
                    if linker.isEmpty { linker = ["$(inherited)"] }
                    linker.append("$(SWIFTPODS_CONFIG_LDFLAGS)")
                    settings["SWIFTPODS_CONFIG_LDFLAGS"] = flags
                } else {
                    settings.removeValue(forKey: "SWIFTPODS_CONFIG_LDFLAGS")
                }
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
                        for (key, value) in NativeSpec.xcconfig(attributes, key: "user_target_xcconfig") {
                            if settings[key] == nil {
                                settings[key] = value
                            } else if nativeStrings(original[key]).contains(where: { $0.contains("$(inherited)") }) {
                                settings[key] =
                                    (nativeStrings(settings[key]) + nativeStrings(value).filter { $0 != "$(inherited)" })
                                    .joined(separator: " ")
                            }
                        }
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
            try packages.integrate(target["packages"] as? [[String: Any]] ?? [], targetID: targetID, user: user)
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
        var written: [URL] = []
        for user in userProjects.values {
            pruneSourceObjects(user)
            pruneVendorObjects(user)
            try user.save()
            written.append(user.url)
        }
        guard let workspace = workspacePath() else {
            throw Diagnostic("SP-WORKSPACE", stage: "integrate", "No selected consumer workspace")
        }
        let userPaths = userProjects.values.map { $0.url.deletingLastPathComponent() }
        let podPaths =
            [project.appendingPathComponent("Pods/Pods.xcodeproj")]
            + (multipleProjects ? Set(targetOwners.values.map { projectForPod($0) }).sorted { $0.path < $1.path } : [])
        let workspaceRoot = workspace.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path
        func reference(_ path: URL) -> String {
            let value = path.standardizedFileURL.path
            return value.hasPrefix(workspaceRoot + "/")
                ? "group:" + String(value.dropFirst(workspaceRoot.count + 1)) : "absolute:" + value
        }
        let podReferences = Set(podPaths.map(reference))
        var workspaces = integrationSettings["_workspaces"] as? [String: [String]] ?? [:]
        let previous = workspaces[workspace.path] ?? []
        let owned = try NativeWorkspace.update(
            workspace, references: (userPaths + podPaths).map(reference), previous: previous,
            expected: workspaceFingerprints[workspace.path])
        workspaceFingerprints[workspace.path] = try FileFingerprint.tree(workspace)
        workspaces[workspace.path] = owned.filter(podReferences.contains)
        integrationSettings["_workspaces"] = workspaces
        integrationSettings["_products"] = previousProducts.union(products).sorted()
        try FileManager.default.createDirectory(
            at: integrationSettingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try jsonData(integrationSettings).writeIfChanged(to: integrationSettingsURL, options: .atomic)
        written += [workspace, integrationSettingsURL]
        return written
    }
    private func isVendorBuild(_ id: String, user: NativePBX) -> Bool {
        guard let reference = user.objects[id]?["fileRef"] as? String,
            let path = user.objects[reference]?["path"] as? String
        else { return false }
        let key = "swiftpods:vendor:" + path
        return reference == NativePBX.identifier(key)
            && [NativePBX.identifier(key + ":link"), NativePBX.identifier(key + ":embed")].contains(id)
    }
    private func pruneSourceObjects(_ user: NativePBX) {
        let candidates = previousProducts.union(products)
        let builds = Set(
            candidates.flatMap {
                [NativePBX.identifier("swiftpods:build:" + $0), NativePBX.identifier("swiftpods:embed:" + $0)]
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
    private func pruneVendorObjects(_ user: NativePBX) {
        let usedBuilds = Set(user.objects.values.flatMap { $0["files"] as? [String] ?? [] })
        for id in Array(user.objects.keys) where isVendorBuild(id, user: user) && !usedBuilds.contains(id) {
            user.objects.removeValue(forKey: id)
        }
        let usedReferences = Set(user.objects.values.compactMap { $0["fileRef"] as? String })
        for (id, object) in user.objects {
            guard object["isa"] as? String == "PBXFileReference", let path = object["path"] as? String,
                id == NativePBX.identifier("swiftpods:vendor:" + path), !usedReferences.contains(id)
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
