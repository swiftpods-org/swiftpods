import Darwin
import Foundation

enum NativeBuildSettings {
    private static let keyPattern = #"[A-Za-z_][A-Za-z_0-9]*(?:[ \t]*\[[^=\]\r\n]+=[^\]\r\n]*\])*"#

    struct Scopes {
        let projectScope: NativeBuildSettingScope
        let targetScope: NativeBuildSettingScope
        var project: [String: Any] { projectScope.values }
        var target: [String: Any] { targetScope.values }
    }

    private static func defaultScope(
        graph: NativePBX, configuration: String, targetName: String?, settingTypes: NativeBuildSettingTypes = .current
    ) -> NativeBuildSettingScope {
        let project = graph.url.deletingLastPathComponent()
        var values: [String: Any] = [
            "SRCROOT": graph.sourceRoot.path, "SOURCE_ROOT": "$(SRCROOT)",
            "PROJECT_DIR": graph.sourceRoot.path, "PROJECT_FILE_PATH": project.path,
            "PROJECT_NAME": project.deletingPathExtension().lastPathComponent, "CONFIGURATION": configuration,
        ]
        values["TARGET_NAME"] = targetName
        // Only an actual SDKROOT assignment receives the built-in inherited default.
        return NativeBuildSettingScope(
            values, literalKeys: Set(values.keys).subtracting(["SOURCE_ROOT"]),
            assignmentDefaults: ["SDKROOT": "macosx"], settingTypes: settingTypes)
    }

    static func validKey(_ key: String) -> Bool {
        key.range(of: "\\A" + keyPattern + "\\z", options: .regularExpression) != nil
    }

    static func expandedValue(_ key: String, settings: [String: Any]) throws -> String? {
        try NativeBuildSettingScope(settings).expandedValue(key)
    }

    /// Preliminary SDK guesses may lack definitions in a base file or a later scope.
    /// The complete target evaluation still diagnoses an unresolved cycle.
    private static func expandedSDK(_ scope: NativeBuildSettingScope, provisional: Bool) throws -> String? {
        do {
            return try scope.expandedValue("SDKROOT", undefinedAsEmpty: true)
        } catch let diagnostic as Diagnostic where provisional && diagnostic.code == "SP-XCCONFIG-CYCLE" {
            return nil
        }
    }

    static func addingConsumerSettings(_ additions: [String: Any], to settings: [String: Any], original: [String: Any])
        -> [String: Any]
    {
        let lists: Set<String> = [
            "OTHER_CFLAGS", "OTHER_CPLUSPLUSFLAGS", "OTHER_SWIFT_FLAGS", "OTHER_LDFLAGS",
            "GCC_PREPROCESSOR_DEFINITIONS", "SWIFT_ACTIVE_COMPILATION_CONDITIONS",
            "HEADER_SEARCH_PATHS", "USER_HEADER_SEARCH_PATHS", "SYSTEM_HEADER_SEARCH_PATHS",
            "FRAMEWORK_SEARCH_PATHS", "LIBRARY_SEARCH_PATHS", "SWIFT_INCLUDE_PATHS",
        ]
        var result = settings
        for (key, value) in additions {
            let base = String(key.prefix { $0 != "[" }).trimmingCharacters(in: .whitespaces)
            let inherits = nativeStrings(original[key]).contains {
                $0.contains("$(inherited)") || $0.contains("${inherited}")
            }
            if result[key] == nil {
                result[key] = value
            } else if inherits || (original[key] == nil && lists.contains(base)) {
                let added = nativeStrings(value).map {
                    $0.replacingOccurrences(of: "$(inherited)", with: "").replacingOccurrences(
                        of: "${inherited}", with: "")
                }.joined(separator: " ").trimmingCharacters(in: .whitespaces)
                result[key] = (nativeStrings(result[key]) + [added]).filter { !$0.isEmpty }.joined(separator: " ")
            }
        }
        return result
    }

    static func isCXXSource(_ source: URL, fileType: String? = nil, inputFileType: String? = nil) -> Bool {
        let clangSource =
            fileType.map { $0.hasPrefix("sourcecode.c.") || $0.hasPrefix("sourcecode.cpp.") }
            ?? (NativeFileSelection.objectSources.contains(source.pathExtension) && source.pathExtension != "swift")
        let effectiveType = clangSource && inputFileType != "automatic" ? inputFileType ?? fileType : fileType
        if let effectiveType {
            return ["sourcecode.cpp.cpp", "sourcecode.cpp.objcpp", "sourcecode.cpp.cpp.preprocessed"].contains(
                effectiveType)
        }
        return ["mm", "cc", "cpp", "cxx", "c++", "C", "M"].contains(source.pathExtension)
    }

    static func sourceIsExcluded(_ source: URL, relativeTo root: URL, settings: [String: Any]) -> Bool {
        let paths = [source.lastPathComponent, source.path, NativePath.relativePath(of: source, to: root)]
        func matches(_ key: String) -> Bool {
            settingWords(nativeStrings(settings[key]).joined(separator: " ")).contains { pattern in
                guard !pattern.utf8.contains(0) else { return false }
                return paths.contains { path in
                    pattern.withCString { p in path.withCString { v in fnmatch(p, v, 0) == 0 } }
                }
            }
        }
        // Explicit inclusion overrides an exclusion; it is not a whitelist.
        return matches("EXCLUDED_SOURCE_FILE_NAMES") && !matches("INCLUDED_SOURCE_FILE_NAMES")
    }

    private static func settingWords(_ text: String) -> [String] {
        var words: [String] = []
        var word = ""
        var quote: Unicode.Scalar?
        var escaped = false
        for scalar in text.unicodeScalars {
            if escaped {
                word.unicodeScalars.append(scalar)
                escaped = false
            } else if scalar == "\\" {
                escaped = true
            } else if scalar == quote {
                quote = nil
            } else if quote == nil && (scalar == "\"" || scalar == "'") {
                quote = scalar
            } else if quote == nil && CharacterSet.whitespacesAndNewlines.contains(scalar) {
                if !word.isEmpty { words.append(word); word = "" }
            } else {
                word.unicodeScalars.append(scalar)
            }
        }
        if escaped { word += "\\" }
        if !word.isEmpty { words.append(word) }
        return words
    }

    static func libraryFlags(
        _ libraries: [String], sources: [URL], settings: [String: Any], linkingWithClang: Bool,
        hasCXXSources: Bool? = nil
    ) -> [String] {
        let implicitCXX =
            linkingWithClang
            && (hasCXXSources
                ?? sources.contains {
                    isCXXSource($0, inputFileType: settings["GCC_INPUT_FILETYPE"] as? String)
                })
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
    static func needsProjectStorage(_ value: Any) -> Bool {
        let strings: [String]
        if let string = value as? String {
            strings = [string]
        } else if let values = value as? [String] {
            strings = values
        } else {
            return false
        }
        return strings.contains { $0.unicodeScalars.contains { $0 == "\u{2028}" || $0 == "\u{2029}" } }
    }

    static func file(
        _ identifier: String, graph: NativePBX, configuration: String = "Debug", targetName: String? = nil,
        variables: [String: Any] = [:]
    ) throws -> URL {
        try file(
            identifier, graph: graph, configuration: configuration, targetName: targetName,
            scope: NativeBuildSettingScope(variables))
    }

    static func file(
        _ identifier: String, graph: NativePBX, configuration: String, targetName: String?,
        scope: NativeBuildSettingScope
    ) throws -> URL {
        if let project = graph.objects[graph.root["rootObject"] as? String ?? ""] {
            try NativePBXPaths.validateObject(project, file: graph.url.path)
        }
        let root = graph.sourceRoot
        let referenceSettings = defaultScope(
            graph: graph, configuration: configuration, targetName: targetName, settingTypes: scope.settingTypes
        ).merging(scope)
        var visited = Set<String>()
        func path(_ id: String) throws -> URL {
            guard visited.insert(id).inserted, let object = graph.objects[id] else {
                throw Diagnostic(
                    "SP-XCCONFIG-PATH", stage: "analyze", "Invalid or cyclic configuration file reference", file: id)
            }
            try NativePBXPaths.validateObject(object, file: graph.url.path)
            let raw = try referenceSettings.expandedPathExpression(object["path"] as? String ?? "")
            guard !raw.utf8.contains(0) else {
                throw Diagnostic(
                    "SP-XCCONFIG-PATH", stage: "analyze", "Expanded configuration paths cannot contain NUL", file: id)
            }
            if raw.utf8.first == 47 { return URL(fileURLWithPath: raw).standardizedFileURL }
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
    /// Lexical platform inference when SDK metadata cannot be located.
    static func sdkName(_ value: String) -> String {
        let name = (value as NSString).lastPathComponent.lowercased()
        return name.hasSuffix(".sdk") ? String(name.dropLast(4)) : name
    }

    static func conditions(
        _ key: String, context: [String: String], sdkContext: NativeSDKContext = NativeSDKContext(),
        sourceRoot: URL? = nil
    ) -> (String, Bool) {
        let base = String(key.prefix(while: { $0 != "[" })).trimmingCharacters(in: .whitespaces)
        guard validKey(key) else { return (base, false) }
        let expression = try! NSRegularExpression(pattern: #"\[([^=\]\r\n]+)=([^\]\r\n]*)\]"#)
        let matches = expression.matches(in: key, range: NSRange(key.startIndex..., in: key))
        var valid = true
        for match in matches {
            guard let a = Range(match.range(at: 1), in: key), let b = Range(match.range(at: 2), in: key) else {
                valid = false
                continue
            }
            let axis = String(key[a])
            let supplied = context[axis]
            let pattern = String(key[b])
            // fnmatch consumes C strings; embedded NUL must never match a prefix.
            guard supplied?.utf8.contains(0) != true, !pattern.utf8.contains(0) else {
                valid = false
                continue
            }
            // Xcode treats a single * as unconditional, even for an unknown axis or SDK.
            if pattern == "*" { continue }
            guard let selected = supplied ?? (axis == "sdk" ? "macosx" : nil) else {
                valid = false
                continue
            }
            let value: String
            if axis == "sdk" {
                // An absent or explicitly empty SDKROOT uses Xcode's default macOS SDK.
                guard
                    let canonical = sdkContext.canonicalName(
                        selected.isEmpty ? "macosx" : selected, relativeTo: sourceRoot)
                else {
                    valid = false
                    continue
                }
                value = canonical
            } else {
                value = selected
            }
            valid = valid && pattern.withCString { p in value.withCString { v in fnmatch(p, v, 0) == 0 } }
        }
        return (base, valid)
    }

    private static func xcconfigLines(_ text: String) -> [(Int, String)] {
        let physical = text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: CharacterSet(charactersIn: "\r\n\u{2028}\u{2029}"))
        var result: [(Int, String)] = []
        var index = 0
        while index < physical.count {
            let number = index
            var line = physical[index]
            index += 1
            while line.hasSuffix("\\"), index < physical.count {
                line.removeLast()
                line += " " + physical[index]
                index += 1
            }
            result.append((number, line))
        }
        return result
    }

    static func xcconfig(
        _ path: URL, context: [String: String] = [:],
        base: [String: Any] = [:], overrides: [String: Any] = [:],
        missingGeneratedRoot: URL? = nil, inputs: inout Set<String>, sdkContext: NativeSDKContext = NativeSDKContext(),
        sourceRoot: URL? = nil
    ) throws -> [String: Any] {
        try configurationFileSettings(
            path, context: context,
            base: NativeBuildSettingScope(
                base, assignmentDefaults: ["SDKROOT": "macosx"], settingTypes: sdkContext.settingTypes),
            overrides: overrides,
            missingGeneratedRoot: missingGeneratedRoot, inputs: &inputs, sdkContext: sdkContext,
            sourceRoot: sourceRoot
        ).raw
    }

    private static func configurationFileSettings(
        _ path: URL, context: [String: String], base: NativeBuildSettingScope, overrides: [String: Any],
        overrideLiterals: Set<String> = [], missingGeneratedRoot: URL?, inputs: inout Set<String>,
        sdkContext: NativeSDKContext, sourceRoot: URL?, provisionalSDK: Bool = false
    ) throws -> (scope: NativeBuildSettingScope, raw: [String: Any]) {
        var stack = Set<String>()
        var evaluationContext = context
        if context["sdk"] == nil,
            let sdk = try expandedSDK(base.merging(overrides, literals: overrideLiterals), provisional: true)
        {
            evaluationContext["sdk"] = sdk
        }
        func parse(_ file: URL, inherited: NativeBuildSettingScope) throws -> (
            scope: NativeBuildSettingScope, raw: [String: Any]
        ) {
            try NativeCancellation.check()
            let canonical = file.resolvingSymlinksInPath().path
            if !FileManager.default.fileExists(atPath: file.path), file.pathExtension == "xcconfig",
                let missingGeneratedRoot,
                NativePath.isDescendant(
                    file.resolvingSymlinksInPath(), of: missingGeneratedRoot.resolvingSymlinksInPath())
            {
                return (inherited, [:])
            }
            guard stack.insert(canonical).inserted else {
                throw Diagnostic("SP-XCCONFIG-CYCLE", stage: "analyze", "Cyclic xcconfig include", file: file.path)
            }
            defer { stack.remove(canonical) }
            inputs.insert(canonical)
            let contents = try String(contentsOf: file, encoding: .utf8)
            var values: [String: Any] = [:]
            var scope = inherited
            for (number, raw) in xcconfigLines(contents) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty || line.hasPrefix("//") { continue }
                if line.hasPrefix("#") {
                    let expression = try NSRegularExpression(
                        pattern: #"\A#[ \t]*include(\?)?[ \t]*"([^"]*)"[ \t]*(?://.*)?\z"#)
                    guard let match = expression.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                        let range = Range(match.range(at: 2), in: line)
                    else {
                        throw Diagnostic(
                            "SP-XCCONFIG-INCLUDE", stage: "analyze", "Invalid xcconfig include", file: file.path,
                            line: number + 1)
                    }
                    // Xcode resolves include paths literally, including $(NAME) and ${NAME}.
                    let supplied = String(line[range])
                    guard !supplied.utf8.contains(0) else {
                        throw Diagnostic(
                            "SP-XCCONFIG-INCLUDE", stage: "analyze", "Include paths cannot contain NUL",
                            file: file.path, line: number + 1)
                    }
                    let child = URL(fileURLWithPath: supplied, relativeTo: file.deletingLastPathComponent())
                        .standardizedFileURL
                    if match.range(at: 1).location != NSNotFound,
                        !FileManager.default.fileExists(atPath: child.path)
                    {
                        continue
                    }
                    let parsed = try parse(child, inherited: scope)
                    scope = parsed.scope
                    values = merge(values, parsed.raw)
                    continue
                }
                let regex = try NSRegularExpression(
                    pattern: "\\A(" + keyPattern + #")[ \t]*=[ \t]*(.*?)[ \t]*;?\z"#, options: .dotMatchesLineSeparators
                )
                guard let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                    let keyRange = Range(match.range(at: 1), in: line),
                    let valueRange = Range(match.range(at: 2), in: line)
                else {
                    throw Diagnostic(
                        "SP-XCCONFIG-SYNTAX", stage: "analyze", "Invalid xcconfig assignment", file: file.path,
                        line: number + 1)
                }
                var effectiveContext = evaluationContext
                if effectiveContext["sdk"] == nil, let sdk = values["SDKROOT"] as? String {
                    effectiveContext["sdk"] = sdk
                }
                let (key, applies) = conditions(
                    String(line[keyRange]), context: effectiveContext, sdkContext: sdkContext, sourceRoot: sourceRoot)
                guard applies else { continue }
                let text = String(line[valueRange]).components(separatedBy: "//")[0].trimmingCharacters(
                    in: .whitespaces)
                values = merge(values, [key: text])
                scope = scope.merging([key: text])
            }
            return (scope, values)
        }
        // SDKROOT may follow a conditional assignment or live in a later include.
        // Resolve it from the complete file, then evaluate conditions with that SDK.
        // Keep assignment order intact and reject mutually dependent SDK selections.
        var visited = Set<String>()
        while true {
            let values = try parse(path, inherited: base)
            guard context["sdk"] == nil,
                let sdk = try expandedSDK(
                    values.scope.merging(overrides, literals: overrideLiterals), provisional: provisionalSDK),
                sdk != evaluationContext["sdk"]
            else { return values }
            guard visited.insert(sdk).inserted else {
                throw Diagnostic("SP-XCCONFIG-CYCLE", stage: "analyze", "Cyclic conditional SDKROOT", file: path.path)
            }
            evaluationContext["sdk"] = sdk
        }
    }
    static func resolved(
        _ configuration: [String: Any], graph: NativePBX, base: [String: Any] = [:], files: Bool = true,
        missingGeneratedRoot: URL? = nil, evaluatingSDK: String? = nil,
        sdkContext: NativeSDKContext = NativeSDKContext(), targetName: String? = nil, finalizeDefaults: Bool = true
    ) throws -> [String: Any] {
        try resolvedContext(
            configuration, graph: graph, base: NativeBuildSettingScope(base), files: files,
            missingGeneratedRoot: missingGeneratedRoot, evaluatingSDK: evaluatingSDK, sdkContext: sdkContext,
            targetName: targetName, finalizeDefaults: finalizeDefaults
        ).values
    }

    private static func resolvedContext(
        _ configuration: [String: Any], graph: NativePBX, base: NativeBuildSettingScope = NativeBuildSettingScope(),
        files: Bool = true, missingGeneratedRoot: URL? = nil, evaluatingSDK: String? = nil,
        sdkContext: NativeSDKContext = NativeSDKContext(), targetName: String? = nil, finalizeDefaults: Bool = true,
        directLiterals: Set<String> = [], provisionalSDK: Bool = false
    ) throws -> NativeBuildSettingScope {
        let effectiveBase = defaultScope(
            graph: graph, configuration: configuration["name"] as? String ?? "Debug", targetName: targetName,
            settingTypes: sdkContext.settingTypes
        ).merging(base)
        var context = ["config": configuration["name"] as? String ?? "Debug"]
        context["sdk"] = evaluatingSDK
        let direct = configuration["buildSettings"] as? [String: Any] ?? [:]
        if let arch = direct["CURRENT_ARCH"] as? String ?? effectiveBase.values["CURRENT_ARCH"] as? String {
            context["arch"] = arch
        }
        var visited = Set<String>()
        while true {
            var result = effectiveBase
            if files, let reference = configuration["baseConfigurationReference"] as? String {
                var inputs = Set<String>()
                result = try configurationFileSettings(
                    file(
                        reference, graph: graph, configuration: configuration["name"] as? String ?? "Debug",
                        targetName: targetName, scope: base), context: context,
                    base: effectiveBase, overrides: direct.filter { !$0.key.contains("[") },
                    overrideLiterals: directLiterals, missingGeneratedRoot: missingGeneratedRoot,
                    inputs: &inputs, sdkContext: sdkContext, sourceRoot: graph.sourceRoot,
                    provisionalSDK: true
                ).scope
            }
            let unconditional = result.merging(direct.filter { !$0.key.contains("[") }, literals: directLiterals)
            if context["sdk"] == nil, let sdk = try expandedSDK(unconditional, provisional: true) {
                context["sdk"] = sdk
            }
            for key in direct.keys.sorted(by: { ($0.contains("[") ? 1 : 0, $0) < ($1.contains("[") ? 1 : 0, $1) }) {
                let (name, applies) = conditions(
                    key, context: context, sdkContext: sdkContext, sourceRoot: graph.sourceRoot)
                if applies { result = result.merging([name: direct[key]!], literals: directLiterals) }
            }
            guard evaluatingSDK == nil, let sdk = try expandedSDK(result, provisional: provisionalSDK),
                sdk != context["sdk"]
            else { return try finalizeDefaults ? result.finalizedDefaults() : result }
            guard visited.insert(sdk).inserted else {
                throw Diagnostic(
                    "SP-XCCONFIG-CYCLE", stage: "analyze", "Cyclic conditional SDKROOT", file: graph.url.path)
            }
            context["sdk"] = sdk
        }
    }

    /// Project and target conditions see the same final SDK, including target overrides.
    static func resolved(
        _ configuration: [String: Any], inheriting projectConfiguration: [String: Any], graph: NativePBX,
        files: Bool = true, missingGeneratedRoot: URL? = nil, sdkContext: NativeSDKContext = NativeSDKContext(),
        targetName: String? = nil
    ) throws -> [String: Any] {
        try resolvedScopes(
            configuration, inheriting: projectConfiguration, graph: graph, files: files,
            missingGeneratedRoot: missingGeneratedRoot, sdkContext: sdkContext, targetName: targetName
        ).target
    }

    /// Retain the project scope used by Xcode to locate a target's base configuration.
    static func resolvedScopes(
        _ configuration: [String: Any], graph: NativePBX, targetName: String?
    ) throws -> Scopes {
        let project = graph.objects[graph.root["rootObject"] as? String ?? ""] ?? [:]
        let list = graph.objects[project["buildConfigurationList"] as? String ?? ""] ?? [:]
        let projectConfiguration =
            (list["buildConfigurations"] as? [String] ?? []).compactMap { graph.objects[$0] }
            .first { $0["name"] as? String == configuration["name"] as? String } ?? [:]
        return try resolvedScopes(
            configuration, inheriting: projectConfiguration, graph: graph, targetName: targetName)
    }

    static func resolvedScopes(
        _ configuration: [String: Any], inheriting suppliedProjectConfiguration: [String: Any], graph: NativePBX,
        files: Bool = true, missingGeneratedRoot: URL? = nil, sdkContext: NativeSDKContext = NativeSDKContext(),
        targetName: String? = nil
    ) throws -> Scopes {
        var projectConfiguration = suppliedProjectConfiguration
        if let targetName {
            var settings = (projectConfiguration["buildSettings"] as? [String: Any] ?? [:]).filter {
                String($0.key.prefix { $0 != "[" }).trimmingCharacters(in: .whitespaces) != "TARGET_NAME"
            }
            // The target's built-in name follows project settings and precedes target overrides.
            settings["TARGET_NAME"] = targetName
            projectConfiguration["buildSettings"] = settings
        }
        let literalNames: Set<String> = targetName == nil ? [] : ["TARGET_NAME"]
        let declared = defaultScope(
            graph: graph, configuration: configuration["name"] as? String ?? "Debug", targetName: targetName,
            settingTypes: sdkContext.settingTypes
        ).merging(
            (projectConfiguration["buildSettings"] as? [String: Any] ?? [:]).filter { !$0.key.contains("[") },
            literals: literalNames
        ).merging((configuration["buildSettings"] as? [String: Any] ?? [:]).filter { !$0.key.contains("[") })
        var sdk = try expandedSDK(declared, provisional: true)
        var visited = Set<String>()
        while true {
            let base = try resolvedContext(
                projectConfiguration, graph: graph, files: files, missingGeneratedRoot: missingGeneratedRoot,
                evaluatingSDK: sdk, sdkContext: sdkContext, targetName: targetName, finalizeDefaults: false,
                directLiterals: literalNames, provisionalSDK: true)
            let values = try resolvedContext(
                configuration, graph: graph, base: base, files: files, missingGeneratedRoot: missingGeneratedRoot,
                evaluatingSDK: sdk, sdkContext: sdkContext, targetName: targetName, finalizeDefaults: false)
            guard let selected = try values.expandedValue("SDKROOT", undefinedAsEmpty: true), selected != sdk
            else { return Scopes(projectScope: base, targetScope: try values.finalizedDefaults()) }
            guard visited.insert(selected).inserted else {
                throw Diagnostic(
                    "SP-XCCONFIG-CYCLE", stage: "analyze", "Cyclic conditional SDKROOT", file: graph.url.path)
            }
            sdk = selected
        }
    }

    static func response(
        _ request: [String: Any], sdkContext: NativeSDKContext = NativeSDKContext()
    ) throws -> [String: Any] {
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
                config, inheriting: base, graph: graph, files: includeFiles, sdkContext: sdkContext,
                targetName: objects[target]?["name"] as? String)
            if let selected = settings[key], let name = config["name"] as? String { result[name] = selected }
        }
        return ["result": result]
    }
}
