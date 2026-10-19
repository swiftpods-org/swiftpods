import Foundation

/// Ownership values describe the bytes already written; only their project keys move.
enum NativeIntegrationLocation {
    static func contractManifest(_ manifest: [String: Any], bindings: [String: String], root: URL) -> [String: Any] {
        var result = manifest
        result["targets"] = (manifest["targets"] as? [[String: Any]] ?? []).map { original -> [String: Any] in
            var target = original.filter { $0.key != "_id" }
            guard let selected = target["project"] as? String else { return target }
            let path = resolve(selected, root: root)
            let file = (path.pathExtension == "xcodeproj" ? path : path.appendingPathExtension("xcodeproj"))
                .appendingPathComponent("project.pbxproj")
            if let location = bindings[file.path], location.utf8.first != 47 {
                target["project"] = NativePath.relativePath(
                    of: resolve(location, root: root).deletingLastPathComponent(), to: root)
            }
            return target
        }
        return result
    }

    static func previousRoot(_ settings: [String: Any]) -> URL? {
        if let path = settings["_project_root"] as? String, path.utf8.first == 47 {
            return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        }
        let roots = Set(
            settings.values.compactMap { value -> String? in
                guard let record = value as? [String: Any],
                    let path = (record["written"] as? [String: Any])?["PODS_ROOT"] as? String,
                    path.utf8.first == 47
                else { return nil }
                let url = URL(fileURLWithPath: path)
                return url.lastPathComponent == "Pods" ? url.deletingLastPathComponent().path : nil
            })
        return roots.count == 1 ? roots.first.map { URL(fileURLWithPath: $0, isDirectory: true) } : nil
    }

    static func projectBindings(
        _ declarations: [String: Any], analyzed: [String: Any], root: URL
    ) -> [String: String] {
        var result: [String: String] = [:]
        let original = declarations["targets"] as? [[String: Any]] ?? []
        let targets = analyzed["targets"] as? [[String: Any]] ?? []
        for (declaration, target) in zip(original, targets) {
            guard let selected = target["project"] as? String ?? analyzed["project"] as? String else { continue }
            let selectedURL = resolve(selected, root: root)
            let file =
                (selectedURL.pathExtension == "xcodeproj"
                ? selectedURL : selectedURL.appendingPathExtension("xcodeproj"))
                .appendingPathComponent("project.pbxproj")
            var location = declaration["project"] as? String ?? declarations["project"] as? String ?? selected
            if resolve(location, root: root).pathExtension != "xcodeproj" { location += ".xcodeproj" }
            result[file.path] = (location as NSString).appendingPathComponent("project.pbxproj")
        }
        return result
    }

    /// The generated project's file IDs encode physical paths, even when a PBX
    /// path expression contains escaped dollars. This preserves the old format's
    /// identity without guessing from whichever neighboring file still exists.
    private static func generatedConfigurationIdentities(_ project: URL, generated: URL) -> [String: Set<String>] {
        guard
            let graph = try? NativePBX(
                project.appendingPathComponent("Pods/Pods.xcodeproj/project.pbxproj"), existing: true)
        else { return [:] }
        var result: [String: Set<String>] = [:]
        for (id, object) in graph.objects {
            guard object["isa"] as? String == "PBXFileReference", let path = object["path"] as? String else { continue }
            for physical in Set([path, NativeBuildSetting.decodedLiteral(path)]) {
                guard id == NativePBX.identifier("file:" + physical),
                    NativePath.relativeComponents(of: URL(fileURLWithPath: physical), to: generated)?.isEmpty == false
                else { continue }
                result[path, default: []].insert(physical)
            }
        }
        // Random UUID installations retain the target's physical label and
        // configuration name; both must agree with the saved reference spelling.
        for target in graph.objects.values {
            guard ["PBXNativeTarget", "PBXAggregateTarget"].contains(target["isa"] as? String ?? ""),
                let label = target["name"] as? String,
                let list = target["buildConfigurationList"] as? String
            else { continue }
            for id in graph.objects[list]?["buildConfigurations"] as? [String] ?? [] {
                guard let config = graph.objects[id], let name = config["name"] as? String,
                    let ref = config["baseConfigurationReference"] as? String,
                    let path = graph.objects[ref]?["path"] as? String
                else { continue }
                let physical = generated.appendingPathComponent(
                    label + "/" + label + "." + name.lowercased() + ".xcconfig"
                ).path
                guard [path, NativeBuildSetting.decodedLiteral(path)].contains(physical) else { continue }
                result[path, default: []].insert(physical)
            }
        }
        return result
    }

    static func relocateGeneratedConfigurations(_ graph: NativePBX, from old: URL, to root: URL) throws {
        let generated = old.appendingPathComponent("Pods/Target Support Files")
        let receipt = try? readObject(
            root.appendingPathComponent("Pods/Target Support Files/SwiftPods-Integration.json"))
        let encoded: Bool
        if let value = receipt?["_configuration_path_encoding"] {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.intValue == 1,
                number.doubleValue == 1
            else {
                throw Diagnostic(
                    "SP-INTEGRATION-LOCATION", stage: "analyze", "Unsupported generated configuration path encoding")
            }
            encoded = true
        } else {
            encoded = false
        }
        let identities = encoded ? [:] : generatedConfigurationIdentities(root, generated: generated)
        for (id, object) in graph.objects {
            guard let path = object["path"] as? String, graph.isGeneratedConfigurationReference(id) else { continue }
            let decoded = NativeBuildSetting.decodedLiteral(path)
            var candidates = Set([decoded, path]).sorted().filter {
                NativePath.relativeComponents(of: URL(fileURLWithPath: $0), to: generated)?.isEmpty == false
            }
            guard !candidates.isEmpty else { continue }
            let configs = graph.objects.values.filter { $0["baseConfigurationReference"] as? String == id }
            if encoded {
                candidates = candidates.filter { $0 == decoded }
            } else if let known = identities[path], known.count == 1 {
                candidates = candidates.filter { known.contains($0) }
            } else if candidates.count > 1 {
                let named = candidates.filter { candidate in
                    configs.contains { config in
                        guard let name = config["name"] as? String else { return false }
                        return candidate.hasSuffix("." + name.lowercased() + ".xcconfig")
                    }
                }
                if named.count == 1 {
                    candidates = named
                } else {
                    // Without evidence of the historical raw format, preserve
                    // PBX expression semantics. File existence cannot establish
                    // identity when the intended generated file is missing.
                    candidates = candidates.filter { $0 == decoded }
                }
            }
            guard let physical = candidates.first,
                let components = NativePath.relativeComponents(of: URL(fileURLWithPath: physical), to: generated)
            else { continue }
            let expression = NativeBuildSetting.literal(
                root.appendingPathComponent("Pods/Target Support Files").appendingPathComponent(
                    components.joined(separator: "/")
                ).path)
            graph.objects[id]?["path"] = expression
            graph.normalizedConfigurationPaths[id] = expression
        }
    }

    static func workspaceBindings(_ manifest: [String: Any], projects: [String: String], root: URL) -> [String: String]
    {
        guard let first = projects.keys.sorted().first else { return [:] }
        let supplied =
            manifest["workspace"] as? String
            ?? URL(fileURLWithPath: first).deletingLastPathComponent().deletingPathExtension().lastPathComponent
        let name = supplied.hasSuffix(".xcworkspace") ? supplied : supplied + ".xcworkspace"
        let location = (name as NSString).appendingPathComponent("contents.xcworkspacedata")
        let file = resolve(location, root: root).resolvingSymlinksInPath()
        let relative = NativePath.relativeComponents(of: file, to: root)?.joined(separator: "/")
        return [file.path: relative ?? location]
    }

    static func relocated(
        _ settings: [String: Any], to root: URL, selected: [String: String] = [:],
        selectedWorkspaces: [String: String] = [:]
    ) throws -> [String: Any] {
        var result = settings
        let current = URL(fileURLWithPath: root.path, isDirectory: true).standardizedFileURL
        for field in ["_project_paths", "_workspace_paths"] where settings[field] != nil {
            guard settings[field] is [String: String] else {
                throw Diagnostic(
                    "SP-INTEGRATION-LOCATION", stage: "integrate", "Invalid ownership location bindings", file: field)
            }
        }
        if let value = settings["_project_root"] {
            guard let path = value as? String, path.utf8.first == 47 else {
                throw Diagnostic("SP-INTEGRATION-LOCATION", stage: "integrate", "Invalid ownership project root")
            }
        }
        let origin = previousRoot(settings)
        var bindings = settings["_project_paths"] as? [String: String] ?? [:]
        var workspaceBindings = settings["_workspace_paths"] as? [String: String] ?? [:]
        if let origin, origin.standardizedFileURL != current {
            var mapping: [String: [String]] = [:]
            for path in NativeIntegrationSettings.projectPaths(settings) {
                var destinations = selected.compactMap { destination, location -> String? in
                    let previous = resolve(location, root: origin)
                    return previous.resolvingSymlinksInPath() == URL(fileURLWithPath: path).resolvingSymlinksInPath()
                        ? destination : nil
                }
                if let components = NativePath.relativeComponents(of: URL(fileURLWithPath: path), to: origin) {
                    let location = components.joined(separator: "/")
                    bindings[path] = location
                    destinations.append(resolve(location, root: current).path)
                } else if let location = bindings[path] {
                    destinations.append(resolve(location, root: current).path)
                }
                guard !destinations.isEmpty else {
                    throw Diagnostic(
                        "SP-INTEGRATION-LOCATION", stage: "integrate",
                        "Relocated legacy metadata cannot identify this external project. Run install with its original project declarations before deintegrating.",
                        file: path)
                }
                mapping[path] = Array(
                    Set(
                        destinations.map { candidate in
                            selected.keys.sorted().first {
                                URL(fileURLWithPath: $0).resolvingSymlinksInPath()
                                    == URL(fileURLWithPath: candidate).resolvingSymlinksInPath()
                            } ?? candidate
                        })
                ).sorted()
            }
            func keys(_ values: [String: Any]) throws -> [String: Any] {
                var output: [String: Any] = [:]
                for (key, value) in values {
                    let match = mapping.keys.sorted { $0.count > $1.count }.first {
                        key == $0 || key.hasPrefix($0 + ":")
                    }
                    let destinations =
                        match.map { path in mapping[path]!.map { $0 + key.dropFirst(path.count) } } ?? [key]
                    for destination in destinations {
                        guard output[destination] == nil else {
                            throw Diagnostic(
                                "SP-INTEGRATION-LOCATION", stage: "integrate", "Relocated ownership records collide",
                                file: destination)
                        }
                        output[destination] = value
                    }
                }
                return output
            }
            result = try keys(settings)
            for field in ["_base_configurations", "_support_configurations", "_swift_packages", "_project_attributes"] {
                if let values = settings[field] as? [String: Any] { result[field] = try keys(values) }
            }
            bindings = (try keys(bindings) as? [String: String]) ?? [:]
            var workspaces: [String: [String]] = [:]
            for (path, owned) in settings["_workspaces"] as? [String: [String]] ?? [:] {
                let location: String
                if let components = NativePath.relativeComponents(of: URL(fileURLWithPath: path), to: origin) {
                    location = components.joined(separator: "/")
                } else if let supplied = workspaceBindings[path] {
                    location = supplied
                } else {
                    throw Diagnostic(
                        "SP-INTEGRATION-LOCATION", stage: "integrate",
                        "Relocated legacy metadata cannot identify this external workspace", file: path)
                }
                var destinations = selectedWorkspaces.compactMap { destination, value -> String? in
                    resolve(value, root: origin).resolvingSymlinksInPath()
                        == URL(fileURLWithPath: path).resolvingSymlinksInPath()
                        ? destination : nil
                }
                destinations.append(resolve(location, root: current).resolvingSymlinksInPath().path)
                workspaceBindings.removeValue(forKey: path)
                for destination in Set(destinations) {
                    guard workspaces[destination] == nil || workspaces[destination] == owned else {
                        throw Diagnostic(
                            "SP-INTEGRATION-LOCATION", stage: "integrate",
                            "Relocated workspace ownership records collide", file: destination)
                    }
                    workspaces[destination] = owned
                    workspaceBindings[destination] = location
                }
            }
            result["_workspaces"] = workspaces
        }
        bindings.merge(selected) { _, new in new }
        workspaceBindings.merge(selectedWorkspaces) { _, new in new }
        result["_project_root"] = current.path
        result["_project_paths"] = bindings
        result["_workspace_paths"] = workspaceBindings
        return result
    }

    private static func resolve(_ location: String, root: URL) -> URL {
        URL(fileURLWithPath: location, relativeTo: URL(fileURLWithPath: root.path, isDirectory: true))
            .standardizedFileURL
    }
}
