import Foundation

enum NativeBuildSetting {
    /// Encode filesystem text once before placing it in an Xcode expression.
    static func literal(_ value: String) -> String {
        value.replacingOccurrences(of: "$", with: "$$")
    }
    /// Unknown PODS_* settings are parsed as lists, then exported as strings.
    /// An unpaired backslash already quotes the following dollar in that parser.
    static func scalarLiteral(_ value: String) -> String {
        var result = ""
        var backslashes = 0
        for scalar in value.unicodeScalars {
            if scalar == "$", backslashes.isMultiple(of: 2) { result += "$" }
            result.unicodeScalars.append(scalar)
            backslashes = scalar == "\\" ? backslashes + 1 : 0
        }
        return result
    }
    static func literalPath(_ value: String) -> String { path(literal(value)) }
    /// Only use for references that this generator encoded as literal paths.
    static func decodedLiteral(_ value: String) -> String {
        value.replacingOccurrences(of: "$$", with: "$")
    }
    static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
    static func path(_ value: String) -> String {
        value.rangeOfCharacter(from: .whitespacesAndNewlines) != nil || value.contains("\"") || value.contains("\\")
            ? quoted(value) : value
    }
}

extension NativeXcode {
    func publicHeaderDirectory(_ platform: String) -> String {
        "Pods/Headers/Public" + (platformNames.count > 1 ? "/" + platform : "")
    }
    func publicHeaderSetting(_ platform: String) -> String {
        "$(PODS_ROOT)" + publicHeaderDirectory(platform).dropFirst(4)
    }

    func nativeDependencies(_ target: [String: Any], search: Bool = false) -> [[String: Any]] {
        target[search ? "search_dependencies" : "dependencies"] as? [[String: Any]] ?? []
    }
    func dependencyEnabled(_ dependency: NativeDependency, configuration: String) -> Bool {
        guard dependency.options["configurations"] != nil else { return true }
        return nativeStrings(dependency.options["configurations"]).contains {
            $0.caseInsensitiveCompare(configuration) == .orderedSame
        }
    }

    func configuredDependencyRoots(_ target: [String: Any]) throws -> [String: Set<String>] {
        let platform = target["platform"] as? [String: String] ?? [:]
        let requests = try nativeDependencies(target).flatMap {
            try NativeDependency(
                $0, platform: platform["name"] ?? "ios", deployment: platform["deployment_target"] ?? "0"
            ).expandedSelections()
        }
        return try Dictionary(
            uniqueKeysWithValues: configurationNames.map { configuration in
                (
                    configuration,
                    try dependencyRoots(requests.filter { dependencyEnabled($0, configuration: configuration) })
                )
            })
    }
}
