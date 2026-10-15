import Foundation

enum NativeDeintegrator {
    static func run(_ project: URL) throws -> [URL] {
        let archive = project.appendingPathComponent("Pods/Target Support Files/SwiftPods-Integration.json")
        guard FileManager.default.fileExists(atPath: archive.path) else { return [] }
        let settings = try readObject(archive)
        let paths = Set(
            settings.keys.compactMap { key -> String? in
                guard let separator = key.range(of: ":", options: .backwards) else { return nil }
                return String(key[..<separator.lowerBound])
            })
        for path in paths {
            let file = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
            guard file.lastPathComponent == "project.pbxproj",
                file.deletingLastPathComponent().pathExtension == "xcodeproj"
            else { throw Diagnostic("SP-DEINTEGRATE-PATH", stage: "integrate", "Invalid owned project", file: path) }
            try ProjectState(directory: project).registerProject(file)
        }
        let pods = try NativePBX(project.appendingPathComponent("Pods/Pods.xcodeproj/project.pbxproj"), existing: true)
        let products = Set(pods.objects.values.compactMap { $0["productReference"] as? String }).union(
            settings["_products"] as? [String] ?? [])
        var changed: [URL] = []
        for path in paths.sorted() {
            let user = try NativePBX(URL(fileURLWithPath: path), existing: true)
            let before = try jsonData(user.objects)
            if let root = user.root["rootObject"] as? String {
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
            for (id, item) in user.objects where item["isa"] as? String == "PBXFileReference" {
                if let path = item["path"] as? String, id == NativePBX.identifier("swiftpods:vendor:" + path) {
                    removable.formUnion([
                        id, NativePBX.identifier("swiftpods:vendor:" + path + ":link"),
                        NativePBX.identifier("swiftpods:vendor:" + path + ":embed"),
                    ])
                }
            }
            for (id, item) in user.objects where item["isa"] as? String == "PBXNativeTarget" {
                try NativeResources.apply([], target: id, graph: user)
                let prefix = "swiftpods:resources:" + id + ":"
                for (reference, value) in user.objects {
                    if let path = value["path"] as? String, reference == NativePBX.identifier(prefix + "file:" + path) {
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
                if let files = user.objects[id]?["files"] as? [String] {
                    user.objects[id]?["files"] = files.filter { !removable.contains($0) }
                }
                if user.objects[id]?["isa"] as? String == "XCBuildConfiguration" {
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
            for _ in 0..<3 {
                for id in removable where user.objects[id] != nil {
                    let used = user.objects.values.contains { object in
                        object["isa"] as? String != "PBXGroup" && object["isa"] as? String != "PBXVariantGroup"
                            && object.values.contains {
                                ($0 as? String) == id || ($0 as? [String])?.contains(id) == true
                            }
                    }
                    if used { continue }
                    user.objects.removeValue(forKey: id)
                    for group in Array(user.objects.keys) {
                        if let children = user.objects[group]?["children"] as? [String] {
                            user.objects[group]?["children"] = children.filter { $0 != id }
                        }
                    }
                }
            }
            if try jsonData(user.objects) != before {
                try user.save()
                changed.append(user.url)
            }
        }
        for (raw, owned) in settings["_workspaces"] as? [String: [String]] ?? [:] {
            let workspace = URL(fileURLWithPath: raw).standardizedFileURL.resolvingSymlinksInPath()
            try ProjectState(directory: project).registerProject(workspace)
            if FileManager.default.fileExists(atPath: workspace.path) {
                let document = try String(contentsOf: workspace, encoding: .utf8)
                // Retain every unrelated workspace reference.
                let references = try NativeWorkspaceReferences.read(workspace).filter { !owned.contains($0) }
                _ = try NativeWorkspace.update(workspace, references: references, previous: owned)
                if try String(contentsOf: workspace, encoding: .utf8) != document { changed.append(workspace) }
            }
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
