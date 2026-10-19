import Foundation

/// Interpret version values without changing the original attributes exposed to hooks.
enum NativeSpecValues {
    static func version(_ value: Any) -> String? {
        if let value = value as? String { return value }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
            number.doubleValue.isFinite
        else { return nil }
        return NativeScalarString.number(number)
    }

    static func versions(_ value: Any?) -> [String] {
        guard let value, !(value is NSNull) else { return [] }
        return (value as? [Any] ?? [value]).compactMap(version)
    }

    static func validVersions(_ value: Any) -> Bool {
        (value as? [Any] ?? [value]).allSatisfy { $0 is NSNull || version($0) != nil }
    }

    static func platforms(_ value: Any?) -> [String: Any]? {
        if let values = value as? [String: Any] {
            return values.mapValues { version($0).map { $0 as Any } ?? $0 }
        }
        if let value = value as? String { return [value: NSNull()] }
        return nil
    }

    static func attributes(_ data: [String: Any]) -> [String: Any] {
        var result = data
        if let values = platforms(data["platforms"]) { result["platforms"] = values }
        if let value = data["deployment_target"], let text = version(value) { result["deployment_target"] = text }
        if let dependencies = data["dependencies"] as? [String: Any] {
            result["dependencies"] = dependencies.mapValues { versions($0) }
        }
        for key in ["swift_versions", "swift_version"] where data[key] != nil {
            result[key] = versions(data[key])
        }
        if let values = data["prefix_header_contents"] as? [Any] {
            result["prefix_header_contents"] = NativeScalarString.prefixContents(values)
        }
        if let options = data["scheme"] as? [String: Any] {
            result["scheme"] = NativeSchemeOptions.normalized(options)
        }
        for key in ["xcconfig", "pod_target_xcconfig", "user_target_xcconfig"] {
            if let values = data[key] as? [String: Any] {
                result[key] = values.mapValues { value -> Any in
                    if value is NSNull { return "" }
                    if value is [String: Any] { return NativeScalarString.inspect(value) }
                    if let values = value as? [Any] { return values.map(NativeScalarString.string) }
                    if let number = value as? NSNumber, NativeScalarString.isFloating(number) {
                        return NativeScalarString.number(number)!
                    }
                    return value
                }
            }
        }
        for key in ["ios", "osx", "tvos", "watchos", "visionos"] {
            if let values = data[key] as? [String: Any] { result[key] = attributes(values) }
        }
        return result
    }
}
