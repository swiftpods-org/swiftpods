import Foundation

enum NativeIntegrationSettings {
    static func restore(_ current: [String: Any], record: [String: Any]) throws -> [String: Any] {
        var result = current
        let originals = record["original"] as? [String: Any] ?? [:]
        for (key, written) in record["written"] as? [String: Any] ?? [:] {
            guard let value = result[key], try equal(value, written) else { continue }
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
