import Foundation

enum NativeDeintegrator {
    /// Restore only managed integration; a target subset is used on reinstall.
    static func restore(_ user: NativePBX, settings: [String: Any], products: Set<String>, targets: Set<String>? = nil)
        throws
    {
        let path = user.url.path
        if targets == nil, let root = user.root["rootObject"] as? String {
            let records = settings["_project_attributes"] as? [String: [String: Any]] ?? [:]
            let attributes = user.objects[root]?["attributes"] as? [String: Any] ?? [:]
            let restored = try NativeIntegrationSettings.restore(attributes, record: records[path] ?? [:])
            user.objects[root]?["attributes"] = restored
        }
        var removable = Set<String>()
        let podRefs = Set(products.map { NativePBX.identifier("swiftpods:product:" + $0) })
        let podBuilds = Set(
            products.flatMap {
                [NativePBX.identifier("swiftpods:build:" + $0), NativePBX.identifier("swiftpods:embed:" + $0)]
            })
        removable.formUnion(podRefs)
        removable.formUnion(podBuilds)
        removable.insert(NativePBX.identifier("swiftpods:pods-project"))
        for id in user.objects.keys {
            if let key = user.ownedFileKey(id, prefix: "swiftpods:vendor:") {
                removable.formUnion([
                    id, NativePBX.identifier(key + ":link"), NativePBX.identifier(key + ":embed"),
                ])
            }
        }
        var selectedPhases = Set<String>()
        var selectedConfigurations = Set<String>()
        for (id, item) in user.objects
        where item["isa"] as? String == "PBXNativeTarget" && (targets == nil || targets!.contains(id)) {
            selectedPhases.formUnion(item["buildPhases"] as? [String] ?? [])
            let list = item["buildConfigurationList"] as? String ?? ""
            selectedConfigurations.formUnion(user.objects[list]?["buildConfigurations"] as? [String] ?? [])
            try NativeResources.apply([], target: id, graph: user)
            let prefix = "swiftpods:resources:" + id + ":"
            for (reference, value) in user.objects {
                if user.ownedFileKey(reference, prefix: prefix + "file:") != nil {
                    removable.formUnion([reference, NativePBX.identifier(prefix + "build:" + reference)])
                }
                if let name = value["name"] as? String,
                    reference == NativePBX.identifier(prefix + "variant:" + id + ":" + name)
                {
                    removable.formUnion([reference, NativePBX.identifier(prefix + "build:" + reference)])
                }
            }
            let phaseIDs = Set(
                ["manifest", "resources", "embedphase", "conditional-embed"].map {
                    NativePBX.identifier("swiftpods:" + $0 + ":" + id)
                })
            removable.formUnion(products.map { NativePBX.identifier("swiftpods:bundle-build:" + id + ":" + $0) })
            let phases = (user.objects[id]?["buildPhases"] as? [String] ?? []).filter { phase in
                let label = user.objects[phase]?["name"] as? String ?? ""
                let script =
                    label.hasPrefix(NativeScriptPhase.prefix)
                    && phase
                        == NativePBX.identifier(
                            "script:" + id + ":" + label.dropFirst(NativeScriptPhase.prefix.count))
                if phaseIDs.contains(phase) || script {
                    removable.insert(phase)
                    return false
                }
                return true
            }
            user.objects[id]?["buildPhases"] = phases
            let dependency = NativePBX.identifier("swiftpods:aggregate-dependency:" + id)
            let proxy = NativePBX.identifier("swiftpods:aggregate-proxy:" + id)
            removable.formUnion([dependency, proxy])
            let variants = Set(
                products.map { NativePBX.identifier("swiftpods:variant-dependency:" + id + ":" + $0) })
            for variant in variants {
                removable.insert(variant)
                if let proxy = user.objects[variant]?["targetProxy"] as? String {
                    removable.insert(proxy)
                    if let portal = user.objects[proxy]?["containerPortal"] as? String { removable.insert(portal) }
                }
            }
            user.objects[id]?["dependencies"] = (item["dependencies"] as? [String] ?? []).filter {
                $0 != dependency && !variants.contains($0)
            }
        }
        for id in Array(user.objects.keys) {
            if targets == nil, user.objects[id]?["isa"] as? String == "PBXFileReference",
                let path = user.objects[id]?["path"] as? String,
                id == NativePBX.identifier("swiftpods:xcconfig:" + path)
            {
                removable.insert(id)
            }
            if targets == nil || selectedPhases.contains(id), let files = user.objects[id]?["files"] as? [String] {
                user.objects[id]?["files"] = files.filter { !removable.contains($0) }
            }
            if user.objects[id]?["isa"] as? String == "XCBuildConfiguration",
                targets == nil || selectedConfigurations.contains(id)
            {
                if let reference = (settings["_support_configurations"] as? [String: String])?[path + ":" + id] {
                    removable.insert(reference)
                }
                if let reference = (settings["_base_configurations"] as? [String: String])?[path + ":" + id],
                    user.objects[id]?["baseConfigurationReference"] as? String == reference
                {
                    user.objects[id]?.removeValue(forKey: "baseConfigurationReference")
                    removable.insert(reference)
                }
                let current = user.objects[id]?["buildSettings"] as? [String: Any] ?? [:]
                user.objects[id]?["buildSettings"] = try NativeIntegrationSettings.restore(
                    current, record: settings[path + ":" + id] as? [String: Any] ?? [:])
            }
        }
        user.removeUnreferencedObjects(removable)
    }
    static func run(_ project: URL) throws -> [URL] {
        let archive = project.appendingPathComponent("Pods/Target Support Files/SwiftPods-Integration.json")
        guard FileManager.default.fileExists(atPath: archive.path) else { return [] }
        let settings = try NativeIntegrationLocation.relocated(readObject(archive), to: project)
        let packageRecords = settings["_swift_packages"] as? [String: [String: Any]] ?? [:]
        let paths = NativeIntegrationSettings.projectPaths(settings)
        var projects: [NativePBX] = []
        for path in paths {
            let file = URL(fileURLWithPath: path).standardizedFileURL
            let canonical = file.resolvingSymlinksInPath()
            guard canonical.lastPathComponent == "project.pbxproj",
                canonical.deletingLastPathComponent().pathExtension == "xcodeproj"
            else { throw Diagnostic("SP-DEINTEGRATE-PATH", stage: "integrate", "Invalid owned project", file: path) }
            if FileManager.default.fileExists(atPath: file.path) {
                try ProjectState(directory: project).registerProject(file)
                projects.append(try NativePBX(file, existing: true))
            }
        }
        let podsPath = project.appendingPathComponent("Pods/Pods.xcodeproj/project.pbxproj")
        let pods = try FileManager.default.fileExists(atPath: podsPath.path) ? NativePBX(podsPath, existing: true) : nil
        let products = Set(pods?.objects.values.compactMap { $0["productReference"] as? String } ?? []).union(
            settings["_products"] as? [String] ?? [])
        var workspaces: [NativeWorkspace.Update] = []
        for (raw, owned) in (settings["_workspaces"] as? [String: [String]] ?? [:]).sorted(by: { $0.key < $1.key }) {
            let workspace = URL(fileURLWithPath: raw).standardizedFileURL.resolvingSymlinksInPath()
            guard workspace.lastPathComponent == "contents.xcworkspacedata",
                workspace.deletingLastPathComponent().pathExtension == "xcworkspace"
            else { throw Diagnostic("SP-WORKSPACE", stage: "integrate", "Invalid owned workspace", file: raw) }
            try ProjectState(directory: project).registerProject(workspace)
            if FileManager.default.fileExists(atPath: workspace.path) {
                workspaces.append(try NativeWorkspace.prepare(workspace, references: [], previous: owned))
            }
        }
        var prepared: [NativePBX] = []
        // Validate and restore every existing graph before the first save.
        for user in projects.sorted(by: { $0.url.path < $1.url.path }) {
            let before = try jsonData(user.objects)
            let packages = NativeSwiftPackageIntegrator()
            try packages.prepare(user, record: packageRecords[user.url.path])
            _ = packages.finish(user)
            try restore(user, settings: settings, products: products)
            if try jsonData(user.objects) != before {
                prepared.append(user)
            }
        }
        var changed: [URL] = []
        for user in prepared {
            try user.save()
            changed.append(user.url)
        }
        for update in workspaces {
            let before = try Data(contentsOf: update.path)
            try update.save()
            if update.data != before { changed.append(update.path) }
        }
        try FileManager.default.removeItem(at: archive)
        changed.append(archive)
        let state = project.appendingPathComponent(".swiftpods/installation.json")
        if FileManager.default.fileExists(atPath: state.path) {
            try FileManager.default.removeItem(at: state)
            changed.append(state)
        }
        return changed
    }
}
