import Foundation

enum NativeSpecSchema {
    static func validate(_ data: [String: Any], path: String? = nil) throws {
        let path = path ?? data["name"] as? String
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
        for key in data.keys.sorted() {
            let value = data[key]!
            if value is NSNull { continue }
            if ["ios", "osx", "tvos", "watchos", "visionos"].contains(key) {
                guard let platform = value as? [String: Any] else {
                    throw Diagnostic("SP-SPEC-ATTRIBUTE-TYPE", stage: "resolve", key + " must be an object")
                }
                try validate(platform, path: path)
            } else if ["subspecs", "testspecs", "appspecs"].contains(key) {
                guard let children = value as? [[String: Any]] else {
                    throw Diagnostic(
                        "SP-SPEC-ATTRIBUTE-TYPE", stage: "resolve", key + " must contain specification objects")
                }
                guard children.allSatisfy({ ($0["name"] as? String).map { NativePodName.isValid($0) } == true }) else {
                    throw Diagnostic("SP-SPEC-ATTRIBUTE-TYPE", stage: "resolve", key + " requires named specifications")
                }
                for child in children {
                    let name = child["name"] as! String
                    try validate(child, path: path.map { $0 + "/" + name } ?? name)
                }
            } else if key == "deployment_target" {
                guard NativeSpecValues.version(value) != nil else {
                    throw Diagnostic(
                        "SP-SPEC-ATTRIBUTE-TYPE", stage: "resolve", "Invalid deployment target", file: path)
                }
            } else if ["_spec_url", "configuration_pod_whitelist"].contains(key) {
                continue
            } else {
                let canonical = aliases[key] ?? key
                try NativeSpecStructure.validate(canonical, value: value, file: path)
                if canonical == "platforms" {
                    guard let values = NativeSpecValues.platforms(value),
                        values.values.allSatisfy({ $0 is NSNull || NativeSpecValues.version($0) != nil })
                    else {
                        throw Diagnostic("SP-SPEC-ATTRIBUTE-TYPE", stage: "resolve", "Invalid platforms", file: path)
                    }
                    continue
                }
                if canonical == "swift_versions", value is [Any] || key == "swift_version" {
                    guard NativeSpecValues.validVersions(value) else {
                        throw Diagnostic(
                            "SP-SPEC-ATTRIBUTE-TYPE", stage: "resolve", "Invalid Swift versions", file: path)
                    }
                    continue
                }
                if [
                    "dependencies", "source", "pod_target_xcconfig", "user_target_xcconfig", "xcconfig",
                    "resource_bundles", "info_plist",
                ].contains(canonical) {
                    guard let values = value as? [String: Any] else {
                        throw Diagnostic(
                            "SP-SPEC-ATTRIBUTE-TYPE", stage: "resolve", key + " must be an object", file: path)
                    }
                    if canonical == "dependencies", !values.values.allSatisfy(NativeSpecValues.validVersions) {
                        throw Diagnostic(
                            "SP-SPEC-ATTRIBUTE-TYPE", stage: "resolve", "Invalid dependency requirements", file: path)
                    }
                    if canonical == "dependencies" {
                        for requirements in values.values {
                            _ = try PodRequirement(NativeSpecValues.versions(requirements))
                        }
                    }
                    if canonical == "source" { try NativeSourceOptions.validate(values, file: path ?? "") }
                    if canonical == "resource_bundles",
                        !values.values.allSatisfy({ patterns in
                            (patterns as? [Any] ?? [patterns]).allSatisfy { $0 is String || $0 is NSNull }
                        })
                    {
                        throw Diagnostic(
                            "SP-SPEC-ATTRIBUTE-TYPE", stage: "resolve", "Resource bundles require string patterns",
                            file: path)
                    }
                }
                guard let allowed = NativeAttributeContract.types[canonical] else {
                    throw Diagnostic("SP-SPEC-ATTRIBUTE", stage: "resolve", "Unknown podspec attribute: " + key)
                }
                guard allowed.contains(kind(value)) else {
                    throw Diagnostic(
                        "SP-SPEC-ATTRIBUTE-TYPE", stage: "resolve", "Invalid type for " + key + ": " + kind(value),
                        file: path)
                }
                if canonical == "test_type", let name = value as? String, NativeTestType(rawValue: name) == nil {
                    throw Diagnostic("SP-TEST-TYPE", stage: "resolve", "Unknown test type " + name, file: path)
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
