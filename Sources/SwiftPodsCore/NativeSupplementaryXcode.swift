import Foundation

extension NativeXcode {
    func generateSupplementaryTargets() throws {
        var selected: [(NativeSpec, NativeDependency, NativeSpecKind, NativePodVariant)] = []
        var names = Set<String>()
        for variant in variantPlan?.variants.values.sorted(by: { $0.label < $1.label }) ?? [] {
            selectVariant(variant)
            for request in variant.supplementary where names.insert(variantKey(request.name, request.platform)).inserted
            {
                guard let spec = resolution.specs[request.root] else { continue }
                let kind = try spec.kind(request.name)
                if kind != .library { selected.append((spec, request, kind, variant)) }
            }
        }
        selected.sort { ($0.2 == .app ? 0 : 1, $0.1.name) < ($1.2 == .app ? 0 : 1, $1.1.name) }
        var apps: [String: (id: String, name: String)] = [:]
        for (spec, request, kind, variant) in selected {
            selectVariant(variant)
            let attributes = try spec.supplementaryAttributes(request.name, platform: request.platform)
            let label = try supplementaryLabel(spec, request: request, kind: kind)
            var host: (id: String, name: String)?
            if kind == .test, attributes["requires_app_host"] as? Bool == true {
                if let name = attributes["app_host_name"] as? String {
                    guard let target = apps[variantKey(name, request.platform)] else {
                        throw Diagnostic(
                            "SP-TEST-HOST", stage: "integrate", "Selected app host is unavailable", file: name)
                    }
                    host = target
                } else {
                    let name =
                        "AppHost-" + libraryLabel(request.root, request.platform) + "-"
                        + (try spec.testType(request.name, platform: request.platform)).label + "-Tests"
                    if let existing = apps[variantKey(name, request.platform)] {
                        host = existing
                    } else {
                        let directory = project.appendingPathComponent("Pods/Target Support Files/" + name)
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        let source = directory.appendingPathComponent("main.m")
                        let mac = request.platform == "osx"
                        try Data(
                            (mac
                                ? "#import <AppKit/AppKit.h>\nint main(int argc, const char *argv[]) { return NSApplicationMain(argc, argv); }\n"
                                : Self.iOSAppHostSource).utf8
                        ).writeIfChanged(to: source)
                        let info: [String: Any]
                        if mac {
                            info = ["NSPrincipalClass": "NSApplication", "LSUIElement": true]
                        } else {
                            info = [
                                "UIApplicationSceneManifest": [
                                    "UIApplicationSupportsMultipleScenes": false, "UISceneConfigurations": [:],
                                ] as [String: Any]
                            ]
                        }
                        let value: [String: Any] = [
                            "source_files": [], "frameworks": [mac ? "AppKit" : "UIKit"], "info_plist": info,
                        ]
                        let id = try supplementaryTarget(
                            spec, request: request, label: name, kind: .app, attributes: value, generatedSource: source)
                        host = (id, name)
                        apps[variantKey(name, request.platform)] = host
                    }
                }
            }
            let id = try supplementaryTarget(
                spec, request: request, label: label, kind: kind, attributes: attributes, host: host)
            supplementaryTargets[variant.key, default: [:]][request.name] = id
            if kind == .app { apps[variantKey(request.name, request.platform)] = (id, label) }
            try writeScheme(
                id: id, label: label, kind: kind, host: host, options: attributes["scheme"] as? [String: Any] ?? [:])
        }
    }

    func supplementaryLabel(_ spec: NativeSpec, request: NativeDependency, kind: NativeSpecKind) throws
        -> String
    {
        let infix =
            kind == .test ? "-" + (try spec.testType(request.name, platform: request.platform)).label + "-" : "-"
        return libraryLabel(request.root, request.platform) + infix
            + NativePodName.components(request.name).dropFirst().joined(separator: "-")
    }

    private func supplementaryTarget(
        _ spec: NativeSpec, request: NativeDependency, label: String, kind: NativeSpecKind, attributes: [String: Any],
        host: (id: String, name: String)? = nil, generatedSource: URL? = nil
    ) throws -> String {
        guard let directory = spec.directory else {
            throw Diagnostic(
                "SP-SPEC-MISSING", stage: "integrate", "Spec source directory is missing", file: request.name)
        }
        guard !targetIDs.contains(where: { graph.objects[$0]?["name"] as? String == label }) else {
            throw Diagnostic("SP-XCODE-TARGET", stage: "integrate", "Duplicate generated target name", file: label)
        }
        var settings = baseSettings(platform: request.platform, deployment: request.deployment)
        if let minimum = attributes["deployment_target"] as? String ?? (attributes["platforms"] as? [String: Any])?[
            request.platform] as? String, minimum.compare(request.deployment, options: .numeric) == .orderedDescending
        {
            settings[
                [
                    "osx": "MACOSX_DEPLOYMENT_TARGET", "ios": "IPHONEOS_DEPLOYMENT_TARGET",
                    "tvos": "TVOS_DEPLOYMENT_TARGET", "watchos": "WATCHOS_DEPLOYMENT_TARGET",
                    "visionos": "XROS_DEPLOYMENT_TARGET",
                ][request.platform]!] = minimum
        }
        settings.merge(NativeSpec.xcconfig(attributes, key: "pod_target_xcconfig")) { _, new in new }
        settings.removeValue(forKey: "MACH_O_TYPE")
        let testType = kind == .test ? try spec.testType(request.name, platform: request.platform) : nil
        if kind == .test && request.platform != "osx" {
            settings["CODE_SIGNING_ALLOWED"] = "YES"
            settings["CODE_SIGNING_REQUIRED"] = "YES"
        }
        settings["PRODUCT_NAME"] = label
        var module = label.replacingOccurrences(of: "[^A-Za-z0-9_]", with: "_", options: .regularExpression)
        if module.first?.isNumber == true { module = "_" + module }
        settings["PRODUCT_MODULE_NAME"] = module
        settings["PRODUCT_BUNDLE_IDENTIFIER"] = "org.swiftpods.$(PRODUCT_NAME:rfc1034identifier)"
        settings["DEFINES_MODULE"] = "NO"
        settings["PODS_ROOT"] = NativeBuildSetting.literal(project.appendingPathComponent("Pods").path)
        settings["PODS_TARGET_SRCROOT"] = NativeBuildSetting.literal(directory.path)
        settings["SWIFT_VERSION"] =
            variantPlan?.variants[variantKey(request.root, request.platform)]?.swiftVersion ?? "5.0"
        if let arc = attributes["requires_arc"] as? Bool { settings["CLANG_ENABLE_OBJC_ARC"] = arc ? "YES" : "NO" }
        if attributes["compiler_flags"] != nil {
            let flags = nativeStrings(settings["OTHER_CFLAGS"])
            settings["OTHER_CFLAGS"] =
                (flags.isEmpty ? ["$(inherited)"] : flags) + nativeStrings(attributes["compiler_flags"])
        }
        let sources = try generatedSource.map { [$0] } ?? NativeFileSelection.sourceFiles(attributes, root: directory)
        let rules = try NativeFileRules(attributes, root: directory, files: sources)
        try compileSettings(attributes, root: directory, label: label, settings: &settings)
        let sourceFiles = sources.filter { NativeFileSelection.compilableSources.contains($0.pathExtension) }.map {
            buildFile(file($0.path), target: label, settings: rules.sourceSettings($0))
        }
        var libraryRequests = variantPlan?.variants[variantKey(request.root, request.platform)]?.actualRequests ?? []
        if libraryRequests.isEmpty {
            libraryRequests = [
                try NativeDependency(["name": request.root], platform: request.platform, deployment: request.deployment)
            ]
        }
        let roots = try dependencyRoots(libraryRequests + [request], includeSupplementary: true)
        let libraries = products.filter {
            productRoots[$0] != nil && matchesProduct($0, roots: roots, platform: request.platform)
        }
        var dependencies = libraries.compactMap { product in
            targetIDs.first { graph.objects[$0]?["productReference"] as? String == product }
        }
        if let host { dependencies.append(host.id) }
        var frameworks = libraries.map { buildFile(buildReference($0), target: label) }
        var embedded = libraries.filter { isDynamicProduct($0) }.map {
            buildFile(
                buildReference($0), target: label + ":embed",
                settings: ["ATTRIBUTES": ["CodeSignOnCopy", "RemoveHeadersOnCopy"]])
        }
        let candidates =
            roots.sorted().flatMap { vendorSDKs[variantKey($0, request.platform)] ?? [] }
            + (try loadVendoredSDKs(attributes, root: directory, platform: request.platform))
        var sdks: [NativeVendorSDK] = []
        var sdkNames: [String: String] = [:]
        for sdk in candidates {
            if let previous = sdkNames[sdk.productName] {
                guard previous == sdk.url.path else {
                    throw Diagnostic(
                        "SP-DUPLICATE-SDK", stage: "integrate", "Two SDKs supply \(sdk.productName)", file: request.name
                    )
                }
                continue
            }
            sdkNames[sdk.productName] = sdk.url.path
            sdks.append(sdk)
        }
        for sdk in sdks {
            let reference = file(sdk.url.path, type: sdk.fileType)
            frameworks.append(buildFile(reference, target: label))
            if sdk.dynamic {
                embedded.append(
                    buildFile(
                        reference, target: label + ":embed",
                        settings: ["ATTRIBUTES": ["CodeSignOnCopy", "RemoveHeadersOnCopy"]]))
            }
        }
        for name in nativeStrings(attributes["frameworks"]) + nativeStrings(attributes["weak_frameworks"]) {
            frameworks.append(
                buildFile(
                    file(
                        "System/Library/Frameworks/" + name + ".framework", type: "wrapper.framework",
                        sourceTree: "SDKROOT"), target: label,
                    settings: nativeStrings(attributes["weak_frameworks"]).contains(name)
                        ? ["ATTRIBUTES": ["Weak"]] : [:]))
        }
        if kind == .test {
            frameworks.append(
                buildFile(
                    file(
                        "Developer/Library/Frameworks/XCTest.framework", type: "wrapper.framework",
                        sourceTree: "PLATFORM_DIR"), target: label))
        }
        let headerDirectories = Set(
            sources.filter { NativeFileSelection.headers.contains($0.pathExtension) }.map {
                $0.deletingLastPathComponent().path
            }
        ).sorted()
        let searchPaths: [String: [String]] = [
            "HEADER_SEARCH_PATHS": [NativeBuildSetting.literal(directory.path)]
                + headerSettings(roots, platform: request.platform)
                + headerDirectories.map(NativeBuildSetting.literal)
                + sdks.filter { !$0.isXCFramework }.compactMap {
                    $0.slices.first?.headers.map { NativeBuildSetting.literal($0.path) }
                },
            "FRAMEWORK_SEARCH_PATHS": ["$(BUILT_PRODUCTS_DIR)"]
                + librarySearchDirectories(roots, platform: request.platform)
                + (kind == .test ? ["$(PLATFORM_DIR)/Developer/Library/Frameworks"] : [])
                + sdks.filter { !$0.isXCFramework && $0.isFramework }.map {
                    NativeBuildSetting.literal($0.url.deletingLastPathComponent().path)
                },
            "LIBRARY_SEARCH_PATHS": ["$(BUILT_PRODUCTS_DIR)"]
                + librarySearchDirectories(roots, platform: request.platform)
                + sdks.filter { !$0.isXCFramework && !$0.isFramework }.map {
                    NativeBuildSetting.literal($0.url.deletingLastPathComponent().path)
                },
            "SWIFT_INCLUDE_PATHS": ["$(BUILT_PRODUCTS_DIR)"]
                + librarySearchDirectories(roots, platform: request.platform),
        ]
        for (key, paths) in searchPaths {
            var values = nativeStrings(settings[key])
            if values.isEmpty { values = ["$(inherited)"] }
            for path in paths.map(NativeBuildSetting.path) where !values.contains(path) { values.append(path) }
            settings[key] = values
        }
        applyCustomModuleMaps(roots, platform: request.platform, settings: &settings)
        settings["OTHER_LDFLAGS"] =
            ["$(inherited)"] + nativeStrings(settings["OTHER_LDFLAGS"])
            + NativeBuildSettings.libraryFlags(
                nativeStrings(attributes["libraries"]), sources: sources, settings: settings, linkingWithClang: true)
        settings["OTHER_LDFLAGS"] =
            nativeStrings(settings["OTHER_LDFLAGS"])
            + (try consumerLinkerFlags(roots, platform: request.platform, sources: sources, settings: settings))
        let mac = request.platform == "osx"
        settings["LD_RUNPATH_SEARCH_PATHS"] =
            [
                "$(inherited)", mac ? "@executable_path/../Frameworks" : "@executable_path/Frameworks",
                mac ? "@loader_path/../Frameworks" : "@loader_path/Frameworks",
                "$(PLATFORM_DIR)/Developer/Library/Frameworks",
            ] + nativeStrings(settings["LD_RUNPATH_SEARCH_PATHS"])
        if let host {
            if testType == .ui {
                settings.removeValue(forKey: "TEST_HOST")
                settings.removeValue(forKey: "BUNDLE_LOADER")
                settings["TEST_TARGET_NAME"] = host.name
            } else {
                settings["TEST_HOST"] =
                    "$(BUILT_PRODUCTS_DIR)/" + host.name + ".app/" + (mac ? "Contents/MacOS/" : "") + host.name
                settings["BUNDLE_LOADER"] = "$(TEST_HOST)"
            }
        }
        let info = project.appendingPathComponent("Pods/Target Support Files/" + label + "/Info.plist")
        try FileManager.default.createDirectory(at: info.deletingLastPathComponent(), withIntermediateDirectories: true)
        var plist: [String: Any] = [
            "CFBundleExecutable": "$(EXECUTABLE_NAME)", "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)",
            "CFBundleName": "$(PRODUCT_NAME)", "CFBundlePackageType": kind == .app ? "APPL" : "BNDL",
            "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0",
        ]
        if kind == .app && request.platform == "ios" {
            plist["UILaunchScreen"] = [:]
            plist["UISupportedInterfaceOrientations"] = [
                "UIInterfaceOrientationPortrait", "UIInterfaceOrientationPortraitUpsideDown",
                "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight",
            ]
            settings["TARGETED_DEVICE_FAMILY"] = "1,2"
        }
        plist.merge(attributes["info_plist"] as? [String: Any] ?? [:]) { _, new in new }
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).writeIfChanged(
            to: info, options: .atomic)
        settings["GENERATE_INFOPLIST_FILE"] = "NO"
        settings["INFOPLIST_FILE"] = NativeBuildSetting.literal(info.path)
        var onDemand = NativeOnDemandResources()
        if kind == .app {
            onDemand = try onDemandResources(roots: roots, platform: request.platform)
            onDemand.merge(try NativeOnDemandResources(attributes: attributes, root: directory))
            settings.merge(onDemand.buildSettings) { _, new in new }
        }
        var resources = try NativeResources.references(
            NativeFileSelection.resourcePaths(attributes["resources"], attributes: attributes, root: directory)
                + Array(onDemand.files.keys)
                + roots.sorted().flatMap { staticResources[variantKey($0, request.platform)] ?? [] },
            owner: label, graph: graph, ungrouped: Set(onDemand.files.keys))
        let libraryBundles = products.filter { product in
            guard !frameworkResourceBundles.contains(product) else { return false }
            guard graph.objects[product]?["explicitFileType"] as? String == "wrapper.cfbundle" else { return false }
            return matchesProduct(product, roots: roots, platform: request.platform)
        }
        // Only products copied into this consumer share a destination. Other
        // supplementary targets have independent bundle output directories.
        var bundleDestinations = Set<String>()
        for product in libraryBundles {
            let name = graph.objects[product]?["path"] as? String ?? ""
            guard bundleDestinations.insert(name).inserted else {
                throw Diagnostic(
                    "SP-XCODE-RESOURCE", stage: "integrate", "Resource bundle product name is already used",
                    file: name)
            }
        }
        resources += libraryBundles.map(buildReference)
        dependencies += libraryBundles.compactMap { product in
            targetIDs.first { graph.objects[$0]?["productReference"] as? String == product }
        }
        for (bundle, patterns) in (attributes["resource_bundles"] as? [String: Any] ?? [:]).sorted(by: {
            $0.key < $1.key
        }) {
            guard bundle.range(of: #"\A[A-Za-z0-9_][A-Za-z0-9_.+-]*\z"#, options: .regularExpression) != nil else {
                throw Diagnostic(
                    "SP-XCODE-RESOURCE", stage: "integrate", "Invalid resource bundle name", file: request.name)
            }
            guard bundleDestinations.insert(bundle + ".bundle").inserted else {
                throw Diagnostic(
                    "SP-XCODE-RESOURCE", stage: "integrate", "Resource bundle product name is already used",
                    file: bundle)
            }
            let bundleIdentity = try resourceBundleIdentity(bundle, variant: currentVariant ?? "", owner: request.name)
            let bundleLabel = resourceBundleLabels[bundleIdentity] ?? label + "-" + bundle
            let refs = try NativeResources.references(
                NativeFileSelection.resourcePaths(patterns, attributes: attributes, root: directory),
                owner: bundleLabel,
                graph: graph)
            let product = graph.add(
                "resource-bundle-product:" + bundleIdentity,
                [
                    "isa": "PBXFileReference", "explicitFileType": "wrapper.cfbundle", "path": bundle + ".bundle",
                    "sourceTree": "BUILT_PRODUCTS_DIR",
                ])
            var bundleSettings = baseSettings(platform: request.platform, deployment: request.deployment)
            bundleSettings["PRODUCT_NAME"] = bundle
            bundleSettings["PRODUCT_BUNDLE_IDENTIFIER"] = "org.swiftpods.$(PRODUCT_NAME:rfc1034identifier)"
            bundleSettings["CONFIGURATION_BUILD_DIR"] =
                "$(BUILD_DIR)/$(CONFIGURATION)$(EFFECTIVE_PLATFORM_NAME)/" + bundleLabel
            try resourceBundleInfoPlist(bundleLabel, settings: &bundleSettings)
            productBuildPaths[product] = bundleLabel + "/" + bundle + ".bundle"
            productVariants[product] = currentVariant
            let target = graph.add(
                "resource-bundle-target:" + bundleIdentity,
                [
                    "isa": "PBXNativeTarget", "name": bundleLabel, "productName": bundle, "productReference": product,
                    "productType": "com.apple.product-type.bundle",
                    "buildConfigurationList": configList(bundleLabel, settings: bundleSettings),
                    "buildPhases": [
                        phase(
                            "PBXResourcesBuildPhase", target: bundleLabel,
                            files: refs.map { buildFile($0, target: bundleLabel) })
                    ], "buildRules": [], "dependencies": [],
                ])
            targetIDs.append(target)
            targetOwners[target] = request.root
            dependencies.append(target)
            resources.append(buildReference(product))
            if generatedSource == nil, let currentVariant {
                supplementaryBundleTargets[currentVariant, default: [:]][request.name, default: []].append(target)
            }
        }
        var phases = [
            phase("PBXSourcesBuildPhase", target: label, files: sourceFiles),
            phase("PBXFrameworksBuildPhase", target: label, files: Array(Set(frameworks)).sorted()),
            phase("PBXResourcesBuildPhase", target: label, files: resources.map { buildFile($0, target: label) }),
        ]
        if !embedded.isEmpty {
            phases.append(
                graph.add(
                    "embed:" + label,
                    [
                        "isa": "PBXCopyFilesBuildPhase", "name": "[SwiftPods] Embed Frameworks",
                        "buildActionMask": "2147483647", "runOnlyForDeploymentPostprocessing": "0",
                        "files": Array(Set(embedded)).sorted(), "dstPath": "", "dstSubfolderSpec": "10",
                    ]))
        }
        let product = graph.add(
            "product:" + label,
            [
                "isa": "PBXFileReference",
                "explicitFileType": kind == .app ? "wrapper.application" : "wrapper.cfbundle",
                "path": label + (kind == .app ? ".app" : ".xctest"), "sourceTree": "BUILT_PRODUCTS_DIR",
            ])
        let id = graph.add(
            "target:" + label,
            [
                "isa": "PBXNativeTarget", "name": label, "productName": label, "productReference": product,
                "productType": kind == .app ? "com.apple.product-type.application" : testType!.productType,
                "buildConfigurationList": configList(label, settings: settings), "buildPhases": phases,
                "buildRules": [],
                "dependencies": Array(Set(dependencies)).sorted().map {
                    graph.add("dependency:" + label + ":" + $0, ["isa": "PBXTargetDependency", "target": $0])
                },
            ])
        targetIDs.append(id)
        targetOwners[id] = request.root
        onDemand.tag(target: id, graph: graph)
        if let host { testTargetHosts[id] = host.id }
        if generatedSource == nil {
            NativeScriptPhase.apply(try spec.scriptPhases(for: request), target: id, graph: graph)
        }
        return id
    }

    func isDynamicProduct(_ product: String) -> Bool {
        guard let target = graph.objects.values.first(where: { $0["productReference"] as? String == product }),
            let list = target["buildConfigurationList"] as? String,
            let config = (graph.objects[list]?["buildConfigurations"] as? [String])?.first
        else { return false }
        return (graph.objects[config]?["buildSettings"] as? [String: Any])?["MACH_O_TYPE"] as? String == "mh_dylib"
    }

    private func supplementaryResources(_ patterns: Any?, root: URL, owner: String) throws -> [String] {
        try NativeResources.references(nativeGlob(patterns, root: root), owner: owner, graph: graph)
    }

    func writeScheme(
        id: String, label: String, kind: NativeSpecKind, host: (id: String, name: String)?, options: [String: Any]
    ) throws {
        func xml(_ value: String) -> String {
            value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "'", with: "&apos;")
                .replacingOccurrences(of: "\t", with: "&#9;").replacingOccurrences(of: "\n", with: "&#10;")
                .replacingOccurrences(of: "\r", with: "&#13;")
        }
        func reference(_ id: String, _ name: String, app: Bool) -> String {
            let product = graph.objects[id]?["productReference"] as? String ?? ""
            let filename = graph.objects[product]?["path"] as? String ?? name + (app ? ".app" : ".xctest")
            let project =
                multipleProjects
                ? targetOwners[id].map { projectForPod($0).lastPathComponent } ?? "Pods.xcodeproj"
                : "Pods.xcodeproj"
            let location = "container:" + project
            // Xcode must recognize the prefix even when the filename starts
            // with a combining mark that joins its colon as a Swift Character.
            let container = location.hasPrefix("container:") ? location : "container:./" + project
            return
                "<BuildableReference BuildableIdentifier=\"primary\" BlueprintIdentifier=\"\(id)\" BuildableName=\"\(xml(filename))\" BlueprintName=\"\(xml(name))\" ReferencedContainer=\"\(xml(container))\"/>"
        }
        let configurations = options["build_configurations"] as? [String: String] ?? [:]
        for name in configurations.values where configurationTypes[name] == nil {
            throw Diagnostic(
                "SP-XCODE-CONFIG", stage: "integrate", "Scheme references an unknown configuration", file: name)
        }
        let ref = reference(id, label, app: kind == .app)
        let args =
            "<CommandLineArguments>"
            + nativeStrings(options["launch_arguments"]).map {
                "<CommandLineArgument argument=\"\(xml($0))\" isEnabled=\"YES\"/>"
            }.joined() + "</CommandLineArguments>"
        let env =
            "<EnvironmentVariables>"
            + (options["environment_variables"] as? [String: String] ?? [:]).sorted(by: { $0.key < $1.key }).map {
                "<EnvironmentVariable key=\"\(xml($0.key))\" value=\"\(xml($0.value))\" isEnabled=\"YES\"/>"
            }.joined() + "</EnvironmentVariables>"
        let testables =
            kind == .test
            ? "<Testables><TestableReference skipped=\"NO\" parallelizable=\"\(options["parallelizable"] as? Bool == true ? "YES" : "NO")\">\(ref)</TestableReference></Testables>"
            : "<Testables/>"
        let runnableRef = kind == .app ? ref : host.map { reference($0.id, $0.name, app: true) }
        let runnable =
            runnableRef.map { "<BuildableProductRunnable runnableDebuggingMode=\"0\">\($0)</BuildableProductRunnable>" }
            ?? ""
        let macro = host.map { "<MacroExpansion>" + reference($0.id, $0.name, app: true) + "</MacroExpansion>" } ?? ""
        let text = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!-- Generated by SwiftPods. -->
            <Scheme LastUpgradeVersion="2700" version="1.3">
              <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">\(ref)</BuildActionEntry></BuildActionEntries></BuildAction>
              <TestAction buildConfiguration="\(xml(configurations["Test"] ?? "Debug"))" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="NO" codeCoverageEnabled="\(options["code_coverage"] as? Bool == true ? "YES" : "NO")">\(testables)\(macro)\(args)\(env)</TestAction>
              <LaunchAction buildConfiguration="\(xml(configurations["Run"] ?? "Debug"))" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES">\(runnable)\(args)\(env)</LaunchAction>
              <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES">\(runnable)</ProfileAction>
              <AnalyzeAction buildConfiguration="\(xml(configurations["Analyze"] ?? "Debug"))"/><ArchiveAction buildConfiguration="\(xml(configurations["Archive"] ?? "Release"))" revealArchiveInOrganizer="YES"/>
            </Scheme>
            """
        let directory = graph.url.deletingLastPathComponent().appendingPathComponent("xcshareddata/xcschemes")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent(label + ".xcscheme")
        try Data(text.utf8).writeIfChanged(to: path, options: .atomic)
        managedSchemes.insert(path)
    }
}
