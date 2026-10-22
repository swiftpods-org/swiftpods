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
            if let variable = NativeSwiftPackageCompileSettings.references[key],
                nativeStrings(value).contains("$(" + variable + ")")
            {
                let reference = "$(" + variable + ")"
                var additions = nativeStrings(value).filter { $0 != reference }
                for old in nativeStrings(original[key]) {
                    if let index = additions.firstIndex(of: old) { additions.remove(at: index) }
                }
                generated[key] = ["$(inherited)"] + additions.filter { !["$(inherited)", "${inherited}"].contains($0) }
                var kept = nativeStrings(original[key] ?? ["$(inherited)"])
                if !kept.contains(reference) { kept.append(reference) }
                direct[key] = kept
                continue
            }
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
        generated["PODS_ROOT"] = user.buildSettingPath(project.appendingPathComponent("Pods"))
        generated["PODS_PODFILE_DIR_PATH"] = user.buildSettingPath(project)
        generated["PODS_BUILD_DIR"] = "$(BUILD_DIR)"
        generated["PODS_CONFIGURATION_BUILD_DIR"] = "$(BUILD_DIR)/$(CONFIGURATION)$(EFFECTIVE_PLATFORM_NAME)"
        for (key, value) in generated {
            guard NativeBuildSettings.validKey(key) else {
                throw Diagnostic("SP-XCCONFIG-KEY", stage: "integrate", "Invalid xcconfig key", file: key)
            }
            guard NativeBuildSettings.needsProjectStorage(value) || NativeBuildSettings.needsProjectStorage(key) else {
                continue
            }
            // A project setting can represent these scalars; xcconfig lines cannot.
            direct[key] = settings[key] ?? value
            generated.removeValue(forKey: key)
        }
        let path = try supportConfiguration(label: label, name: name, settings: generated)
        let expression = user.relativeFilePath(path)
        let reference = user.add(
            "swiftpods:xcconfig:" + expression,
            user.relativeFileReference(path, type: "text.xcconfig"))
        var support = integrationSettings["_support_configurations"] as? [String: String] ?? [:]
        support[recordKey] = reference
        integrationSettings["_support_configurations"] = support
        let current = user.objects[configuration]?["baseConfigurationReference"] as? String
        let previous = (integrationSettings["_base_configurations"] as? [String: String])?[recordKey]
        let previouslyManaged =
            current != nil && current == previous && user.isGeneratedConfigurationReference(current!)
        var attached = current == nil || current == reference || previouslyManaged
        if let current, !attached {
            let scope = try NativeBuildSettings.resolvedScopes(
                user.objects[configuration] ?? [:], graph: user, targetName: target["name"] as? String
            ).projectScope
            var inputs = Set<String>()
            _ = try NativeBuildSettings.xcconfig(
                NativeBuildSettings.file(
                    current, graph: user, configuration: name, targetName: target["name"] as? String,
                    scope: scope),
                context: ["config": name],
                inputs: &inputs)
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
        if current == nil || previouslyManaged {
            user.objects[configuration]?["baseConfigurationReference"] = reference
        }
        if let root = user.root["rootObject"] as? String, let group = user.objects[root]?["mainGroup"] as? String {
            var children = user.objects[group]?["children"] as? [String] ?? []
            if !children.contains(reference) {
                children.append(reference)
                user.objects[group]?["children"] = children
            }
        }
        if current == nil || current == reference || previouslyManaged {
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
            guard NativeBuildSettings.validKey(key), !NativeBuildSettings.needsProjectStorage(key)
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
            guard !text.contains("\n"), !text.contains("\r"), !NativeBuildSettings.needsProjectStorage(text) else {
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
                let candidates = settings.filter {
                    (flags.contains($0.key) || custom.contains($0.key)) && !essential.contains($0.key)
                }
                for key in candidates.keys {
                    guard NativeBuildSettings.validKey(key) else {
                        throw Diagnostic("SP-XCCONFIG-KEY", stage: "integrate", "Invalid xcconfig key", file: key)
                    }
                }
                let moved = candidates.filter {
                    !NativeBuildSettings.needsProjectStorage($0.value)
                        && !NativeBuildSettings.needsProjectStorage($0.key)
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
