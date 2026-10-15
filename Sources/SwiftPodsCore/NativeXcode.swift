import Foundation

final class NativeXcode {
    let project: URL
    let graph: NativePBX
    let manifest: [String: Any]
    var resolution: NativeResolution
    var hookTargets: [[String: Any]] = []
    var configurations: [String: [String: String]] = [:]
    var products: [String] = []
    var targetIDs: [String] = []
    var targetOwners: [String: String] = [:]
    var testTargetHosts: [String: String] = [:]
    var userProjects: [String: NativePBX] = [:]
    var resources: [String] = []
    var productRoots: [String: String] = [:]
    var productPlatforms: [String: String] = [:]
    var libraryTargets: [String: String] = [:]
    var resourceBundleTargets: [String: [String]] = [:]
    var supplementaryTargets: [String: [String: String]] = [:]
    var supplementaryBundleTargets: [String: [String: [String]]] = [:]
    var variantPlan: NativeVariantPlan?
    var activeVariants: [String: String] = [:]
    var currentVariant: String?
    var productVariants: [String: String] = [:]
    var productBuildPaths: [String: String] = [:]
    var aggregateTargets: [String: String] = [:]
    var previousProducts: Set<String> = []
    var integrationSettings: [String: Any] = [:]
    var configurationWarnings: [[String: Any]] = []
    var workspaceFingerprints: [String: String] = [:]
    var integrationSettingsURL: URL {
        project.appendingPathComponent("Pods/Target Support Files/SwiftPods-Integration.json")
    }
    var staticResources: [String: [URL]] = [:]
    var generatedProjects: [String: NativePBX] = [:]
    var aggregateProject: NativePBX?
    var managedSchemes = Set<URL>()
    var previousInventory: [String: Any] = [:]
    var projectInventoryURL: URL { project.appendingPathComponent("Pods/Target Support Files/SwiftPods-Projects.json") }
    var configurationTypes: [String: String] = ["Debug": "debug", "Release": "release"]
    var platformNames: [String] {
        Set(
            (manifest["targets"] as? [[String: Any]] ?? []).map {
                ($0["platform"] as? [String: String])?["name"] ?? "ios"
            }
        ).sorted()
    }
    func variantKey(_ name: String, _ platform: String) -> String {
        let root = String(name.split(separator: "/").first ?? "")
        if let key = activeVariants[root], variantPlan?.variants[key]?.platform == platform {
            return key + (name == root ? "" : "::" + name.dropFirst(root.count + 1))
        }
        return name + ":" + platform
    }
    func libraryLabel(_ root: String, _ platform: String) -> String {
        variantPlan?.variants[variantKey(root, platform)]?.label
            ?? (platformNames.count > 1 ? root + "-" + platform : root)
    }
    var configurationNames: [String] {
        ["Debug", "Release"] + configurationTypes.keys.filter { !["Debug", "Release"].contains($0) }.sorted()
    }
    var resourceRoots: [String: String] = [:]
    var frameworkResourceBundles = Set<String>()
    var vendorSDKs: [String: [NativeVendorSDK]] = [:]
    init(project: URL, manifest: [String: Any], resolution: NativeResolution, integrateUserProjects: Bool = true) throws
    {
        self.project = project
        self.manifest = manifest
        self.resolution = resolution
        graph = try NativePBX(project.appendingPathComponent("Pods/Pods.xcodeproj/project.pbxproj"))
        if FileManager.default.fileExists(atPath: graph.url.path),
            let previous = try? NativePBX(graph.url, existing: true)
        {
            previousProducts = Set(previous.objects.values.compactMap { $0["productReference"] as? String })
        }
        if FileManager.default.fileExists(atPath: projectInventoryURL.path) {
            previousInventory = try NativeProjectInventory.load(
                projectInventoryURL, root: project.appendingPathComponent("Pods"))
            previousProducts.formUnion(previousInventory["products"] as? [String] ?? [])
        }
        graph.randomIdentifiers = (manifest["options"] as? [String: Any])?["deterministic_uuids"] as? Bool == false
        if FileManager.default.fileExists(atPath: integrationSettingsURL.path) {
            integrationSettings = try readObject(integrationSettingsURL)
            previousProducts.formUnion(integrationSettings["_products"] as? [String] ?? [])
        }
        for target in integrateUserProjects ? (manifest["targets"] as? [[String: Any]] ?? []) : [] {
            let path = try projectPath(target)
            if userProjects[path.path] == nil { userProjects[path.path] = try NativePBX(path, existing: true) }
        }
        if let workspace = workspacePath() {
            try ProjectState(directory: project).registerProject(workspace)
            workspaceFingerprints[workspace.path] = try FileFingerprint.tree(workspace)
        }
        for user in userProjects.values {
            for object in user.objects.values where object["isa"] as? String == "XCBuildConfiguration" {
                if let name = object["name"] as? String {
                    configurationTypes[name] = name.lowercased().contains("debug") ? "debug" : "release"
                }
            }
        }
        for target in [manifest] + (manifest["targets"] as? [[String: Any]] ?? []) {
            for (name, kind) in target["configurations"] as? [String: String] ?? [:] {
                guard !name.isEmpty, ["debug", "release"].contains(kind) else {
                    throw Diagnostic(
                        "SP-XCODE-CONFIG", stage: "integrate", "Configuration mapping values must be debug/release",
                        file: name)
                }
                configurationTypes[name] = kind
            }
        }
        var analyzed = manifest
        analyzed["targets"] = try (manifest["targets"] as? [[String: Any]] ?? []).map { original -> [String: Any] in
            var target = original
            if target["swift_version"] == nil, integrateUserProjects,
                let user = userProjects[try projectPath(target).path],
                let native = user.objects.values.first(where: {
                    $0["isa"] as? String == "PBXNativeTarget" && $0["name"] as? String == target["name"] as? String
                }),
                let list = native["buildConfigurationList"] as? String
            {
                target["swift_version"] =
                    (user.objects[list]?["buildConfigurations"] as? [String] ?? []).compactMap { id -> String? in
                        let value = (user.objects[id]?["buildSettings"] as? [String: Any])?["SWIFT_VERSION"] as? String
                        return value?.range(of: #"\A[0-9]+(?:\.[0-9]+)*\z"#, options: .regularExpression) != nil
                            ? value : nil
                    }.first
            }
            return target
        }
        variantPlan = try NativeVariantPlan(manifest: analyzed, resolution: resolution)
    }
    func workspacePath() -> URL? {
        guard let first = userProjects.values.sorted(by: { $0.url.path < $1.url.path }).first else { return nil }
        let name =
            manifest["workspace"] as? String
            ?? first.url.deletingLastPathComponent().deletingPathExtension().lastPathComponent
        let value = name.hasSuffix(".xcworkspace") ? name : name + ".xcworkspace"
        let path = value.hasPrefix("/") ? URL(fileURLWithPath: value) : project.appendingPathComponent(value)
        return path.standardizedFileURL.resolvingSymlinksInPath().appendingPathComponent("contents.xcworkspacedata")
    }
    func projectPath(_ target: [String: Any]) throws -> URL {
        if let path = target["project"] as? String ?? manifest["project"] as? String {
            let url = URL(fileURLWithPath: path, relativeTo: project).standardizedFileURL
            return (url.pathExtension == "xcodeproj" ? url : url.appendingPathExtension("xcodeproj"))
                .appendingPathComponent("project.pbxproj")
        }
        let found = try FileManager.default.contentsOfDirectory(at: project, includingPropertiesForKeys: nil).filter {
            $0.pathExtension == "xcodeproj"
        }
        guard found.count == 1 else {
            throw Diagnostic(
                "SP-XCODE-AMBIGUOUS", stage: "integrate", "Specify project 'Name.xcodeproj' in the Podfile")
        }
        return found[0].appendingPathComponent("project.pbxproj")
    }
    func configList(_ name: String, settings: [String: Any]) -> String {
        var ids: [String: String] = [:]
        let entries: [[String: Any]] = configurationNames.map { configuration in
            var value = settings
            value["SWIFT_OPTIMIZATION_LEVEL"] = configurationTypes[configuration] == "debug" ? "-Onone" : "-O"
            value["GCC_OPTIMIZATION_LEVEL"] = configurationTypes[configuration] == "debug" ? "0" : "s"
            if value["ENABLE_TESTABILITY"] == nil {
                value["ENABLE_TESTABILITY"] = configurationTypes[configuration] == "debug" ? "YES" : "NO"
            }
            let id = graph.add(
                "config:\(name):\(configuration)",
                ["isa": "XCBuildConfiguration", "name": configuration, "buildSettings": value])
            ids[configuration] = id
            return ["name": configuration, "build_settings": value]
        }
        configurations[name] = ids
        if name != "Pods" { hookTargets.append(["name": name, "build_configurations": entries]) }
        return graph.add(
            "configs:" + name,
            [
                "isa": "XCConfigurationList", "buildConfigurations": configurationNames.compactMap { ids[$0] },
                "defaultConfigurationName": "Release", "defaultConfigurationIsVisible": "0",
            ])
    }
    func file(_ path: String, type: String? = nil, sourceTree: String = "<absolute>") -> String {
        var object: [String: Any] = ["isa": "PBXFileReference", "path": path, "sourceTree": sourceTree]
        if let type { object["lastKnownFileType"] = type }
        return graph.add("file:" + path, object)
    }
    func buildFile(_ reference: String, target: String, settings: [String: Any] = [:]) -> String {
        var object: [String: Any] = ["isa": "PBXBuildFile", "fileRef": reference]
        if !settings.isEmpty { object["settings"] = settings }
        return graph.add("build:\(target):\(reference)", object)
    }
    func phase(_ kind: String, target: String, files: [String]) -> String {
        graph.add(
            "phase:\(target):\(kind)",
            ["isa": kind, "buildActionMask": "2147483647", "files": files, "runOnlyForDeploymentPostprocessing": "0"])
    }
    func baseSettings(platform: String, deployment: String) -> [String: Any] {
        let sdk =
            ["osx": "macosx", "ios": "iphoneos", "tvos": "appletvos", "watchos": "watchos", "visionos": "xros"][
                platform] ?? "iphoneos"
        let minimum =
            [
                "osx": "MACOSX_DEPLOYMENT_TARGET", "ios": "IPHONEOS_DEPLOYMENT_TARGET",
                "tvos": "TVOS_DEPLOYMENT_TARGET", "watchos": "WATCHOS_DEPLOYMENT_TARGET",
                "visionos": "XROS_DEPLOYMENT_TARGET",
            ][platform] ?? "IPHONEOS_DEPLOYMENT_TARGET"
        return [
            "SDKROOT": sdk, minimum: deployment, "ALWAYS_SEARCH_USER_PATHS": "NO", "CLANG_ENABLE_MODULES": "YES",
            "CLANG_ENABLE_OBJC_ARC": "YES", "DEFINES_MODULE": "YES", "SWIFT_VERSION": "5.0",
            "CODE_SIGNING_ALLOWED": "NO", "COPY_PHASE_STRIP": "NO", "GENERATE_INFOPLIST_FILE": "YES",
            "SKIP_INSTALL": "YES", "GCC_TREAT_WARNINGS_AS_ERRORS": "YES", "SWIFT_TREAT_WARNINGS_AS_ERRORS": "YES",
            "GCC_PREPROCESSOR_DEFINITIONS": ["$(inherited)", "COCOAPODS=1"],
            "CONFIGURATION_BUILD_DIR": "$(BUILD_DIR)/$(CONFIGURATION)$(EFFECTIVE_PLATFORM_NAME)",
        ]
    }
    func dependencyRoots(_ requests: [NativeDependency], includeSupplementary: Bool = false) throws -> Set<String> {
        var queue = requests
        var names = Set<String>()
        var roots = Set<String>()
        while let request = queue.popLast() {
            guard names.insert(request.name).inserted else { continue }
            guard let spec = resolution.specs[request.root] else { continue }
            if !includeSupplementary, try spec.kind(request.name) != .library {
                roots.insert(request.root)
                if let variant = variantPlan?.variants[variantKey(request.root, request.platform)] {
                    queue += variant.actualRequests
                } else {
                    queue += try resolution.requests.filter {
                        try $0.root == request.root && $0.platform == request.platform && spec.kind($0.name) == .library
                    }
                }
                continue
            }
            roots.insert(request.root)
            queue += try spec.dependencies(for: request)
        }
        return roots
    }
    func loadVendoredSDKs(_ attributes: [String: Any], root: URL, platform: String) throws -> [NativeVendorSDK] {
        var paths = Set<URL>()
        for pattern in nativeStrings(attributes["vendored_frameworks"])
            + nativeStrings(attributes["vendored_libraries"])
        {
            let matches = try nativeGlob(pattern, root: root)
            guard !matches.isEmpty else {
                throw Diagnostic(
                    "SP-VENDOR-MISSING", stage: "integrate", "Vendored SDK pattern matches no files", file: pattern)
            }
            paths.formUnion(matches)
        }
        let sdks = try paths.sorted { $0.path < $1.path }.map(NativeVendorSDK.init)
        for sdk in sdks where !sdk.supports(platform: platform) {
            throw Diagnostic(
                "SP-VENDOR-PLATFORM", stage: "integrate", "SDK does not support \(platform)", file: sdk.url.path)
        }
        return sdks
    }
}
