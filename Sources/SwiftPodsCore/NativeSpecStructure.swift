import Foundation

/// Validate structured declarations before hooks, downloads or project writes.
enum NativeSpecStructure {
    static func validate(_ key: String, value: Any, file: String?) throws {
        try NativeSpecPaths.validate(key, value: value, file: file)
        func invalid(_ message: String) -> Diagnostic {
            Diagnostic("SP-SPEC-ATTRIBUTE-TYPE", stage: "resolve", message, file: file)
        }
        func author(_ value: Any) -> Bool {
            if value is String { return true }
            guard let values = value as? [String: Any] else { return false }
            return values.values.allSatisfy { $0 is String || $0 is NSNull }
        }
        func finite(_ value: Any) -> Bool {
            if let number = value as? NSNumber { return number.doubleValue.isFinite }
            if let values = value as? [Any] { return values.allSatisfy(finite) }
            if let values = value as? [String: Any] { return values.values.allSatisfy(finite) }
            return true
        }
        switch key {
        case "scheme":
            if let options = value as? [String: Any] { try NativeSchemeOptions.validate(options, file: file) }
        case "script_phases":
            _ = try NativeScriptPhase.parse(value)
        case "on_demand_resources":
            _ = try NativeOnDemandResources.declarations(value)
        case "default_subspecs", "requires_arc":
            if let values = value as? [Any], !values.allSatisfy({ $0 is String || $0 is NSNull }) {
                throw invalid(key + " requires string values")
            }
        case "authors":
            guard (value as? [Any] ?? [value]).allSatisfy(author) else {
                throw invalid("Authors must contain names and optional email strings")
            }
        case "license":
            if let values = value as? [String: Any], !values.values.allSatisfy({ $0 is String || $0 is NSNull }) {
                throw invalid("License fields must be strings")
            }
        case "info_plist":
            guard PropertyListSerialization.propertyList(value, isValidFor: .xml) else {
                throw invalid("Info.plist contains an unsupported value")
            }
        case "xcconfig", "pod_target_xcconfig", "user_target_xcconfig":
            guard finite(value) else { throw invalid("Build settings must contain finite numbers") }
            for name in (value as? [String: Any] ?? [:]).keys where !NativeBuildSettings.validKey(name) {
                throw Diagnostic("SP-XCCONFIG-KEY", stage: "resolve", "Invalid xcconfig key: " + name, file: file)
            }
        default: break
        }
    }
}
