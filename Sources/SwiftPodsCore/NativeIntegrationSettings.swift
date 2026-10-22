import Foundation

enum NativeIntegrationSettings {
    static func projectPaths(_ settings: [String: Any]) -> Set<String> {
        var keys = Array(settings.keys)
        keys += Array((settings["_base_configurations"] as? [String: String] ?? [:]).keys)
        keys += Array((settings["_support_configurations"] as? [String: String] ?? [:]).keys)
        let configurations = keys.compactMap { key -> String? in
            guard let separator = key.range(of: ":", options: .backwards) else { return nil }
            return String(key[..<separator.lowerBound])
        }
        return Set(configurations)
            .union((settings["_swift_packages"] as? [String: Any] ?? [:]).keys)
            .union((settings["_project_attributes"] as? [String: Any] ?? [:]).keys)
    }

    static func removingProject(_ path: String, from settings: [String: Any]) -> [String: Any] {
        var result = settings.filter { !$0.key.hasPrefix(path + ":") }
        for key in [
            "_base_configurations", "_support_configurations", "_swift_packages", "_project_attributes",
            "_project_paths",
        ] {
            if let values = result[key] as? [String: Any] {
                result[key] = values.filter { $0.key != path && !$0.key.hasPrefix(path + ":") }
            }
        }
        return result
    }

    static func restore(_ current: [String: Any], record: [String: Any]) throws -> [String: Any] {
        var result = current
        let originals = record["original"] as? [String: Any] ?? [:]
        for (key, written) in record["written"] as? [String: Any] ?? [:] {
            guard let value = result[key] else { continue }
            guard try equal(value, written) else {
                if let variable = NativeSwiftPackageCompileSettings.references[key],
                    nativeStrings(written).contains("$(" + variable + ")"),
                    !nativeStrings(originals[key]).contains("$(" + variable + ")")
                {
                    result[key] = NativeSwiftPackageCompileSettings.removingReferences(value, key: key)
                }
                continue
            }
            if let original = originals[key], !(original is NSNull) {
                result[key] = original
            } else {
                result.removeValue(forKey: key)
            }
        }
        return result
    }
    static func record(before: [String: Any], after: [String: Any]) throws -> [String: Any] {
        var original: [String: Any] = [:]
        var written: [String: Any] = [:]
        for (key, value) in after {
            if let old = before[key], try equal(old, value) { continue }
            original[key] = before[key] ?? NSNull()
            written[key] = value
        }
        return ["original": original, "written": written]
    }
    private static func equal(_ lhs: Any, _ rhs: Any) throws -> Bool {
        try jsonData(["value": lhs]) == jsonData(["value": rhs])
    }
}
