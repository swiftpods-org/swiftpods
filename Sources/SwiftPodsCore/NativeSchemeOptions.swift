import Foundation

enum NativeSchemeOptions {
    static func validate(_ options: [String: Any], file: String?) throws {
        let allowed: Set<String> = [
            "launch_arguments", "environment_variables", "code_coverage", "parallelizable", "build_configurations",
        ]
        guard Set(options.keys).isSubset(of: allowed),
            options["launch_arguments"] == nil || options["launch_arguments"] is [Any],
            options["environment_variables"] == nil || options["environment_variables"] is [String: Any],
            ["code_coverage", "parallelizable"].allSatisfy({
                options[$0] == nil || NativeScalarString.boolean(options[$0]!) != nil
            })
        else { throw Diagnostic("SP-SPEC-SCHEME", stage: "resolve", "Invalid scheme options", file: file) }
        if let value = options["build_configurations"] {
            guard let actions = value as? [String: String],
                Set(actions.keys).isSubset(of: ["Run", "Test", "Analyze", "Archive"])
            else {
                throw Diagnostic(
                    "SP-SPEC-SCHEME", stage: "resolve", "Invalid scheme build configurations", file: file)
            }
        }
        let values = normalized(options)
        let environment = values["environment_variables"] as? [String: String] ?? [:]
        guard environment.keys.allSatisfy(NativeProcessEnvironment.isValidName) else {
            throw Diagnostic(
                "SP-SPEC-SCHEME", stage: "resolve",
                "Environment variable names must be nonempty and cannot contain '=' or NUL", file: file)
        }
        let configurations = values["build_configurations"] as? [String: String] ?? [:]
        let strings =
            (values["launch_arguments"] as? [String] ?? [])
            + Array(environment.keys) + Array(environment.values) + Array(configurations.values)
        guard strings.allSatisfy(isXMLText) else {
            throw Diagnostic(
                "SP-SPEC-SCHEME", stage: "resolve", "Scheme strings must contain XML 1.0 characters", file: file)
        }
    }

    private static func isXMLText(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy {
            [9, 10, 13].contains($0.value) || (0x20...0xD7FF).contains($0.value)
                || (0xE000...0xFFFD).contains($0.value) || (0x10000...0x10FFFF).contains($0.value)
        }
    }

    static func normalized(_ options: [String: Any]) -> [String: Any] {
        var result = options
        if let values = options["launch_arguments"] as? [Any] {
            result["launch_arguments"] = values.map(NativeScalarString.string)
        }
        if let values = options["environment_variables"] as? [String: Any] {
            result["environment_variables"] = values.mapValues(NativeScalarString.string)
        }
        return result
    }
}
