import Foundation

/// Script text is preserved for Xcode to execute in its build environment.
struct NativeScriptPhase {
    static let prefix = "[CP-User] "
    let name: String
    let position: String
    let object: [String: Any]

    init(_ value: [String: Any]) throws {
        let strings = [
            "shell_path": "shellPath", "dependency_file": "dependencyFile", "always_out_of_date": "alwaysOutOfDate",
        ]
        let paths = [
            "input_files": "inputPaths", "output_files": "outputPaths", "input_file_lists": "inputFileListPaths",
            "output_file_lists": "outputFileListPaths",
        ]
        let allowed = Set(
            ["name", "script", "execution_position", "show_env_vars_in_log"] + Array(strings.keys) + Array(paths.keys))
        guard Set(value.keys).isSubset(of: allowed), let name = value["name"] as? String, !name.isEmpty,
            !name.contains("\0"), let script = value["script"] as? String, !script.contains("\0")
        else {
            throw Diagnostic(
                "SP-SCRIPT-SCHEMA", stage: "integrate", "Script phase requires name/script strings and known options")
        }
        self.name = name
        position = value["execution_position"] as? String ?? "any"
        guard value["execution_position"] == nil || value["execution_position"] is String,
            ["before_compile", "after_compile", "before_headers", "after_headers", "any"].contains(position)
        else {
            throw Diagnostic(
                "SP-SCRIPT-POSITION", stage: "integrate", "Invalid execution position for script phase \(name)")
        }
        var object: [String: Any] = [
            "isa": "PBXShellScriptBuildPhase", "name": Self.prefix + name,
            "buildActionMask": "2147483647", "runOnlyForDeploymentPostprocessing": "0", "files": [],
            "shellPath": "/bin/sh", "shellScript": script,
        ]
        for (key, field) in strings where value[key] != nil && !(value[key] is NSNull) {
            guard let text = value[key] as? String, !text.contains("\0"),
                key != "always_out_of_date" || ["0", "1"].contains(text)
            else {
                throw Diagnostic("SP-SCRIPT-SCHEMA", stage: "integrate", "Invalid \(key) for script phase \(name)")
            }
            object[field] = text
        }
        for (key, field) in paths {
            guard value[key] == nil || value[key] is NSNull || value[key] is [String] else {
                throw Diagnostic(
                    "SP-SCRIPT-SCHEMA", stage: "integrate", "\(key) must be an array of paths for script phase \(name)")
            }
            let entries = value[key] as? [String] ?? []
            guard entries.allSatisfy({ !$0.utf8.contains(where: { $0 == 0 || $0 == 10 || $0 == 13 }) }) else {
                throw Diagnostic("SP-SCRIPT-SCHEMA", stage: "integrate", "Invalid path for script phase \(name)")
            }
            object[field] = entries
        }
        if let flag = value["show_env_vars_in_log"], !(flag is NSNull) {
            let text = flag as? String ?? NativeScalarString.boolean(flag).map { $0 ? "1" : "0" }
            guard let text, ["0", "1"].contains(text) else {
                throw Diagnostic(
                    "SP-SCRIPT-SCHEMA", stage: "integrate",
                    "show_env_vars_in_log must be '0' or '1' for script phase \(name)")
            }
            if text == "0" { object["showEnvVarsInLog"] = "0" }
        }
        self.object = object
    }

    static func parse(_ value: Any?) throws -> [Self] {
        guard let value, !(value is NSNull) else { return [] }
        if let phase = value as? [String: Any] { return [try Self(phase)] }
        guard let phases = value as? [[String: Any]] else {
            throw Diagnostic(
                "SP-SCRIPT-SCHEMA", stage: "integrate", "Script phases must be a hash or an array of hashes")
        }
        return try phases.map(Self.init)
    }

    static func apply(_ phases: [Self], target: String, graph: NativePBX) {
        func key(_ name: String) -> String { "script:\(target):" + name }
        let names = Set(phases.map(\.name))
        var order = graph.objects[target]?["buildPhases"] as? [String] ?? []
        order.removeAll { id in
            guard let label = graph.objects[id]?["name"] as? String, label.hasPrefix(prefix) else { return false }
            let name = String(label.dropFirst(prefix.count))
            guard id == NativePBX.identifier(key(name)), !names.contains(name) else { return false }
            graph.objects.removeValue(forKey: id)
            return true
        }
        var seen = Set<String>()
        let selected = Array(phases.reversed().filter { seen.insert($0.name).inserted }.reversed())
        let ids = selected.map { graph.add(key($0.name), $0.object) }
        order += ids.filter { !order.contains($0) }
        for position in ["any", "before_headers", "after_headers", "before_compile", "after_compile"] {
            let group = zip(selected, ids).filter { $0.0.position == position }.map { $0.1 }
            guard !group.isEmpty else { continue }
            // Change only this position's managed slots, keeping foreign phases in place.
            let slots = order.indices.filter { group.contains(order[$0]) }
            for (slot, id) in zip(slots, group) { order[slot] = id }
            guard position != "any" else { continue }
            let headers = position.hasSuffix("headers")
            func isAnchor(_ id: String) -> Bool {
                let object = graph.objects[id] ?? [:]
                if !headers { return object["isa"] as? String == "PBXSourcesBuildPhase" }
                let path = object["dstPath"] as? String ?? ""
                return object["isa"] as? String == "PBXHeadersBuildPhase"
                    || (object["isa"] as? String == "PBXCopyFilesBuildPhase"
                        && (path.contains("_HEADERS_FOLDER_PATH)") || path.contains("_HEADERS_FOLDER_PATH}")))
            }
            let anchors = order.indices.filter { isAnchor(order[$0]) }
            let before = position.hasPrefix("before_")
            guard let anchor = before ? anchors.first : anchors.last,
                slots.contains(where: { before ? $0 > anchor : $0 < anchor })
            else { continue }
            order.removeAll { group.contains($0) }
            let remaining = order.indices.filter { isAnchor(order[$0]) }
            order.insert(contentsOf: group, at: before ? remaining.first! : remaining.last! + 1)
        }
        graph.objects[target]?["buildPhases"] = order
    }
}

extension NativeSpec {
    func scriptPhases(for request: NativeDependency) throws -> [NativeScriptPhase] {
        let node = try nodes(request.name).last!.data
        func phases(_ node: [String: Any]) throws -> [NativeScriptPhase] {
            try NativeScriptPhase.parse(node["script_phases"] ?? node["script_phase"])
        }
        return try phases(node) + phases(node[request.platform] as? [String: Any] ?? [:])
    }
    var containsExecutableCommands: Bool {
        func contains(_ value: Any) -> Bool {
            if let node = value as? [String: Any] {
                for key in ["prepare_command", "script_phase", "script_phases"] {
                    if let command = node[key], !(command is NSNull) {
                        if let array = command as? [Any], array.isEmpty { continue }
                        return true
                    }
                }
                return node.values.contains(where: contains)
            }
            return (value as? [Any] ?? []).contains(where: contains)
        }
        return contains(data)
    }
}
