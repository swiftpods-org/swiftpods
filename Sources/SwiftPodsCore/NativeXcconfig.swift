import Foundation

extension NativeSpec {
    static func xcconfig(_ attributes: [String: Any], key: String) -> [String: Any] {
        let legacy = attributes["xcconfig"] as? [String: Any] ?? [:]
        let explicit = attributes[key] as? [String: Any] ?? [:]
        return (merge([key: legacy], [key: explicit])[key] as? [String: Any]) ?? [:]
    }
}

extension NativeXcode {
    func consumerConfiguration(
        _ target: [String: Any], configuration: String, user: NativePBX, recordKey: String, original: [String: Any],
        settings: [String: Any]
    ) throws -> [String: Any] {
        let label = target["label"] as? String ?? "Pods-" + (target["name"] as? String ?? "")
        let name = user.objects[configuration]?["name"] as? String ?? "Debug"
        var generated: [String: Any] = [:]
        var direct = settings
        // PODS_ROOT remains directly visible to legacy project hooks.
        let retained: Set<String> = ["PODS_ROOT", "EXCLUDED_SOURCE_FILE_NAMES"]
        for (key, value) in settings where !retained.contains(key) {
            if let before = original[key], try jsonData(["value": before]) == jsonData(["value": value]) { continue }
            if let before = original[key] {
                let previous = nativeStrings(before)
                guard previous.contains(where: { $0.contains("$(inherited)") || $0.contains("${inherited}") }) else {
                    // Preserve explicit user overrides and report the conflict.
                    configurationWarnings.append([
                        "kind": "warning", "code": "SP-XCCONFIG-OVERRIDE",
                        "message": "User build setting overrides the dependency configuration: " + key,
                        "file": user.url.path,
                    ])
                    direct[key] = before
                    continue
                }
                if let values = value as? [String] {
                    var additions = values
                    for old in previous { if let index = additions.firstIndex(of: old) { additions.remove(at: index) } }
                    generated[key] =
                        ["$(inherited)"] + additions.filter { !["$(inherited)", "${inherited}"].contains($0) }
                } else if let text = value as? String {
                    let old = previous.joined(separator: " ")
                    generated[key] = "$(inherited) " + (text.hasPrefix(old) ? String(text.dropFirst(old.count)) : text)
                } else {
                    generated[key] = value
                }
                direct[key] = before
            } else {
                generated[key] = value
                direct.removeValue(forKey: key)
            }
        }
        generated["PODS_ROOT"] = project.appendingPathComponent("Pods").path
        generated["PODS_PODFILE_DIR_PATH"] = project.path
        generated["PODS_BUILD_DIR"] = "$(BUILD_DIR)"
        generated["PODS_CONFIGURATION_BUILD_DIR"] = "$(BUILD_DIR)/$(CONFIGURATION)$(EFFECTIVE_PLATFORM_NAME)"
        let path = try supportConfiguration(label: label, name: name, settings: generated)
        let reference = user.add(
            "swiftpods:xcconfig:" + path.path,
            [
                "isa": "PBXFileReference", "path": path.path, "sourceTree": "<absolute>",
                "lastKnownFileType": "text.xcconfig",
            ])
        let current = user.objects[configuration]?["baseConfigurationReference"] as? String
        var attached = current == nil || current == reference
        if let current, !attached {
            var inputs = Set<String>()
            _ = try NativeBuildSettings.xcconfig(
                NativeBuildSettings.file(current, graph: user), context: ["config": name],
                variables: [
                    "SRCROOT": user.url.deletingLastPathComponent().deletingLastPathComponent().path,
                    "PODS_ROOT": project.appendingPathComponent("Pods").path,
                ], inputs: &inputs)
            attached = inputs.contains(path.resolvingSymlinksInPath().path)
            if !attached {
                configurationWarnings.append([
                    "kind": "warning", "code": "SP-XCCONFIG-BASE",
                    "message": "Existing base configuration is preserved; include " + path.path
                        + " to consume the generated dependency settings", "file": user.url.path,
                ])
                return settings
            }
        }
        if current == nil { user.objects[configuration]?["baseConfigurationReference"] = reference }
        if let root = user.root["rootObject"] as? String, let group = user.objects[root]?["mainGroup"] as? String {
            var children = user.objects[group]?["children"] as? [String] ?? []
            if !children.contains(reference) {
                children.append(reference)
                user.objects[group]?["children"] = children
            }
        }
        if current == nil || current == reference {
            var records = integrationSettings["_base_configurations"] as? [String: String] ?? [:]
            records[recordKey] = reference
            integrationSettings["_base_configurations"] = records
        }
        return direct
    }
    func supportConfiguration(label: String, name: String, settings: [String: Any]) throws -> URL {
        let path = project.appendingPathComponent(
            "Pods/Target Support Files/" + label + "/" + label + "." + name.lowercased() + ".xcconfig")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        var lines = ["// Generated by SwiftPods."]
        for (key, value) in settings.sorted(by: { $0.key < $1.key }) {
            guard key.range(of: #"\A[A-Za-z_][A-Za-z0-9_]*(?:\[[^\n\]]+\])*\z"#, options: .regularExpression) != nil
            else { throw Diagnostic("SP-XCCONFIG-KEY", stage: "integrate", "Invalid xcconfig key", file: key) }
            let text: String
            if let strings = value as? [String] {
                text = strings.joined(separator: " ")
            } else if let string = value as? String {
                text = string
            } else if let number = value as? NSNumber {
                text =
                    CFGetTypeID(number) == CFBooleanGetTypeID() ? (number.boolValue ? "YES" : "NO") : number.stringValue
            } else {
                throw Diagnostic(
                    "SP-XCCONFIG-VALUE", stage: "integrate", "Build settings must be strings, arrays or numbers",
                    file: key)
            }
            guard !text.contains("\n"), !text.contains("\r") else {
                throw Diagnostic(
                    "SP-XCCONFIG-VALUE", stage: "integrate", "Build setting cannot contain newlines", file: key)
            }
            lines.append(key + " = " + text)
        }
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        if (try? Data(contentsOf: path)) != data { try data.write(to: path, options: .atomic) }
        return path
    }
    func podConfigurations() throws {
        var custom = Set<String>()
        func inspect(_ node: [String: Any]) {
            for key in ["xcconfig", "pod_target_xcconfig"] {
                custom.formUnion((node[key] as? [String: Any] ?? [:]).keys)
            }
            for value in node.values {
                if let child = value as? [String: Any] { inspect(child) }
                if let children = value as? [[String: Any]] { for child in children { inspect(child) } }
            }
        }
        for spec in resolution.specs.values { inspect(spec.data) }
        let flags: Set<String> = [
            "HEADER_SEARCH_PATHS", "FRAMEWORK_SEARCH_PATHS", "LIBRARY_SEARCH_PATHS", "OTHER_LDFLAGS", "OTHER_CFLAGS",
            "OTHER_CPLUSPLUSFLAGS", "GCC_PREPROCESSOR_DEFINITIONS", "SWIFT_ACTIVE_COMPILATION_CONDITIONS",
            "SWIFT_INCLUDE_PATHS",
        ]
        let essential: Set<String> = [
            "SDKROOT", "SWIFT_VERSION", "PRODUCT_NAME", "PRODUCT_MODULE_NAME", "MACH_O_TYPE", "DEFINES_MODULE",
        ]
        for id in targetIDs {
            guard let label = graph.objects[id]?["name"] as? String,
                let list = graph.objects[id]?["buildConfigurationList"] as? String
            else { continue }
            for config in graph.objects[list]?["buildConfigurations"] as? [String] ?? [] {
                guard let name = graph.objects[config]?["name"] as? String else { continue }
                let settings = graph.objects[config]?["buildSettings"] as? [String: Any] ?? [:]
                let moved = settings.filter {
                    (flags.contains($0.key) || custom.contains($0.key)) && !essential.contains($0.key)
                }
                let path = try supportConfiguration(label: label, name: name, settings: moved)
                graph.objects[config]?["buildSettings"] = settings.filter { moved[$0.key] == nil }
                let reference = file(path.path, type: "text.xcconfig")
                graph.objects[config]?["baseConfigurationReference"] = reference
                if let root = graph.root["rootObject"] as? String,
                    let group = graph.objects[root]?["mainGroup"] as? String
                {
                    var children = graph.objects[group]?["children"] as? [String] ?? []
                    children.append(reference)
                    graph.objects[group]?["children"] = children
                }
            }
        }
    }
}
