import Foundation

/// A native OpenStep project graph. Unknown user project objects are retained.
final class NativePBX {
    var objects: [String: [String: Any]] = [:]
    var root: [String: Any] = [:]
    let url: URL
    private var original: String
    var randomIdentifiers = false
    private var identifiers: [String: String] = [:]
    init(_ url: URL, existing: Bool = false) throws {
        self.url = url
        original = try FileFingerprint.tree(url)
        if existing {
            guard let value = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any],
                  let objects = value["objects"] as? [String: [String: Any]] else { throw Diagnostic("SP-XCODE-PROJECT", stage: "integrate", "Invalid Xcode project", file: url.path) }
            root = value; self.objects = objects
        }
    }
    @discardableResult func add(_ key: String, _ object: [String: Any]) -> String {
        let id = randomIdentifiers ? (identifiers[key] ?? UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24).uppercased()) : Self.identifier(key)
        identifiers[key] = id
        objects[id] = object
        return id
    }
    static func identifier(_ key: String) -> String { String(digest(Data(key.utf8)).prefix(24)).uppercased() }
    func save() throws {
        guard try FileFingerprint.tree(url) == original else { throw Diagnostic("SP-XCODE-CONFLICT", stage: "integrate", "Project changed during installation", file: url.path) }
        root["objects"] = objects
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data(("// !$*UTF8*$!\n" + Self.serialize(root) + "\n").utf8)
        if (try? Data(contentsOf: url)) != data { try data.writeIfChanged(to: url, options: .atomic) }
        original = try FileFingerprint.tree(url)
    }
    static func serialize(_ value: Any, level: Int = 0) -> String {
        let indentation = String(repeating: "\t", count: level)
        let childIndentation = indentation + "\t"
        if let dictionary = value as? [String: Any] {
            let entries: [String] = dictionary.keys.sorted().map { key in
                let serialized = serialize(dictionary[key]!, level: level + 1)
                return "\(childIndentation)\(quote(key)) = \(serialized);"
            }
            return "{\n\(entries.joined(separator: "\n"))\n\(indentation)}"
        }
        if let array = value as? [Any] {
            let entries: [String] = array.map { element in
                "\(childIndentation)\(serialize(element, level: level + 1)),"
            }
            return "(\n\(entries.joined(separator: "\n"))\n\(indentation))"
        }
        return quote(String(describing: value))
    }
    private static func quote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r") + "\""
    }
}

final class NativeXcode {
    let project: URL
    let graph: NativePBX
    let manifest: [String: Any]
    var resolution: NativeResolution
    var hookTargets: [[String: Any]] = []
    private var configurations: [String: [String: String]] = [:]
    var products: [String] = []
    var targetIDs: [String] = []
    var targetOwners: [String: String] = [:]
    var testTargetHosts: [String: String] = [:]
    var userProjects: [String: NativePBX] = [:]
    private var resources: [String] = []
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
    var integrationSettingsURL: URL { project.appendingPathComponent("Pods/Target Support Files/SwiftPods-Integration.json") }
    var staticResources: [String: [URL]] = [:]
    var generatedProjects: [String: NativePBX] = [:]
    var aggregateProject: NativePBX?
    var managedSchemes = Set<URL>()
    var previousInventory: [String: Any] = [:]
    var projectInventoryURL: URL { project.appendingPathComponent("Pods/Target Support Files/SwiftPods-Projects.json") }
    var configurationTypes: [String: String] = ["Debug": "debug", "Release": "release"]
    var platformNames: [String] { Set((manifest["targets"] as? [[String: Any]] ?? []).map { ($0["platform"] as? [String: String])?["name"] ?? "ios" }).sorted() }
    func variantKey(_ name: String, _ platform: String) -> String {
        let root = String(name.split(separator: "/").first ?? "")
        if let key = activeVariants[root], variantPlan?.variants[key]?.platform == platform { return key + (name == root ? "" : "::" + name.dropFirst(root.count + 1)) }
        return name + ":" + platform
    }
    func libraryLabel(_ root: String, _ platform: String) -> String {
        variantPlan?.variants[variantKey(root, platform)]?.label ?? (platformNames.count > 1 ? root + "-" + platform : root)
    }
    var configurationNames: [String] { ["Debug", "Release"] + configurationTypes.keys.filter { !["Debug", "Release"].contains($0) }.sorted() }
    var resourceRoots: [String: String] = [:]
    var frameworkResourceBundles = Set<String>()
    var vendorSDKs: [String: [NativeVendorSDK]] = [:]
    init(project: URL, manifest: [String: Any], resolution: NativeResolution, integrateUserProjects: Bool = true) throws {
        self.project = project; self.manifest = manifest; self.resolution = resolution
        graph = try NativePBX(project.appendingPathComponent("Pods/Pods.xcodeproj/project.pbxproj"))
        if FileManager.default.fileExists(atPath: graph.url.path), let previous = try? NativePBX(graph.url, existing: true) {
            previousProducts = Set(previous.objects.values.compactMap { $0["productReference"] as? String })
        }
        if FileManager.default.fileExists(atPath: projectInventoryURL.path) {
            previousInventory = try NativeProjectInventory.load(projectInventoryURL, root: project.appendingPathComponent("Pods"))
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
                if let name = object["name"] as? String { configurationTypes[name] = name.lowercased().contains("debug") ? "debug" : "release" }
            }
        }
        for target in [manifest] + (manifest["targets"] as? [[String: Any]] ?? []) {
            for (name, kind) in target["configurations"] as? [String: String] ?? [:] {
                guard !name.isEmpty, ["debug", "release"].contains(kind) else { throw Diagnostic("SP-XCODE-CONFIG", stage: "integrate", "Configuration mapping values must be debug/release", file: name) }
                configurationTypes[name] = kind
            }
        }
        var analyzed = manifest
        analyzed["targets"] = try (manifest["targets"] as? [[String: Any]] ?? []).map { original -> [String: Any] in
            var target = original
            if target["swift_version"] == nil, integrateUserProjects, let user = userProjects[try projectPath(target).path],
               let native = user.objects.values.first(where: { $0["isa"] as? String == "PBXNativeTarget" && $0["name"] as? String == target["name"] as? String }),
               let list = native["buildConfigurationList"] as? String {
                target["swift_version"] = (user.objects[list]?["buildConfigurations"] as? [String] ?? []).compactMap { id -> String? in
                    let value = (user.objects[id]?["buildSettings"] as? [String: Any])?["SWIFT_VERSION"] as? String
                    return value?.range(of: #"\A[0-9]+(?:\.[0-9]+)*\z"#, options: .regularExpression) != nil ? value : nil
                }.first
            }
            return target
        }
        variantPlan = try NativeVariantPlan(manifest: analyzed, resolution: resolution)
    }
    func workspacePath() -> URL? {
        guard let first = userProjects.values.sorted(by: { $0.url.path < $1.url.path }).first else { return nil }
        let name = manifest["workspace"] as? String ?? first.url.deletingLastPathComponent().deletingPathExtension().lastPathComponent
        let value = name.hasSuffix(".xcworkspace") ? name : name + ".xcworkspace"
        let path = value.hasPrefix("/") ? URL(fileURLWithPath: value) : project.appendingPathComponent(value)
        return path.standardizedFileURL.resolvingSymlinksInPath().appendingPathComponent("contents.xcworkspacedata")
    }
    private func projectPath(_ target: [String: Any]) throws -> URL {
        if let path = target["project"] as? String ?? manifest["project"] as? String {
            let url = URL(fileURLWithPath: path, relativeTo: project).standardizedFileURL
            return (url.pathExtension == "xcodeproj" ? url : url.appendingPathExtension("xcodeproj")).appendingPathComponent("project.pbxproj")
        }
        let found = try FileManager.default.contentsOfDirectory(at: project, includingPropertiesForKeys: nil).filter { $0.pathExtension == "xcodeproj" }
        guard found.count == 1 else { throw Diagnostic("SP-XCODE-AMBIGUOUS", stage: "integrate", "Specify project 'Name.xcodeproj' in the Podfile") }
        return found[0].appendingPathComponent("project.pbxproj")
    }
    func configList(_ name: String, settings: [String: Any]) -> String {
        var ids: [String: String] = [:]
        let entries: [[String: Any]] = configurationNames.map { configuration in
            var value = settings
            value["SWIFT_OPTIMIZATION_LEVEL"] = configurationTypes[configuration] == "debug" ? "-Onone" : "-O"
            value["GCC_OPTIMIZATION_LEVEL"] = configurationTypes[configuration] == "debug" ? "0" : "s"
            if value["ENABLE_TESTABILITY"] == nil { value["ENABLE_TESTABILITY"] = configurationTypes[configuration] == "debug" ? "YES" : "NO" }
            let id = graph.add("config:\(name):\(configuration)", ["isa": "XCBuildConfiguration", "name": configuration, "buildSettings": value])
            ids[configuration] = id
            return ["name": configuration, "build_settings": value]
        }
        configurations[name] = ids
        if name != "Pods" { hookTargets.append(["name": name, "build_configurations": entries]) }
        return graph.add("configs:" + name, ["isa": "XCConfigurationList", "buildConfigurations": configurationNames.compactMap { ids[$0] }, "defaultConfigurationName": "Release", "defaultConfigurationIsVisible": "0"])
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
        graph.add("phase:\(target):\(kind)", ["isa": kind, "buildActionMask": "2147483647", "files": files, "runOnlyForDeploymentPostprocessing": "0"])
    }
    func baseSettings(platform: String, deployment: String) -> [String: Any] {
        let sdk = ["osx": "macosx", "ios": "iphoneos", "tvos": "appletvos", "watchos": "watchos", "visionos": "xros"][platform] ?? "iphoneos"
        let minimum = ["osx": "MACOSX_DEPLOYMENT_TARGET", "ios": "IPHONEOS_DEPLOYMENT_TARGET", "tvos": "TVOS_DEPLOYMENT_TARGET", "watchos": "WATCHOS_DEPLOYMENT_TARGET", "visionos": "XROS_DEPLOYMENT_TARGET"][platform] ?? "IPHONEOS_DEPLOYMENT_TARGET"
        return ["SDKROOT": sdk, minimum: deployment, "ALWAYS_SEARCH_USER_PATHS": "NO", "CLANG_ENABLE_MODULES": "YES", "CLANG_ENABLE_OBJC_ARC": "YES", "DEFINES_MODULE": "YES", "SWIFT_VERSION": "5.0", "CODE_SIGNING_ALLOWED": "NO", "COPY_PHASE_STRIP": "NO", "GENERATE_INFOPLIST_FILE": "YES", "SKIP_INSTALL": "YES", "GCC_TREAT_WARNINGS_AS_ERRORS": "YES", "SWIFT_TREAT_WARNINGS_AS_ERRORS": "YES", "GCC_PREPROCESSOR_DEFINITIONS": ["$(inherited)", "COCOAPODS=1"], "CONFIGURATION_BUILD_DIR": "$(BUILD_DIR)/$(CONFIGURATION)$(EFFECTIVE_PLATFORM_NAME)"]
    }
    func dependencyRoots(_ requests: [NativeDependency], includeSupplementary: Bool = false) throws -> Set<String> {
        var queue = requests, names = Set<String>(), roots = Set<String>()
        while let request = queue.popLast() {
            guard names.insert(request.name).inserted else { continue }
            guard let spec = resolution.specs[request.root] else { continue }
            if !includeSupplementary, try spec.kind(request.name) != .library {
                roots.insert(request.root)
                if let variant = variantPlan?.variants[variantKey(request.root, request.platform)] { queue += variant.actualRequests }
                else { queue += try resolution.requests.filter { try $0.root == request.root && $0.platform == request.platform && spec.kind($0.name) == .library } }
                continue
            }
            roots.insert(request.root)
            queue += try spec.dependencies(for: request)
        }
        return roots
    }
    func loadVendoredSDKs(_ attributes: [String: Any], root: URL, platform: String) throws -> [NativeVendorSDK] {
        var paths = Set<URL>()
        for pattern in nativeStrings(attributes["vendored_frameworks"]) + nativeStrings(attributes["vendored_libraries"]) {
            let matches = try nativeGlob(pattern, root: root)
            guard !matches.isEmpty else { throw Diagnostic("SP-VENDOR-MISSING", stage: "integrate", "Vendored SDK pattern matches no files", file: pattern) }
            paths.formUnion(matches)
        }
        let sdks = try paths.sorted { $0.path < $1.path }.map(NativeVendorSDK.init)
        for sdk in sdks where !sdk.supports(platform: platform) { throw Diagnostic("SP-VENDOR-PLATFORM", stage: "integrate", "SDK does not support \(platform)", file: sdk.url.path) }
        return sdks
    }
    func generate() throws {
        let targets = manifest["targets"] as? [[String: Any]] ?? []
        for variant in variantPlan?.variants.values.sorted(by: { $0.label < $1.label }) ?? [] {
            selectVariant(variant)
            let platform = variant.platform, name = variant.root
            guard let spec = resolution.specs[name], let directory = spec.directory else { continue }
            let requests = try variant.names.map { try NativeDependency(["name": $0], platform: platform, deployment: variant.consumerDeployment) }
            let attributes = try NativeVariantPlan.attributes(spec, names: variant.names, platform: platform)
            let targetName = variant.label
            var module = spec.moduleName
            if attributes["module_name"] == nil, module.first?.isNumber == true { module = "_" + module }
            guard module.range(of: #"\A[A-Za-z_][A-Za-z0-9_]*\z"#, options: .regularExpression) != nil else { throw Diagnostic("SP-XCODE-MODULE", stage: "integrate", "Invalid module name", file: name) }
            let mode = variant.mode
            let useFramework = mode != "library", dynamic = mode == "dynamic"
            let minimum = (attributes["platforms"] as? [String: Any])?[platform] as? String ?? attributes["deployment_target"] as? String ?? variant.consumerDeployment
            var settings = baseSettings(platform: platform, deployment: minimum)
            settings["HEADERMAP_INCLUDES_PROJECT_HEADERS"] = "NO"
            if variant.scoped { settings["CONFIGURATION_BUILD_DIR"] = "$(BUILD_DIR)/$(CONFIGURATION)$(EFFECTIVE_PLATFORM_NAME)/" + targetName }
            if let arc = attributes["requires_arc"] as? Bool { settings["CLANG_ENABLE_OBJC_ARC"] = arc ? "YES" : "NO" }
            settings.merge(NativeSpec.xcconfig(attributes, key: "pod_target_xcconfig")) { _, new in new }
            settings["PRODUCT_NAME"] = module; settings["PRODUCT_MODULE_NAME"] = module
            settings["PODS_ROOT"] = project.appendingPathComponent("Pods").path
            settings["PODS_PODFILE_DIR_PATH"] = project.path
            settings["PODS_TARGET_SRCROOT"] = directory.path
            settings["PRODUCT_BUNDLE_IDENTIFIER"] = "org.swiftpods." + module.replacingOccurrences(of: "_", with: "-")
            settings["SWIFT_VERSION"] = variant.swiftVersion ?? "5.0"
            if inhibitWarnings(variant) { settings["GCC_WARN_INHIBIT_ALL_WARNINGS"] = "YES"; settings["SWIFT_SUPPRESS_WARNINGS"] = "YES" }
            if manifest["set_arc_compatibility_flag"] as? Bool == true, attributes["requires_arc"] as? Bool != false { settings["OTHER_LDFLAGS"] = ["$(inherited)", "-fobjc-arc"] }
            if useFramework { settings["MACH_O_TYPE"] = dynamic ? "mh_dylib" : "staticlib" }
            if dynamic { settings["LD_DYLIB_INSTALL_NAME"] = "@rpath/$(EXECUTABLE_PATH)" }
            if attributes["compiler_flags"] != nil { settings["OTHER_CFLAGS"] = "$(inherited) " + nativeStrings(attributes["compiler_flags"]).joined(separator: " ") }
            let all = try NativeFileSelection.sourceFiles(attributes, root: directory)
            let supplementarySources = try variant.supplementary.flatMap { request -> [URL] in
                let own = try spec.supplementaryAttributes(request.name, platform: platform)
                return try NativeFileSelection.sourceFiles(own, root: directory)
            }
            let modular = requiresModule(variant, attributes: attributes, sources: all + supplementarySources)
            settings["DEFINES_MODULE"] = modular ? "YES" : "NO"
            let rules = try NativeFileRules(attributes, root: directory, files: all)
            try compileSettings(attributes, root: directory, label: targetName, settings: &settings)
            var sources: [String] = [], headers: [String] = []
            for source in all {
                let reference = file(source.path)
                if NativeFileSelection.headers.contains(source.pathExtension) {
                    // Archives expose headers through the sandbox's mappings;
                    // a Headers phase would flatten them into usr/local/include.
                    if useFramework { headers.append(buildFile(reference, target: targetName, settings: rules.headerSettings(source))) }
                }
                else if NativeFileSelection.sources.contains(source.pathExtension) { sources.append(buildFile(reference, target: targetName, settings: rules.sourceSettings(source))) }
            }
            if sources.isEmpty {
                let dummy = project.appendingPathComponent("Pods/Target Support Files/" + targetName + "/dummy.m")
                try FileManager.default.createDirectory(at: dummy.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("void swiftpods_\(module)_dummy(void) {}\n".utf8).writeIfChanged(to: dummy)
                sources.append(buildFile(file(dummy.path), target: targetName))
            }
            let linkedFrameworks = nativeStrings(attributes["frameworks"])
            let weakFrameworks = nativeStrings(attributes["weak_frameworks"])
            var frameworks = (linkedFrameworks + weakFrameworks).map { framework in
                buildFile(file("System/Library/Frameworks/" + framework + ".framework", type: "wrapper.framework", sourceTree: "SDKROOT"), target: targetName, settings: weakFrameworks.contains(framework) ? ["ATTRIBUTES": ["Weak"]] : [:])
            }
            let sdks = try loadVendoredSDKs(attributes, root: directory, platform: platform)
            for sdk in sdks {
                frameworks.append(buildFile(file(sdk.url.path, type: sdk.fileType), target: targetName))
            }
            vendorSDKs[variantKey(name, platform)] = sdks
            settings["OTHER_LDFLAGS"] = ["$(inherited)"] + nativeStrings(settings["OTHER_LDFLAGS"]) + nativeStrings(attributes["libraries"]).map { "-l" + $0 }
            // Recursive pod-root search would expose headers from every
            // XCFramework slice, bypassing Xcode's destination selection.
            let headerDirectories = Set(all.filter { NativeFileSelection.headers.contains($0.pathExtension) }.map { $0.deletingLastPathComponent().path }).sorted()
            for (key, paths) in [
                "HEADER_SEARCH_PATHS": [directory.path, project.appendingPathComponent(headerDirectory(name, platform: platform)).path] + headerDirectories + sdks.filter { !$0.isXCFramework }.compactMap { $0.slices.first?.headers?.path },
                "FRAMEWORK_SEARCH_PATHS": sdks.filter { !$0.isXCFramework && $0.isFramework }.map { $0.url.deletingLastPathComponent().path },
                "LIBRARY_SEARCH_PATHS": sdks.filter { !$0.isXCFramework && !$0.isFramework }.map { $0.url.deletingLastPathComponent().path }
            ] {
                var values = nativeStrings(settings[key]); if values.isEmpty { values = ["$(inherited)"] }
                for path in paths.map(NativeBuildSetting.path) where !values.contains(path) { values.append(path) }; settings[key] = values
            }
            if !useFramework {
                let publicRoot = project.appendingPathComponent(headerDirectory(name, platform: platform) + "/" + (try NativeFileRules.headerDirectory(attributes, module: module)))
                try FileManager.default.createDirectory(at: publicRoot, withIntermediateDirectories: true)
                let publicHeaders = rules.publicHeaders.sorted { $0.path < $1.path }
                var destinations = Set<String>()
                for header in publicHeaders {
                    let relative = try NativeFileRules.headerPath(header, attributes: attributes, root: directory)
                    guard destinations.insert(relative).inserted else { throw Diagnostic("SP-SPEC-HEADER-COLLISION", stage: "integrate", "Multiple public headers map to " + relative, file: name) }
                    let destination = publicRoot.appendingPathComponent(relative)
                    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
                    try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: header)
                }
                let umbrella = publicRoot.appendingPathComponent(module + "-umbrella.h")
                let content = "#ifdef __OBJC__\n#import <Foundation/Foundation.h>\n#endif\n" + (try publicHeaders.map { "#include \"" + (try NativeFileRules.headerPath($0, attributes: attributes, root: directory)) + "\"" }).joined(separator: "\n") + "\n"
                try Data(content.utf8).writeIfChanged(to: umbrella, options: .atomic)
                let modulemap = publicRoot.appendingPathComponent("module.modulemap")
                if modular {
                    try Data(("module " + module + " { umbrella header \"" + umbrella.lastPathComponent + "\" export * module * { export * } }\n").utf8).writeIfChanged(to: modulemap, options: .atomic)
                    if attributes["module_map"] == nil { settings["MODULEMAP_FILE"] = modulemap.path }
                } else if FileManager.default.fileExists(atPath: modulemap.path) { try FileManager.default.removeItem(at: modulemap) }
            }
            if useFramework && attributes["module_map"] == nil {
                let support = project.appendingPathComponent("Pods/Target Support Files/" + targetName)
                try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
                let umbrella = support.appendingPathComponent(module + "-umbrella.h")
                let publicHeaders = rules.publicHeaders.sorted { $0.path < $1.path }
                let content = "#ifdef __OBJC__\n#import <Foundation/Foundation.h>\n#endif\n" + (try publicHeaders.map { "#include \"" + (try NativeFileRules.headerPath($0, attributes: attributes, root: directory)) + "\"" }).joined(separator: "\n") + "\n"
                try Data(content.utf8).writeIfChanged(to: umbrella, options: .atomic)
                headers.append(buildFile(file(umbrella.path), target: targetName, settings: ["ATTRIBUTES": ["Public"]]))
                let modulemap = support.appendingPathComponent(module + ".modulemap")
                try Data(("framework module " + module + " { umbrella header \"" + umbrella.lastPathComponent + "\" export * module * { export * } }\n").utf8).writeIfChanged(to: modulemap, options: .atomic)
                settings["MODULEMAP_FILE"] = modulemap.path
            }
            if useFramework, let additional = attributes["info_plist"] as? [String: Any] {
                let info = project.appendingPathComponent("Pods/Target Support Files/" + targetName + "/Info.plist")
                try FileManager.default.createDirectory(at: info.deletingLastPathComponent(), withIntermediateDirectories: true)
                var plist: [String: Any] = ["CFBundleExecutable": "$(EXECUTABLE_NAME)", "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)", "CFBundleName": "$(PRODUCT_NAME)", "CFBundlePackageType": "FMWK", "CFBundleVersion": "1", "CFBundleShortVersionString": spec.version.description]
                plist.merge(additional) { _, new in new }
                try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).writeIfChanged(to: info, options: .atomic)
                settings["INFOPLIST_FILE"] = info.path; settings["GENERATE_INFOPLIST_FILE"] = "NO"
            }
            let product = graph.add("product:" + targetName, ["isa": "PBXFileReference", "explicitFileType": useFramework ? "wrapper.framework" : "archive.ar", "path": useFramework ? module + ".framework" : "lib" + module + ".a", "sourceTree": "BUILT_PRODUCTS_DIR"])
            products.append(product); productRoots[product] = name; productPlatforms[product] = platform
            productVariants[product] = variant.key
            productBuildPaths[product] = (variant.scoped ? targetName + "/" : "") + (useFramework ? module + ".framework" : "lib" + module + ".a")
            let list = configList(targetName, settings: settings)
            let identifier = graph.add("target:" + targetName, ["isa": "PBXNativeTarget", "name": targetName, "productName": module, "productReference": product, "productType": useFramework ? "com.apple.product-type.framework" : "com.apple.product-type.library.static", "buildConfigurationList": list, "buildPhases": [phase("PBXHeadersBuildPhase", target: targetName, files: headers), phase("PBXSourcesBuildPhase", target: targetName, files: sources), phase("PBXFrameworksBuildPhase", target: targetName, files: frameworks)], "buildRules": [], "dependencies": []])
            var scriptRequests = Set<String>()
            let scripts = try requests.filter { scriptRequests.insert($0.name).inserted }.flatMap { try spec.scriptPhases(for: $0) }
            NativeScriptPhase.apply(scripts, target: identifier, graph: graph)
            targetIDs.append(identifier); targetOwners[identifier] = name; libraryTargets[variantKey(name, platform)] = identifier
            if useFramework, attributes["header_mappings_dir"] != nil { try mapFrameworkHeaders(rules.publicHeaders, attributes: attributes, root: directory, target: identifier, label: targetName) }
            let directPaths = try NativeFileSelection.paths(attributes["resources"], attributes: attributes, root: directory)
            if dynamic {
                let refs = try NativeResources.references(directPaths, owner: targetName, graph: graph)
                if !refs.isEmpty {
                    var phases = graph.objects[identifier]?["buildPhases"] as? [String] ?? []
                    phases.append(phase("PBXResourcesBuildPhase", target: targetName, files: refs.map { buildFile($0, target: targetName) }))
                    graph.objects[identifier]?["buildPhases"] = phases
                }
            } else { staticResources[variantKey(name, platform)] = directPaths }
            for (bundle, patterns) in attributes["resource_bundles"] as? [String: Any] ?? [:] {
                guard bundle.range(of: #"\A[A-Za-z0-9_][A-Za-z0-9_.+-]*\z"#, options: .regularExpression) != nil else { throw Diagnostic("SP-XCODE-RESOURCE", stage: "integrate", "Invalid resource bundle name", file: name) }
                let bundleLabel = variant.scoped ? targetName + "-" + bundle : platformNames.count > 1 ? bundle + "-" + platform : bundle
                let resourceReferences = try NativeResources.references(NativeFileSelection.paths(patterns, attributes: attributes, root: directory), owner: bundleLabel, graph: graph)
                let resources = resourceReferences.map { buildFile($0, target: bundleLabel) }
                let bundleProduct = graph.add("product:" + bundleLabel, ["isa": "PBXFileReference", "explicitFileType": "wrapper.cfbundle", "path": bundle + ".bundle", "sourceTree": "BUILT_PRODUCTS_DIR"])
                var bundleSettings = baseSettings(platform: platform, deployment: minimum).merging(["PRODUCT_NAME": bundle, "PRODUCT_BUNDLE_IDENTIFIER": "org.swiftpods." + bundle]) { _, new in new }
                if variant.scoped { bundleSettings["CONFIGURATION_BUILD_DIR"] = "$(BUILD_DIR)/$(CONFIGURATION)$(EFFECTIVE_PLATFORM_NAME)/" + targetName }
                let bundleTarget = graph.add("target:" + bundleLabel, ["isa": "PBXNativeTarget", "name": bundleLabel, "productName": bundle, "productReference": bundleProduct, "productType": "com.apple.product-type.bundle", "buildConfigurationList": configList(bundleLabel, settings: bundleSettings), "buildPhases": [phase("PBXResourcesBuildPhase", target: bundleLabel, files: resources)], "buildRules": [], "dependencies": []])
                products.append(bundleProduct); productPlatforms[bundleProduct] = platform; targetIDs.append(bundleTarget); targetOwners[bundleTarget] = name; self.resources.append(bundle + ".bundle"); resourceRoots[bundle + ".bundle"] = name
                productVariants[bundleProduct] = variant.key
                resourceBundleTargets[variant.key, default: []].append(bundleTarget)
                productBuildPaths[bundleProduct] = (variant.scoped ? targetName + "/" : "") + bundle + ".bundle"
                let resourceDependency = graph.add("dependency:" + identifier + ":" + bundleTarget, ["isa": "PBXTargetDependency", "target": bundleTarget])
                var resourceDependencies = graph.objects[identifier]?["dependencies"] as? [String] ?? []
                resourceDependencies.append(resourceDependency); graph.objects[identifier]?["dependencies"] = resourceDependencies
                if dynamic {
                    frameworkResourceBundles.insert(bundleProduct)
                    var phases = graph.objects[identifier]?["buildPhases"] as? [String] ?? []
                    let resourcePhase = phases.first { graph.objects[$0]?["isa"] as? String == "PBXResourcesBuildPhase" } ?? phase("PBXResourcesBuildPhase", target: targetName, files: [])
                    var files = graph.objects[resourcePhase]?["files"] as? [String] ?? []
                    files.append(buildFile(bundleProduct, target: targetName)); graph.objects[resourcePhase]?["files"] = files
                    if !phases.contains(resourcePhase) { phases.append(resourcePhase) }
                    graph.objects[identifier]?["buildPhases"] = phases
                }
            }
        }
        // Dependencies between native pod targets let Xcode order Swift modules.
        for id in targetIDs {
            guard let entry = libraryTargets.first(where: { $0.value == id }), let variant = variantPlan?.variants[entry.key],
                  let product = graph.objects[id]?["productReference"] as? String,
                  let platform = productPlatforms[product], let name = productRoots[product] else { continue }
            selectVariant(variant)
            let label = variant.label
            let requests = variant.actualRequests
            let roots = try dependencyRoots(requests).subtracting([name])
            let dependencies = roots.sorted().compactMap { dependency -> String? in
                guard let target = libraryTargets[variantKey(dependency, platform)] else { return nil }
                return graph.add("dependency:\(id):\(target)", ["isa": "PBXTargetDependency", "target": target])
            }
            let previousDependencies = graph.objects[id]?["dependencies"] as? [String] ?? []
            graph.objects[id]?["dependencies"] = previousDependencies + dependencies
            // Source wrappers must see SDKs supplied by transitive binary pods,
            // including Xcode's selected XCFramework headers and frameworks.
            let sdks = roots.sorted().flatMap { vendorSDKs[variantKey($0, platform)] ?? [] }
            if let phases = graph.objects[id]?["buildPhases"] as? [String], let phase = phases.first(where: { graph.objects[$0]?["isa"] as? String == "PBXFrameworksBuildPhase" }) {
                var files = graph.objects[phase]?["files"] as? [String] ?? []
                let references = sdks.map { file($0.url.path, type: $0.fileType) } + products.filter { matchesProduct($0, roots: roots, platform: platform) && productRoots[$0] != nil }.map(buildReference)
                for reference in references {
                    let build = buildFile(reference, target: label)
                    if !files.contains(build) { files.append(build) }
                }
                graph.objects[phase]?["files"] = files
            }
            let libraryDirectories = librarySearchDirectories(roots, platform: platform)
            let frameworkDirectories = sdks.filter { !$0.isXCFramework && $0.isFramework }.map { $0.url.deletingLastPathComponent().path }
            let staticDirectories = sdks.filter { !$0.isXCFramework && !$0.isFramework }.map { $0.url.deletingLastPathComponent().path }
            let sdkHeaderDirectories = sdks.filter { !$0.isXCFramework }.compactMap { $0.slices.first?.headers?.path }
            let searchPaths: [String: [String]] = [
                "FRAMEWORK_SEARCH_PATHS": ["$(BUILT_PRODUCTS_DIR)"] + libraryDirectories + frameworkDirectories,
                "LIBRARY_SEARCH_PATHS": ["$(BUILT_PRODUCTS_DIR)"] + libraryDirectories + staticDirectories,
                "SWIFT_INCLUDE_PATHS": libraryDirectories,
                "HEADER_SEARCH_PATHS": headerSettings(roots, platform: platform) + sdkHeaderDirectories
            ]
            for config in configurations[label].map({ Array($0.values) }) ?? [] {
                var settings = graph.objects[config]?["buildSettings"] as? [String: Any] ?? [:]
                for (key, paths) in searchPaths {
                    var values = nativeStrings(settings[key]); if values.isEmpty { values = ["$(inherited)"] }
                    for path in paths.map(NativeBuildSetting.path) where !values.contains(path) { values.append(path) }; settings[key] = values
                }
                graph.objects[config]?["buildSettings"] = settings
            }
        }
        try generateSupplementaryTargets()
        for target in targets {
            selectConsumer(target)
            let platform = target["platform"] as? [String: String] ?? [:]
            let name = target["name"] as? String ?? ""
            let requests = try (nativeDependencies(target) + nativeDependencies(target, search: true)).flatMap { try NativeDependency($0, platform: platform["name"] ?? "ios", deployment: platform["deployment_target"] ?? "0").expandedSelections() }
            let roots = try dependencyRoots(requests)
            let label = target["label"] as? String ?? "Pods-" + name
            let deps = roots.sorted().compactMap { libraryTargets[variantKey($0, platform["name"] ?? "ios")] }.map { graph.add("aggregate-dependency:" + label + ":" + $0, ["isa": "PBXTargetDependency", "target": $0]) }
            let id = graph.add("aggregate:" + label, ["isa": "PBXAggregateTarget", "name": label, "productName": label, "buildConfigurationList": configList(label, settings: baseSettings(platform: platform["name"] ?? "ios", deployment: platform["deployment_target"] ?? "0")), "buildPhases": [], "dependencies": deps])
            targetIDs.append(id); aggregateTargets[nativeConsumerKey(target)] = id
        }
        let allProducts = targetIDs.compactMap { graph.objects[$0]?["productReference"] as? String }
        let productGroup = graph.add("products", ["isa": "PBXGroup", "name": "Products", "sourceTree": "<group>", "children": allProducts])
        let variants = graph.objects.filter { $0.value["isa"] as? String == "PBXVariantGroup" }
        let localizedChildren = Set(variants.values.flatMap { $0["children"] as? [String] ?? [] })
        let files = graph.objects.filter { $0.value["isa"] as? String == "PBXFileReference" && !allProducts.contains($0.key) && !localizedChildren.contains($0.key) }.map(\.key).sorted() + variants.keys.sorted()
        let group = graph.add("group", ["isa": "PBXGroup", "sourceTree": "<group>", "children": files + [productGroup]])
        var projectAttributes: [String: Any] = ["LastUpgradeCheck": "1600"]
        let assetTags = Set(graph.objects.values.flatMap { nativeStrings(($0["settings"] as? [String: Any])?["ASSET_TAGS"]) })
        if !assetTags.isEmpty { projectAttributes["KnownAssetTags"] = assetTags.sorted() }
        if !testTargetHosts.isEmpty { projectAttributes["TargetAttributes"] = testTargetHosts.mapValues { ["TestTargetID": $0] } }
        let root = graph.add("project", ["isa": "PBXProject", "attributes": projectAttributes, "buildConfigurationList": configList("Pods", settings: [:]), "compatibilityVersion": "Xcode 14.0", "developmentRegion": "en", "hasScannedForEncodings": "0", "knownRegions": ["en", "Base"], "mainGroup": group, "productRefGroup": productGroup, "projectDirPath": "", "projectRoot": "", "targets": targetIDs])
        graph.root = ["archiveVersion": "1", "objectVersion": "56", "classes": [:], "rootObject": root]
        try developmentSchemes()
        organizeSourceGroups()
        try generateBridgeSupport()
        try podConfigurations()
        for index in hookTargets.indices {
            guard let name = hookTargets[index]["name"] as? String, let mapping = configurations[name] else { continue }
            hookTargets[index]["build_configurations"] = configurationNames.compactMap { configuration -> [String: Any]? in
                guard let id = mapping[configuration], let settings = graph.objects[id]?["buildSettings"] else { return nil }
                return ["name": configuration, "build_settings": settings]
            }
        }
    }
    var hookProject: [String: Any] { hookDescription() }
    func applyHook(_ value: [String: Any]) throws {
        if value["generated"] as? Bool == false { return }
        if value["graph"] != nil {
            try applyHookGraph(value, to: podsProject)
            for child in value["projects"] as? [[String: Any]] ?? [] {
                guard let path = child["path"] as? String, let destination = generatedProjects[path] else { throw Diagnostic("SP-HOOK-PROJECT", stage: "hook", "Unknown generated project") }
                try applyHookGraph(child, to: destination)
            }
            return
        }
        guard let targets = value["targets"] as? [[String: Any]], targets.count == hookTargets.count else { throw Diagnostic("SP-HOOK-UNSUPPORTED", stage: "hook", "Changing target membership through hooks is not implemented") }
        for target in targets {
            guard let name = target["name"] as? String, let mapping = configurations[name] else { throw Diagnostic("SP-HOOK-UNSUPPORTED", stage: "hook", "Hook returned an unknown target") }
            for configuration in target["build_configurations"] as? [[String: Any]] ?? [] {
                guard let name = configuration["name"] as? String, let id = mapping[name], let settings = configuration["build_settings"] as? [String: Any] else { throw Diagnostic("SP-HOOK-UNSUPPORTED", stage: "hook", "Invalid hook configuration") }
                graph.objects[id]?["buildSettings"] = settings
            }
        }
        hookTargets = targets
    }
    func savePods() throws -> URL {
        if multipleProjects { try saveMultipleProjects() }
        try podsProject.save()
        try saveProjectInventory()
        return podsProject.url
    }
    func integrate() throws -> [URL] {
        var originalAttributes: [String: [String: Any]] = [:]
        let previousAttributes = integrationSettings["_project_attributes"] as? [String: [String: Any]] ?? [:]
        for user in userProjects.values {
            removePreviousAggregateIntegration(user)
            if let root = user.root["rootObject"] as? String {
                let current = user.objects[root]?["attributes"] as? [String: Any] ?? [:]
                let restored = try NativeIntegrationSettings.restore(current, record: previousAttributes[user.url.path] ?? [:])
                user.objects[root]?["attributes"] = restored; originalAttributes[user.url.path] = restored
            }
        }
        for target in manifest["targets"] as? [[String: Any]] ?? [] {
            selectConsumer(target)
            let path = try projectPath(target), name = target["name"] as? String ?? ""
            guard let user = userProjects[path.path], let targetID = user.objects.first(where: { $0.value["isa"] as? String == "PBXNativeTarget" && $0.value["name"] as? String == name })?.key else { throw Diagnostic("SP-XCODE-TARGET", stage: "integrate", "Target \(name) does not exist", file: path.path) }
            let group = (user.root["rootObject"] as? String).flatMap { user.objects[$0]?["mainGroup"] as? String }
            var linked: [String] = [], embedded: [String] = []
            let platform = target["platform"] as? [String: String] ?? [:]
            let requests = try (target["dependencies"] as? [[String: Any]] ?? []).flatMap { try NativeDependency($0, platform: platform["name"] ?? "ios", deployment: platform["deployment_target"] ?? "0").expandedSelections() }
            let searchRequests = try nativeDependencies(target, search: true).flatMap { try NativeDependency($0, platform: platform["name"] ?? "ios", deployment: platform["deployment_target"] ?? "0").expandedSelections() }
            var configuredRoots: [String: Set<String>] = [:]
            for configuration in configurationNames {
                configuredRoots[configuration] = try dependencyRoots(requests.filter { dependencyEnabled($0, configuration: configuration) })
            }
            let eligibleRoots = configuredRoots.values.reduce(into: Set<String>()) { $0.formUnion($1) }
            let searchRoots = try dependencyRoots(searchRequests).union(eligibleRoots)
            let conditionalRoots = eligibleRoots.subtracting(configuredRoots.values.reduce(eligibleRoots) { $0.intersection($1) })
            if let aggregate = aggregateTargets[nativeConsumerKey(target)] {
                let portal = user.add("swiftpods:pods-project", ["isa": "PBXFileReference", "path": project.appendingPathComponent("Pods/Pods.xcodeproj").path, "sourceTree": "<absolute>", "lastKnownFileType": "wrapper.pb-project"])
                let label = target["label"] as? String ?? "Pods-" + name
                let proxy = user.add("swiftpods:aggregate-proxy:" + targetID, ["isa": "PBXContainerItemProxy", "containerPortal": portal, "proxyType": "1", "remoteGlobalIDString": aggregate, "remoteInfo": label])
                let dependency = user.add("swiftpods:aggregate-dependency:" + targetID, ["isa": "PBXTargetDependency", "name": label, "targetProxy": proxy])
                var dependencies = user.objects[targetID]?["dependencies"] as? [String] ?? []
                if !dependencies.contains(dependency) { dependencies.append(dependency) }; user.objects[targetID]?["dependencies"] = dependencies
                if let group { var children = user.objects[group]?["children"] as? [String] ?? []; if !children.contains(portal) { children.append(portal) }; user.objects[group]?["children"] = children }
            }
            consumerVariantDependencies(user, target: targetID, roots: eligibleRoots, platform: platform["name"] ?? "ios")
            for product in products where graph.objects[product]?["explicitFileType"] as? String != "wrapper.cfbundle" && matchesProduct(product, roots: eligibleRoots, platform: platform["name"] ?? "ios") {
                let value = consumerProduct(product)
                let reference = user.add("swiftpods:product:" + product, value)
                let build = user.add("swiftpods:build:" + product, ["isa": "PBXBuildFile", "fileRef": reference])
                if !conditionalRoots.contains(productRoots[product] ?? "") { linked.append(build) }
                let dynamicTarget = graph.objects.values.first { $0["productReference"] as? String == product }
                if let list = dynamicTarget?["buildConfigurationList"] as? String,
                   let config = (graph.objects[list]?["buildConfigurations"] as? [String])?.first,
                   (graph.objects[config]?["buildSettings"] as? [String: Any])?["MACH_O_TYPE"] as? String == "mh_dylib", !conditionalRoots.contains(productRoots[product] ?? "") {
                    embedded.append(user.add("swiftpods:embed:" + product, ["isa": "PBXBuildFile", "fileRef": reference, "settings": ["ATTRIBUTES": ["CodeSignOnCopy", "RemoveHeadersOnCopy"]]]))
                }
                if let group { var children = user.objects[group]?["children"] as? [String] ?? []; if !children.contains(reference) { children.append(reference) }; user.objects[group]?["children"] = children }
            }
            let targetSDKs = eligibleRoots.sorted().flatMap { vendorSDKs[variantKey($0, platform["name"] ?? "ios")] ?? [] }
            try validateExistingPackages(user, target: targetID, roots: eligibleRoots, platform: platform["name"] ?? "ios")
            var sdkNames: [String: String] = [:]
            for sdk in targetSDKs {
                if let before = sdkNames[sdk.productName], before != sdk.url.path { throw Diagnostic("SP-DUPLICATE-SDK", stage: "integrate", "Two vendored SDKs supply \(sdk.productName)", file: sdk.url.path) }
                sdkNames[sdk.productName] = sdk.url.path
                let key = "swiftpods:vendor:" + sdk.url.path
                let reference = user.add(key, ["isa": "PBXFileReference", "path": sdk.url.path, "sourceTree": "<absolute>", "lastKnownFileType": sdk.fileType])
                let build = user.add(key + ":link", ["isa": "PBXBuildFile", "fileRef": reference])
                if !linked.contains(build) { linked.append(build) }
                if sdk.dynamic {
                    embedded.append(user.add(key + ":embed", ["isa": "PBXBuildFile", "fileRef": reference, "settings": ["ATTRIBUTES": ["CodeSignOnCopy", "RemoveHeadersOnCopy"]]]))
                }
                if let group { var children = user.objects[group]?["children"] as? [String] ?? []; if !children.contains(reference) { children.append(reference) }; user.objects[group]?["children"] = children }
            }
            var phases = user.objects[targetID]?["buildPhases"] as? [String] ?? []
            let frameworkPhase = phases.first { user.objects[$0]?["isa"] as? String == "PBXFrameworksBuildPhase" } ?? user.add("swiftpods:frameworkphase:" + targetID, ["isa": "PBXFrameworksBuildPhase", "buildActionMask": "2147483647", "runOnlyForDeploymentPostprocessing": "0", "files": []])
            let managedLinks = Set(previousProducts.union(products).map { NativePBX.identifier("swiftpods:build:" + $0) })
            var files = (user.objects[frameworkPhase]?["files"] as? [String] ?? []).filter { !isVendorBuild($0, user: user) && !managedLinks.contains($0) }

            for file in linked where !files.contains(file) { files.append(file) }
            user.objects[frameworkPhase]?["files"] = files
            if !phases.contains(frameworkPhase) { phases.append(frameworkPhase) }
            let check = user.add("swiftpods:manifest:" + targetID, ["isa": "PBXShellScriptBuildPhase", "name": "[CP] Check Pods Manifest.lock", "buildActionMask": "2147483647", "runOnlyForDeploymentPostprocessing": "0", "files": [], "inputPaths": ["$(PODS_PODFILE_DIR_PATH)/Podfile.lock", "$(PODS_ROOT)/Manifest.lock"], "outputPaths": ["$(DERIVED_FILE_DIR)/swiftpods-manifest.txt"], "shellPath": "/bin/sh", "shellScript": "set -eu\ncmp \"${PODS_PODFILE_DIR_PATH}/Podfile.lock\" \"${PODS_ROOT}/Manifest.lock\"\nprintf OK > \"${SCRIPT_OUTPUT_FILE_0}\"\n"])
            if !phases.contains(check) { phases.insert(check, at: 0) }
            user.objects[targetID]?["buildPhases"] = phases
            let onDemand = try onDemandResources(roots: eligibleRoots, platform: platform["name"] ?? "ios")
            try NativeResources.apply(eligibleRoots.sorted().flatMap { staticResources[variantKey($0, platform["name"] ?? "ios")] ?? [] } + onDemand.files.keys.sorted(by: { $0.path < $1.path }) + bridgeSupportResource(target), target: targetID, graph: user, allowMissing: Set(bridgeSupportResource(target)))
            onDemand.tag(target: targetID, graph: user)
            copyResourceBundles(roots: eligibleRoots, platform: platform["name"] ?? "ios", target: targetID, user: user)
            phases = user.objects[targetID]?["buildPhases"] as? [String] ?? phases
            let embedID = NativePBX.identifier("swiftpods:embedphase:" + targetID)
            phases.removeAll { $0 == embedID }
            user.objects.removeValue(forKey: embedID)
            if !embedded.isEmpty {
                let embed = user.add("swiftpods:embedphase:" + targetID, ["isa": "PBXCopyFilesBuildPhase", "name": "[SwiftPods] Embed Frameworks", "buildActionMask": "2147483647", "runOnlyForDeploymentPostprocessing": "0", "files": embedded, "dstPath": "", "dstSubfolderSpec": "10"])
                if !phases.contains(embed) { phases.append(embed) }
            }
            user.objects[targetID]?["buildPhases"] = phases
            try conditionalEmbeds(conditionalRoots, configured: configuredRoots, platform: platform["name"] ?? "ios", target: targetID, user: user)
            NativeScriptPhase.apply(try NativeScriptPhase.parse(target["script_phases"]), target: targetID, graph: user)
            applyInputOutputOptions(targetID, graph: user)
            let list = user.objects[targetID]?["buildConfigurationList"] as? String
            for config in list.flatMap({ user.objects[$0]?["buildConfigurations"] as? [String] }) ?? [] {
                let recordKey = path.path + ":" + config
                let original = try NativeIntegrationSettings.restore(user.objects[config]?["buildSettings"] as? [String: Any] ?? [:], record: integrationSettings[recordKey] as? [String: Any] ?? [:])
                var settings = original
                settings.merge(onDemand.buildSettings) { _, new in new }
                for key in ["FRAMEWORK_SEARCH_PATHS", "LIBRARY_SEARCH_PATHS", "SWIFT_INCLUDE_PATHS"] {
                    var values = nativeStrings(settings[key]); if values.isEmpty { values = ["$(inherited)"] }
                    if !values.contains("$(BUILT_PRODUCTS_DIR)") { values.append("$(BUILT_PRODUCTS_DIR)") }
                    for directory in librarySearchDirectories(searchRoots, platform: platform["name"] ?? "ios") where !values.contains(directory) { values.append(directory) }
                    settings[key] = values
                }
                for (key, paths) in ["FRAMEWORK_SEARCH_PATHS": targetSDKs.filter { !$0.isXCFramework && $0.isFramework }.map { $0.url.deletingLastPathComponent().path }, "LIBRARY_SEARCH_PATHS": targetSDKs.filter { !$0.isXCFramework && !$0.isFramework }.map { $0.url.deletingLastPathComponent().path }, "HEADER_SEARCH_PATHS": targetSDKs.filter { !$0.isXCFramework }.compactMap { $0.slices.first?.headers?.path }] {
                    var values = nativeStrings(settings[key]); if values.isEmpty { values = ["$(inherited)"] }
                    for path in paths.map(NativeBuildSetting.path) where !values.contains(path) { values.append(path) }; settings[key] = values
                }
                var headerPaths = nativeStrings(settings["HEADER_SEARCH_PATHS"])
                if headerPaths.isEmpty { headerPaths = ["$(inherited)"] }
                let publicHeaders = headerSettings(searchRoots, platform: platform["name"] ?? "ios")
                for directory in publicHeaders where !headerPaths.contains(directory) { headerPaths.append(directory) }
                settings["HEADER_SEARCH_PATHS"] = headerPaths
                if !embedded.isEmpty || !conditionalRoots.isEmpty {
                    var runpaths = nativeStrings(settings["LD_RUNPATH_SEARCH_PATHS"])
                    if runpaths.isEmpty { runpaths = ["$(inherited)"] }
                    let frameworkPath = platform["name"] == "osx" ? "@executable_path/../Frameworks" : "@executable_path/Frameworks"
                    if !runpaths.contains(frameworkPath) { runpaths.append(frameworkPath) }
                    settings["LD_RUNPATH_SEARCH_PATHS"] = runpaths
                }
                if settings["ALWAYS_SEARCH_USER_PATHS"] == nil { settings["ALWAYS_SEARCH_USER_PATHS"] = "NO" }
                settings["PODS_ROOT"] = project.appendingPathComponent("Pods").path
            settings["PODS_PODFILE_DIR_PATH"] = project.path
                if original["GCC_PREPROCESSOR_DEFINITIONS"] == nil || nativeStrings(original["GCC_PREPROCESSOR_DEFINITIONS"]).contains(where: { $0.contains("$(inherited)") }) {
                    var definitions = nativeStrings(settings["GCC_PREPROCESSOR_DEFINITIONS"])
                    if definitions.isEmpty { definitions = ["$(inherited)"] }
                    if !definitions.contains("COCOAPODS=1") { definitions.append("COCOAPODS=1") }
                    settings["GCC_PREPROCESSOR_DEFINITIONS"] = definitions
                }
                let configuration = user.objects[config]?["name"] as? String ?? "Debug"
                let enabled = configuredRoots[configuration] ?? eligibleRoots
                let excludedAssets = try consumerAssetExclusions(eligible: eligibleRoots, enabled: enabled, platform: platform["name"] ?? "ios")
                if !excludedAssets.isEmpty {
                    var exclusions = nativeStrings(settings["EXCLUDED_SOURCE_FILE_NAMES"])
                    if exclusions.isEmpty { exclusions = ["$(inherited)"] }
                    for asset in excludedAssets {
                        let value = NativeBuildSetting.quoted(asset)
                        if !exclusions.contains(value) { exclusions.append(value) }
                    }
                    settings["EXCLUDED_SOURCE_FILE_NAMES"] = exclusions
                }
                let conditionalProducts = products.filter { productRoots[$0] != nil && matchesProduct($0, roots: conditionalRoots.intersection(enabled), platform: platform["name"] ?? "ios") }
                var flags: [String] = []
                for product in conditionalProducts {
                    let path = graph.objects[product]?["path"] as? String ?? ""
                    if path.hasSuffix(".framework") { flags += ["-framework", "\"" + String(path.dropLast(10)) + "\""] }
                    else { flags.append("-l\"" + String(path.dropFirst(3).dropLast(2)) + "\"") }
                }
                var linker = nativeStrings(settings["OTHER_LDFLAGS"]).filter { $0 != "$(SWIFTPODS_CONFIG_LDFLAGS)" }
                if manifest["set_arc_compatibility_flag"] as? Bool == true, enabled.contains(where: { root in
                    guard let spec = resolution.specs[root], let variant = variantPlan?.variants[variantKey(root, platform["name"] ?? "ios")] else { return false }
                    return (try? NativeVariantPlan.attributes(spec, names: variant.names, platform: platform["name"] ?? "ios")["requires_arc"] as? Bool) != false
                }), !linker.contains("-fobjc-arc") {
                    if linker.isEmpty { linker = ["$(inherited)"] }; linker.append("-fobjc-arc")
                }
                if !flags.isEmpty { if linker.isEmpty { linker = ["$(inherited)"] }; linker.append("$(SWIFTPODS_CONFIG_LDFLAGS)"); settings["SWIFTPODS_CONFIG_LDFLAGS"] = flags }
                else { settings.removeValue(forKey: "SWIFTPODS_CONFIG_LDFLAGS") }
                if !linker.isEmpty { settings["OTHER_LDFLAGS"] = linker }
                else { settings.removeValue(forKey: "OTHER_LDFLAGS") }
                for root in enabled.sorted() {
                    if let spec = resolution.specs[root], let variant = variantPlan?.variants[variantKey(root, platform["name"] ?? "ios")] {
                        let attributes = try NativeVariantPlan.attributes(spec, names: variant.names, platform: platform["name"] ?? "ios")
                        for (key, value) in NativeSpec.xcconfig(attributes, key: "user_target_xcconfig") {
                            if settings[key] == nil { settings[key] = value }
                            else if nativeStrings(original[key]).contains(where: { $0.contains("$(inherited)") }) {
                                settings[key] = (nativeStrings(settings[key]) + nativeStrings(value).filter { $0 != "$(inherited)" }).joined(separator: " ")
                            }
                        }
                    }
                }
                if !searchRoots.isEmpty { settings["SWIFT_INCLUDE_PATHS"] = nativeStrings(settings["SWIFT_INCLUDE_PATHS"]) + publicHeaders }
                settings = try consumerConfiguration(target, configuration: config, user: user, recordKey: recordKey, original: original, settings: settings)
                user.objects[config]?["buildSettings"] = settings
                integrationSettings[recordKey] = try NativeIntegrationSettings.record(before: original, after: settings)
            }
            try addPackages(target["packages"] as? [[String: Any]] ?? [], targetID: targetID, user: user)
        }
        var attributeRecords: [String: [String: Any]] = [:]
        for user in userProjects.values {
            if let root = user.root["rootObject"] as? String {
                attributeRecords[user.url.path] = try NativeIntegrationSettings.record(before: originalAttributes[user.url.path] ?? [:], after: user.objects[root]?["attributes"] as? [String: Any] ?? [:])
            }
        }
        integrationSettings["_project_attributes"] = attributeRecords
        var written: [URL] = []
        for user in userProjects.values { pruneSourceObjects(user); pruneVendorObjects(user); try user.save(); written.append(user.url) }
        guard let workspace = workspacePath() else { throw Diagnostic("SP-WORKSPACE", stage: "integrate", "No selected consumer workspace") }
        let userPaths = userProjects.values.map { $0.url.deletingLastPathComponent() }
        let podPaths = [project.appendingPathComponent("Pods/Pods.xcodeproj")] + (multipleProjects ? Set(targetOwners.values.map { projectForPod($0) }).sorted { $0.path < $1.path } : [])
        let workspaceRoot = workspace.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path
        func reference(_ path: URL) -> String {
            let value = path.standardizedFileURL.path
            return value.hasPrefix(workspaceRoot + "/") ? "group:" + String(value.dropFirst(workspaceRoot.count + 1)) : "absolute:" + value
        }
        let podReferences = Set(podPaths.map(reference))
        var workspaces = integrationSettings["_workspaces"] as? [String: [String]] ?? [:]
        let previous = workspaces[workspace.path] ?? []
        let owned = try NativeWorkspace.update(workspace, references: (userPaths + podPaths).map(reference), previous: previous, expected: workspaceFingerprints[workspace.path])
        workspaceFingerprints[workspace.path] = try FileFingerprint.tree(workspace)
        workspaces[workspace.path] = owned.filter(podReferences.contains)
        integrationSettings["_workspaces"] = workspaces
        integrationSettings["_products"] = previousProducts.union(products).sorted()
        try FileManager.default.createDirectory(at: integrationSettingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try jsonData(integrationSettings).writeIfChanged(to: integrationSettingsURL, options: .atomic)
        written += [workspace, integrationSettingsURL]
        return written
    }
    private func isVendorBuild(_ id: String, user: NativePBX) -> Bool {
        guard let reference = user.objects[id]?["fileRef"] as? String, let path = user.objects[reference]?["path"] as? String else { return false }
        let key = "swiftpods:vendor:" + path
        return reference == NativePBX.identifier(key) && [NativePBX.identifier(key + ":link"), NativePBX.identifier(key + ":embed")].contains(id)
    }
    private func pruneSourceObjects(_ user: NativePBX) {
        let candidates = previousProducts.union(products)
        let builds = Set(candidates.flatMap { [NativePBX.identifier("swiftpods:build:" + $0), NativePBX.identifier("swiftpods:embed:" + $0)] })
        let usedBuilds = Set(user.objects.values.flatMap { $0["files"] as? [String] ?? [] })
        for id in builds.subtracting(usedBuilds) { user.objects.removeValue(forKey: id) }
        let usedReferences = Set(user.objects.values.compactMap { $0["fileRef"] as? String })
        for id in candidates.map({ NativePBX.identifier("swiftpods:product:" + $0) }) where !usedReferences.contains(id) {
            user.objects.removeValue(forKey: id)
            for group in Array(user.objects.keys) {
                if let children = user.objects[group]?["children"] as? [String] { user.objects[group]?["children"] = children.filter { $0 != id } }
            }
        }
    }
    private func pruneVendorObjects(_ user: NativePBX) {
        let usedBuilds = Set(user.objects.values.flatMap { $0["files"] as? [String] ?? [] })
        for id in Array(user.objects.keys) where isVendorBuild(id, user: user) && !usedBuilds.contains(id) { user.objects.removeValue(forKey: id) }
        let usedReferences = Set(user.objects.values.compactMap { $0["fileRef"] as? String })
        for (id, object) in user.objects {
            guard object["isa"] as? String == "PBXFileReference", let path = object["path"] as? String,
                  id == NativePBX.identifier("swiftpods:vendor:" + path), !usedReferences.contains(id) else { continue }
            user.objects.removeValue(forKey: id)
            for group in Array(user.objects.keys) {
                if let children = user.objects[group]?["children"] as? [String], children.contains(id) { user.objects[group]?["children"] = children.filter { $0 != id } }
            }
        }
    }
    private func addPackages(_ packages: [[String: Any]], targetID: String, user: NativePBX) throws {
        guard let rootID = user.root["rootObject"] as? String else { return }
        for package in packages {
            guard let url = package["git"] as? String else { throw Diagnostic("SP-SPM-URL", stage: "integrate", "Swift packages require :git") }
            let keys = ["exact", "from", "range", "branch", "revision"].filter { package[$0] != nil }
            guard keys.count == 1 else { throw Diagnostic("SP-SPM-REQUIREMENT", stage: "integrate", "Specify one Swift package requirement") }
            var requirement: [String: Any]
            switch keys[0] {
            case "exact": requirement = ["kind": "exactVersion", "version": package["exact"]!]
            case "from": requirement = ["kind": "upToNextMajorVersion", "minimumVersion": package["from"]!]
            case "branch": requirement = ["kind": "branch", "branch": package["branch"]!]
            case "revision": requirement = ["kind": "revision", "revision": package["revision"]!]
            default:
                guard let range = package["range"] as? [String], range.count == 2 else { throw Diagnostic("SP-SPM-REQUIREMENT", stage: "integrate", "Swift package range needs two versions") }
                requirement = ["kind": "versionRange", "minimumVersion": range[0], "maximumVersion": range[1]]
            }
            let reference: String
            if let existing = user.objects.first(where: { $0.value["isa"] as? String == "XCRemoteSwiftPackageReference" && $0.value["repositoryURL"] as? String == url }) {
                guard try jsonData(existing.value["requirement"] ?? [:]) == jsonData(requirement) else { throw Diagnostic("SP-SPM-CONFLICT", stage: "integrate", "Existing Swift package uses a different requirement", file: url) }
                reference = existing.key
            } else { reference = user.add("swiftpods:package:" + url, ["isa": "XCRemoteSwiftPackageReference", "repositoryURL": url, "requirement": requirement]) }
            var refs = user.objects[rootID]?["packageReferences"] as? [String] ?? []
            if !refs.contains(reference) { refs.append(reference) }; user.objects[rootID]?["packageReferences"] = refs
            for product in nativeStrings(package["products"]) {
                guard !resolution.specs.values.contains(where: { ($0.data["module_name"] as? String ?? $0.name) == product }) else { throw Diagnostic("SP-DUPLICATE-SDK", stage: "integrate", "Module \(product) is declared as both pod and Swift package") }
                var products = user.objects[targetID]?["packageProductDependencies"] as? [String] ?? []
                let id = products.first(where: { user.objects[$0]?["package"] as? String == reference && user.objects[$0]?["productName"] as? String == product }) ?? user.add("swiftpods:packageproduct:\(reference):\(product)", ["isa": "XCSwiftPackageProductDependency", "package": reference, "productName": product])
                if !products.contains(id) { products.append(id) }; user.objects[targetID]?["packageProductDependencies"] = products
                if let phase = (user.objects[targetID]?["buildPhases"] as? [String])?.first(where: { user.objects[$0]?["isa"] as? String == "PBXFrameworksBuildPhase" }) {
                    var files = user.objects[phase]?["files"] as? [String] ?? []
                    let build = files.first(where: { user.objects[$0]?["productRef"] as? String == id }) ?? user.add("swiftpods:packagebuild:" + id, ["isa": "PBXBuildFile", "productRef": id])
                    if !files.contains(build) { files.append(build) }; user.objects[phase]?["files"] = files
                }
            }
        }
    }
}
