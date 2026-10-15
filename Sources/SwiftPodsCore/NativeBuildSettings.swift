import Darwin
import Foundation

enum NativeBuildSettings {
    static func libraryFlags(_ libraries: [String], sources: [URL], settings: [String: Any], linkingWithClang: Bool)
        -> [String]
    {
        let cxx = Set(["mm", "cc", "cpp", "cxx", "c++"])
        let implicitCXX =
            linkingWithClang && sources.contains { cxx.contains($0.pathExtension) }
            && (settings["LINK_WITH_STANDARD_LIBRARIES"] as? String ?? "YES") != "NO" && settings["LD"] == nil
            && settings["LDPLUSPLUS"] == nil
        let standardLibrary = settings["CLANG_CXX_LIBRARY"] as? String ?? "libc++"
        return libraries.filter { library in
            !(implicitCXX && standardLibrary == "lib" + library)
        }.map { "-l" + $0 }
    }

    static func merge(_ old: [String: Any], _ new: [String: Any]) -> [String: Any] {
        old.merging(new) { previous, value in
            if let text = value as? String {
                return text.replacingOccurrences(
                    of: "$(inherited)", with: nativeStrings(previous).joined(separator: " ")
                ).replacingOccurrences(of: "${inherited}", with: nativeStrings(previous).joined(separator: " "))
            }
            if let values = value as? [String] {
                return values.flatMap {
                    ["$(inherited)", "${inherited}"].contains($0) ? nativeStrings(previous) : [$0]
                }
            }
            return value
        }
    }
    static func file(_ identifier: String, graph: NativePBX) throws -> URL {
        let root = graph.url.deletingLastPathComponent().deletingLastPathComponent()
        var visited = Set<String>()
        func path(_ id: String) throws -> URL {
            guard visited.insert(id).inserted, let object = graph.objects[id] else {
                throw Diagnostic(
                    "SP-XCCONFIG-PATH", stage: "analyze", "Invalid or cyclic configuration file reference", file: id)
            }
            let raw = (object["path"] as? String ?? "").replacingOccurrences(of: "$(SRCROOT)", with: root.path)
                .replacingOccurrences(of: "${SRCROOT}", with: root.path).replacingOccurrences(
                    of: "$(PROJECT_DIR)", with: root.path)
            if raw.hasPrefix("/") { return URL(fileURLWithPath: raw).standardizedFileURL }
            let tree = object["sourceTree"] as? String ?? "<group>"
            if tree == "<group>",
                let parent = graph.objects.keys.sorted().first(where: {
                    (graph.objects[$0]?["children"] as? [String])?.contains(id) == true
                })
            {
                return try path(parent).appendingPathComponent(raw).standardizedFileURL
            }
            guard ["SOURCE_ROOT", "PROJECT_DIR", "<group>", "<absolute>"].contains(tree) else {
                throw Diagnostic(
                    "SP-XCCONFIG-PATH", stage: "analyze", "Cannot resolve configuration source tree: " + tree, file: raw
                )
            }
            return root.appendingPathComponent(raw).standardizedFileURL
        }
        return try path(identifier)
    }
    static func conditions(_ key: String, context: [String: String]) -> (String, Bool) {
        let base = String(key.prefix(while: { $0 != "[" }))
        let expression = try! NSRegularExpression(pattern: #"\[([A-Za-z_]+)=([^\]]+)\]"#)
        let matches = expression.matches(in: key, range: NSRange(key.startIndex..., in: key))
        var valid = key == base || !matches.isEmpty
        for match in matches {
            guard let a = Range(match.range(at: 1), in: key), let b = Range(match.range(at: 2), in: key),
                let value = context[String(key[a])]
            else {
                valid = false
                continue
            }
            let pattern = String(key[b])
            valid = valid && pattern.withCString { p in value.withCString { v in fnmatch(p, v, 0) == 0 } }
        }
        return (base, valid)
    }
    static func xcconfig(
        _ path: URL, context: [String: String] = [:], variables: [String: String] = [:],
        missingGeneratedRoot: URL? = nil, inputs: inout Set<String>
    ) throws -> [String: Any] {
        var stack = Set<String>()
        func expand(_ text: String, values: [String: Any]) -> String {
            var result = text
            let replacements = variables.merging(context, uniquingKeysWith: { _, new in new }).merging(
                values.compactMapValues { $0 as? String }, uniquingKeysWith: { _, new in new })
            for (name, value) in replacements {
                result = result.replacingOccurrences(of: "$(" + name + ")", with: value).replacingOccurrences(
                    of: "${" + name + "}", with: value)
            }
            return result
        }
        func parse(_ file: URL) throws -> [String: Any] {
            try NativeCancellation.check()
            let canonical = file.resolvingSymlinksInPath().path
            if !FileManager.default.fileExists(atPath: file.path), file.pathExtension == "xcconfig",
                let missingGeneratedRoot,
                canonical.hasPrefix(missingGeneratedRoot.resolvingSymlinksInPath().path + "/")
            {
                return [:]
            }
            guard stack.insert(canonical).inserted else {
                throw Diagnostic("SP-XCCONFIG-CYCLE", stage: "analyze", "Cyclic xcconfig include", file: file.path)
            }
            defer { stack.remove(canonical) }
            inputs.insert(canonical)
            let contents = try String(contentsOf: file, encoding: .utf8).replacingOccurrences(of: "\\\n", with: " ")
                .replacingOccurrences(of: #"/\*[\s\S]*?\*/"#, with: "", options: .regularExpression)
            var values: [String: Any] = [:]
            for (number, raw) in contents.components(separatedBy: .newlines).enumerated() {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty || line.hasPrefix("//") { continue }
                if line.hasPrefix("#include") {
                    guard let start = line.firstIndex(of: "\""), let end = line.lastIndex(of: "\""), start < end else {
                        throw Diagnostic(
                            "SP-XCCONFIG-INCLUDE", stage: "analyze", "Invalid xcconfig include", file: file.path,
                            line: number + 1)
                    }
                    let supplied = expand(String(line[line.index(after: start)..<end]), values: values)
                    let child = URL(fileURLWithPath: supplied, relativeTo: file.deletingLastPathComponent())
                        .standardizedFileURL
                    if line.hasPrefix("#include?"), !FileManager.default.fileExists(atPath: child.path) { continue }
                    values = merge(values, try parse(child))
                    continue
                }
                let regex = try NSRegularExpression(
                    pattern: #"^([A-Za-z_][A-Za-z_0-9]*(?:\[[^\]]+\])*)\s*(\+=|\?=|=)\s*(.*?)\s*;?$"#)
                guard let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                    let keyRange = Range(match.range(at: 1), in: line),
                    let operation = Range(match.range(at: 2), in: line),
                    let valueRange = Range(match.range(at: 3), in: line)
                else {
                    throw Diagnostic(
                        "SP-XCCONFIG-SYNTAX", stage: "analyze", "Invalid xcconfig assignment", file: file.path,
                        line: number + 1)
                }
                var effectiveContext = context
                if effectiveContext["sdk"] == nil, let sdk = values["SDKROOT"] as? String {
                    effectiveContext["sdk"] = sdk
                }
                let (key, applies) = conditions(String(line[keyRange]), context: effectiveContext)
                guard applies else { continue }
                var text = String(line[valueRange]).components(separatedBy: "//")[0].trimmingCharacters(
                    in: .whitespaces)
                if text.hasPrefix("\""), text.hasSuffix("\""), text.count >= 2,
                    !text.dropFirst().dropLast().contains("\"")
                {
                    text = String(text.dropFirst().dropLast())
                }
                let op = String(line[operation])
                if op == "?=" && values[key] != nil { continue }
                if op == "+=" { text = "$(inherited) " + text }
                values = merge(values, [key: text])
            }
            return values
        }
        return try parse(path)
    }
    static func resolved(
        _ configuration: [String: Any], graph: NativePBX, base: [String: Any] = [:], files: Bool = true,
        missingGeneratedRoot: URL? = nil
    ) throws -> [String: Any] {
        var result = base
        var context = ["config": configuration["name"] as? String ?? "Debug"]
        let direct = configuration["buildSettings"] as? [String: Any] ?? [:]
        if let sdk = direct["SDKROOT"] as? String ?? base["SDKROOT"] as? String, sdk != "auto" { context["sdk"] = sdk }
        if let arch = direct["CURRENT_ARCH"] as? String ?? base["CURRENT_ARCH"] as? String { context["arch"] = arch }
        if files, let reference = configuration["baseConfigurationReference"] as? String {
            var inputs = Set<String>()
            let root = graph.url.deletingLastPathComponent().deletingLastPathComponent().path
            result = merge(
                result,
                try xcconfig(
                    file(reference, graph: graph), context: context, variables: ["SRCROOT": root, "PROJECT_DIR": root],
                    missingGeneratedRoot: missingGeneratedRoot, inputs: &inputs))
        }
        for key in direct.keys.sorted(by: { ($0.contains("[") ? 1 : 0, $0) < ($1.contains("[") ? 1 : 0, $1) }) {
            let (name, applies) = conditions(key, context: context)
            if applies { result = merge(result, [name: direct[key]!]) }
        }
        return result
    }
    static func response(_ request: [String: Any]) throws -> [String: Any] {
        guard let value = request["value"] as? [String: Any], let path = value["path"] as? String,
            let target = value["target"] as? String, let key = value["key"] as? String
        else { throw Diagnostic("SP-HOOK-SETTINGS", stage: "hook", "Invalid build setting query") }
        let (objects, root) = try NativeHookGraph.parse(value)
        let graph = try NativePBX(URL(fileURLWithPath: path).appendingPathComponent("project.pbxproj"))
        graph.objects = objects
        graph.root = root
        func configs(_ id: String) -> [[String: Any]] {
            let list = objects[id]?["buildConfigurationList"] as? String ?? ""
            return (objects[list]?["buildConfigurations"] as? [String] ?? []).compactMap { objects[$0] }
        }
        let project = configs(root["rootObject"] as? String ?? "")
        let includeFiles = value["xcconfig"] as? Bool == true
        var result: [String: Any] = [:]
        for config in configs(target) {
            let base = project.first { $0["name"] as? String == config["name"] as? String } ?? [:]
            let settings = try resolved(
                config, graph: graph, base: resolved(base, graph: graph, files: includeFiles), files: includeFiles)
            if let selected = settings[key], let name = config["name"] as? String { result[name] = selected }
        }
        return ["result": result]
    }
}
