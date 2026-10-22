import Foundation

/// Resolve once with Xcode, then keep an immutable checkout for exported compiler interfaces.
/// The application still builds and links its package products through Xcode.
final class NativeSwiftPackageGraph {
    struct Package {
        let identity: String
        let location: String
        let directory: URL
        var mutable = false
    }

    let directory: URL
    let environment: [String: String]
    let packages: [Package]
    let artifacts: [[String: Any]]
    let moduleMaps: NativeSwiftPackageModuleMaps
    private var manifests: [String: [String: Any]] = [:]
    private var binaries: [URL: NativeVendorSDK] = [:]
    private var pkgConfigs: [String: [String]] = [:]
    private let loadManifest: ((Package) throws -> [String: Any])?

    init(directory: URL, environment: [String: String], moduleMaps: NativeSwiftPackageModuleMaps,
        loadManifest: ((Package) throws -> [String: Any])? = nil) throws {
        self.directory = directory
        self.environment = environment
        self.loadManifest = loadManifest
        self.moduleMaps = moduleMaps
        let state = try readObject(directory.appendingPathComponent("workspace-state.json"))
        guard let object = state["object"] as? [String: Any],
            let entries = object["dependencies"] as? [[String: Any]]
        else {
            throw Diagnostic("SP-SPM-STATE", stage: "integrate", "Unsupported SwiftPM workspace state", file: directory.path)
        }
        packages = try entries.map { entry in
            guard let reference = entry["packageRef"] as? [String: Any],
                let identity = reference["identity"] as? String, let location = reference["location"] as? String,
                let state = entry["state"] as? [String: Any], let kind = state["name"] as? String
            else { throw Diagnostic("SP-SPM-STATE", stage: "integrate", "Invalid resolved package", file: directory.path) }
            let root: URL
            if kind == "sourceControlCheckout", let subpath = entry["subpath"] as? String,
                !subpath.hasPrefix("/"), !(subpath as NSString).pathComponents.contains("..")
            {
                root = directory.appendingPathComponent("checkouts").appendingPathComponent(subpath)
            } else if kind == "fileSystem" || kind == "edited" {
                root = URL(fileURLWithPath: state["path"] as? String ?? location)
            } else {
                throw Diagnostic("SP-SPM-STATE", stage: "integrate", "Unsupported resolved package state: " + kind, file: location)
            }
            return Package(identity: identity, location: location, directory: root.standardizedFileURL,
                mutable: kind != "sourceControlCheckout")
        }
        artifacts = object["artifacts"] as? [[String: Any]] ?? []
    }

    static func location(_ raw: String) -> String {
        let value = URL(string: raw).flatMap { $0.isFileURL ? $0.path : nil } ?? raw
        return value.hasSuffix(".git") ? String(value.dropLast(4)) : value
    }

    static func scheme(target: String, name: String, project: URL, workspace: URL) -> String {
        for container in [project, workspace] {
            let files = (FileManager.default.enumerator(at: container, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
                .filter { $0.pathExtension == "xcscheme" }.sorted { $0.path < $1.path }
            for file in files {
                guard let data = try? Data(contentsOf: file), let document = try? XMLDocument(data: data),
                    let entries = try? document.nodes(forXPath: "//BuildActionEntry/BuildableReference")
                else { continue }
                for case let entry as XMLElement in entries where entry.attribute(forName: "BlueprintIdentifier")?.stringValue == target {
                    guard let reference = entry.attribute(forName: "ReferencedContainer")?.stringValue,
                        reference.hasPrefix("container:")
                    else { continue }
                    let path = URL(fileURLWithPath: String(reference.dropFirst("container:".count)),
                        relativeTo: container.deletingLastPathComponent()).standardizedFileURL
                    if path == project.standardizedFileURL { return file.deletingPathExtension().lastPathComponent }
                }
            }
        }
        return name // Xcode's automatically generated target scheme.
    }

    func package(_ location: String) throws -> Package {
        let matches = packages.filter { Self.location($0.location) == Self.location(location) }
        guard matches.count == 1, let package = matches.first else {
            throw Diagnostic("SP-SPM-PACKAGE", stage: "integrate", "Resolved package not found or ambiguous", file: location)
        }
        return package
    }

    func manifest(_ package: Package) throws -> [String: Any] {
        if let cached = manifests[package.directory.path] { return cached }
        if let loadManifest {
            let value = try loadManifest(package)
            manifests[package.directory.path] = value
            return value
        }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("swiftpods-spm-manifest-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        var host = environment
        host.removeValue(forKey: "SDKROOT")
        let result = try ToolProcess.run(
            "/usr/bin/xcrun", ["swift", "package", "--package-path", package.directory.path,
                "--scratch-path", temporary.appendingPathComponent("build").path,
                "--cache-path", temporary.appendingPathComponent("cache").path,
                "--config-path", temporary.appendingPathComponent("configuration").path,
                "--security-path", temporary.appendingPathComponent("security").path, "dump-package"],
            environment: host)
        guard result.status == 0, !String(decoding: result.error, as: UTF8.self).contains("warning:"),
            let value = try NativeJSON.decode(result.output) as? [String: Any] else {
            throw Diagnostic("SP-SPM-MANIFEST", stage: "integrate",
                "Cannot evaluate resolved package manifest: " + String(decoding: result.error, as: UTF8.self),
                file: package.directory.path)
        }
        manifests[package.directory.path] = value
        return value
    }

    func pkgConfig(_ name: String, package: Package) throws -> [String] {
        let key = package.directory.path + ":" + name
        if let cached = pkgConfigs[key] { return cached }
        let flags = try NativeSwiftPackagePkgConfig.read(name, directory: package.directory, environment: environment)
        pkgConfigs[key] = flags
        return flags
    }

    func dependencies(_ package: Package) throws -> [(name: String?, package: Package)] {
        try (manifest(package)["dependencies"] as? [[String: Any]] ?? []).compactMap { declaration in
            if let source = (declaration["sourceControl"] as? [[String: Any]])?.first,
                let identity = source["identity"] as? String
            {
                // SwiftPM may prune dependencies of products not selected by this workspace.
                guard let resolved = packages.first(where: { $0.identity == identity }) else { return nil }
                return (source["nameForTargetDependencyResolutionOnly"] as? String, resolved)
            }
            if let source = (declaration["fileSystem"] as? [[String: Any]])?.first,
                let path = source["path"] as? String
            {
                let root = URL(fileURLWithPath: path, relativeTo: package.directory).standardizedFileURL
                return (source["nameForTargetDependencyResolutionOnly"] as? String,
                    Package(identity: source["identity"] as? String ?? root.lastPathComponent.lowercased(), location: root.path, directory: root, mutable: true))
            }
            throw Diagnostic("SP-SPM-DEPENDENCY", stage: "integrate", "Unsupported package dependency", file: package.directory.path)
        }
    }

    func targetDirectory(_ target: [String: Any], package: Package) throws -> URL {
        if let path = target["path"] as? String {
            return URL(fileURLWithPath: path, relativeTo: package.directory).standardizedFileURL
        }
        let kind = target["type"] as? String ?? "regular"
        let name = target["name"] as? String ?? ""
        let bases = kind == "test" ? ["Tests"] : ["Sources", "Source", "src", "srcs"]
        let named = bases.map { package.directory.appendingPathComponent($0 + "/" + name) }
        if let path = named.first(where: { FileManager.default.fileExists(atPath: $0.path) }) { return path }
        // Modern system targets use Sources/<name>; legacy packages put their
        // module map at the package root. Explicit paths still take precedence.
        if kind == "system" { return package.directory }
        let targets = try manifest(package)["targets"] as? [[String: Any]] ?? []
        let sources = targets.filter { !["test", "binary", "plugin", "system"].contains($0["type"] as? String ?? "regular") }
        if kind != "test", sources.count == 1,
            let path = bases.map({ package.directory.appendingPathComponent($0) }).first(where: { FileManager.default.fileExists(atPath: $0.path) })
        { return path }
        throw Diagnostic("SP-SPM-LAYOUT", stage: "integrate", "Resolved package target directory is missing", file: name)
    }

    func mutableManifestInputs() throws -> [String: String] {
        try Dictionary(uniqueKeysWithValues: packages.filter(\.mutable).map { package in
            let manifests = try FileManager.default.contentsOfDirectory(at: package.directory, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("Package") && $0.pathExtension == "swift" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            let fingerprints = try manifests.map { [$0.lastPathComponent, try FileFingerprint.file($0)] }
            return (package.directory.path, digest(try jsonData(fingerprints)))
        })
    }

    func resolutionFingerprint() throws -> String {
        func normalized(_ value: Any) -> Any {
            if let text = value as? String { return text.replacingOccurrences(of: directory.path, with: "@checkout") }
            if let values = value as? [Any] { return values.map(normalized) }
            if let values = value as? [String: Any] {
                var result = values.mapValues(normalized)
                if var reference = result["packageRef"] as? [String: Any] {
                    // Xcode can alternate between a repository basename and
                    // the manifest's display name for the same package.
                    reference.removeValue(forKey: "name")
                    result["packageRef"] = reference
                }
                return result
            }
            return value
        }
        var state = try readObject(directory.appendingPathComponent("workspace-state.json")).mapValues(normalized)
        var object = state["object"] as? [String: Any] ?? [:]
        for key in ["dependencies", "artifacts", "prebuilts"] {
            if let entries = object[key] as? [Any] {
                object[key] = entries.sorted { NativePBX.serialize($0) < NativePBX.serialize($1) }
            }
        }
        state["object"] = object
        return digest(try jsonData(state))
    }

    func binary(_ target: [String: Any], package: Package) throws -> NativeVendorSDK {
        let name = target["name"] as? String ?? ""
        let artifact = artifacts.first {
            ($0["packageRef"] as? [String: Any])?["identity"] as? String == package.identity && $0["targetName"] as? String == name
        }
        let path: URL
        if let raw = artifact?["path"] as? String {
            path = URL(fileURLWithPath: raw, relativeTo: directory).standardizedFileURL
        } else if let raw = target["path"] as? String {
            path = URL(fileURLWithPath: raw, relativeTo: package.directory).standardizedFileURL
        } else {
            throw Diagnostic("SP-SPM-ARTIFACT", stage: "integrate", "Resolved binary artifact is missing", file: name)
        }
        if let cached = binaries[path] { return cached }
        let sdk = try NativeVendorSDK(path)
        binaries[path] = sdk
        return sdk
    }
}

extension NativeXcode {
    func resolveSwiftPackageCompilerGraph() throws -> NativeSwiftPackageGraph? {
        let targets = manifest["targets"] as? [[String: Any]] ?? []
        guard try targets.contains(where: {
            try NativeSwiftPackageDeclaration.list($0["packages"]).contains { !$0.link && !$0.products.isEmpty }
        }) else { return nil }
        let storage = ProjectStorage(project: project)
        try storage.validate()
        let root = storage.directory.appendingPathComponent("swift-packages")
        if let attributes = try? FileManager.default.attributesOfItem(atPath: root.path),
            attributes[.type] as? FileAttributeType != .typeDirectory
        {
            throw Diagnostic("SP-SPM-STATE", stage: "integrate", "Package cache must be a directory without symlinks", file: root.path)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard let workspace = workspacePath()?.deletingLastPathComponent() else { return nil }
        let pins = workspace.appendingPathComponent("xcshareddata/swiftpm/Package.resolved")
        let toolchain = try ToolProcess.run("/usr/bin/xcrun", ["swift", "--version"], environment: packageEnvironment)
        guard toolchain.status == 0 else {
            throw Diagnostic("SP-SPM-TOOLCHAIN", stage: "integrate", "Cannot identify the selected Swift toolchain")
        }
        func signature() throws -> String {
            var references: [[String: Any]] = []
            for path in userProjects.keys.sorted() {
                let user = userProjects[path]!
                let objects = user.objects.values.filter {
                    ["XCRemoteSwiftPackageReference", "XCLocalSwiftPackageReference"].contains($0["isa"] as? String ?? "")
                }.sorted { NativePBX.serialize($0) < NativePBX.serialize($1) }
                let products = user.objects.values.filter { $0["isa"] as? String == "XCSwiftPackageProductDependency" }
                    .sorted { NativePBX.serialize($0) < NativePBX.serialize($1) }
                references.append(["project": path, "references": objects, "products": products])
            }
            return try digest(jsonData(["references": references,
                "pins": (try? Data(contentsOf: pins)).map { digest($0) } ?? "",
                "developer": packageEnvironment["DEVELOPER_DIR"] ?? "", "toolchain": digest(toolchain.output)]))
        }
        let receipt = root.appendingPathComponent("active.json")
        let currentSignature = try signature()
        if !updateSwiftPackages && !cleanSwiftPackages, let previous = try? readObject(receipt),
            previous["signature"] as? String == currentSignature, let relative = previous["directory"] as? String,
            relative.range(of: #"\Acheckout-[A-Fa-f0-9-]+\z"#, options: .regularExpression) != nil,
            FileManager.default.fileExists(atPath: root.appendingPathComponent(relative + "/workspace-state.json").path)
        {
            let graph = try NativeSwiftPackageGraph(directory: root.appendingPathComponent(relative), environment: packageEnvironment,
                moduleMaps: packageModuleMaps)
            if try graph.mutableManifestInputs() == (previous["mutable_manifests"] as? [String: String] ?? [:]) { return graph }
        }
        guard packageEnvironment["SWIFTPODS_OFFLINE"] != "1" else {
            throw Diagnostic("SP-SPM-OFFLINE", stage: "integrate", "No matching resolved compiler interfaces in the SwiftPods cache")
        }
        let cache = root.appendingPathComponent("checkout-" + UUID().uuidString)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("swiftpods-spm-resolve-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        var accepted = false
        defer { if !accepted { try? FileManager.default.removeItem(at: cache) } }
        try ProjectState(directory: project).registerProject(pins)
        let owner = targets.first { target in
            (try? NativeSwiftPackageDeclaration.list(target["packages"]).contains { $0.link && !$0.products.isEmpty }) == true
        } ?? targets[0]
        let ownerProject = try projectPath(owner)
        let ownerID = userProjects[ownerProject.path]?.objects.first {
            $0.value["isa"] as? String == "PBXNativeTarget" && $0.value["name"] as? String == owner["name"] as? String
        }?.key ?? ""
        let scheme = NativeSwiftPackageGraph.scheme(target: ownerID, name: owner["name"] as? String ?? "",
            project: ownerProject.deletingLastPathComponent(), workspace: workspace)
        let result = try ToolProcess.run("/usr/bin/xcrun", ["xcodebuild", "-resolvePackageDependencies",
            "-workspace", workspace.path, "-scheme", scheme,
            "-clonedSourcePackagesDirPath", cache.path, "-derivedDataPath", temporary.appendingPathComponent("Data").path],
            directory: project, environment: packageEnvironment)
        recordPackageWrite?(pins)
        guard result.status == 0 else {
            throw Diagnostic("SP-SPM-RESOLVE", stage: "integrate",
                "Xcode could not resolve Swift package compiler interfaces:\n"
                    + String(decoding: result.output + result.error, as: UTF8.self), file: workspace.path)
        }
        let graph = try NativeSwiftPackageGraph(directory: cache, environment: packageEnvironment, moduleMaps: packageModuleMaps)
        if !cleanSwiftPackages, let previous = try? readObject(receipt), let relative = previous["directory"] as? String,
            relative.range(of: #"\Acheckout-[A-Fa-f0-9-]+\z"#, options: .regularExpression) != nil,
            let old = try? NativeSwiftPackageGraph(directory: root.appendingPathComponent(relative), environment: packageEnvironment, moduleMaps: packageModuleMaps),
            try old.resolutionFingerprint() == graph.resolutionFingerprint()
        {
            // Product selection can change without changing any resolved revision.
            // Keep existing interface paths and discard the redundant checkout.
            try jsonData(["signature": signature(), "directory": relative,
                "mutable_manifests": old.mutableManifestInputs()]).writeIfChanged(to: receipt, options: .atomic)
            return old
        }
        try jsonData(["signature": signature(), "directory": cache.lastPathComponent,
            "mutable_manifests": graph.mutableManifestInputs()]).writeIfChanged(to: receipt, options: .atomic)
        accepted = true
        return graph
    }
}
