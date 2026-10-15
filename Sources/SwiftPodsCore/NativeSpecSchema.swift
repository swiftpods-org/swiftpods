import Foundation

enum NativeSpecSchema {
    static func validate(_ data: [String: Any]) throws {
        func kind(_ value: Any) -> String {
            if value is NSNull { return "NilClass" }
            if let number = value as? NSNumber {
                return CFGetTypeID(number) == CFBooleanGetTypeID()
                    ? (number.boolValue ? "TrueClass" : "FalseClass") : "Numeric"
            }
            if value is String { return "String" }
            if value is [Any] { return "Array" }
            if value is [String: Any] { return "Hash" }
            return "Unknown"
        }
        let aliases = [
            "author": "authors", "swift_version": "swift_versions", "default_subspec": "default_subspecs",
            "script_phase": "script_phases",
        ]
        for (key, value) in data {
            if value is NSNull { continue }
            if ["ios", "osx", "tvos", "watchos", "visionos"].contains(key) {
                guard let platform = value as? [String: Any] else {
                    throw Diagnostic("SP-SPEC-ATTRIBUTE-TYPE", stage: "resolve", key + " must be an object")
                }
                try validate(platform)
            } else if ["subspecs", "testspecs", "appspecs"].contains(key) {
                guard let children = value as? [[String: Any]] else {
                    throw Diagnostic(
                        "SP-SPEC-ATTRIBUTE-TYPE", stage: "resolve", key + " must contain specification objects")
                }
                guard children.allSatisfy({ $0["name"] is String }) else {
                    throw Diagnostic("SP-SPEC-ATTRIBUTE-TYPE", stage: "resolve", key + " requires named specifications")
                }
            } else if ["deployment_target", "test_type", "_spec_url", "configuration_pod_whitelist"].contains(key) {
                continue
            } else {
                let canonical = aliases[key] ?? key
                guard let allowed = NativeAttributeContract.types[canonical] else {
                    throw Diagnostic("SP-SPEC-ATTRIBUTE", stage: "resolve", "Unknown podspec attribute: " + key)
                }
                guard allowed.contains(kind(value)) else {
                    throw Diagnostic(
                        "SP-SPEC-ATTRIBUTE-TYPE", stage: "resolve", "Invalid type for " + key + ": " + kind(value))
                }
                if NativeAttributeContract.arrays.contains(canonical), let array = value as? [Any],
                    allowed == Set(["Array", "String"])
                {
                    guard array.allSatisfy({ $0 is String || $0 is NSNull }) else {
                        throw Diagnostic("SP-SPEC-ATTRIBUTE-TYPE", stage: "resolve", key + " requires string values")
                    }
                }
            }
        }
    }
}
