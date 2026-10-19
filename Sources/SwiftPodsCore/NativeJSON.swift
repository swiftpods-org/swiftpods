import Foundation

/// Preserve integral floating values across the Ruby protocol and saved specs.
/// Foundation otherwise serializes 1.0 as 1, changing its selector and Ruby type.
enum NativeJSON {
    static func decode(_ data: Data, file: String? = nil) throws -> Any {
        let value = try JSONSerialization.jsonObject(with: data)
        try NativeDictionaryKeys.validate(value, file: file)
        return value
    }

    static func data(_ value: Any, pretty: Bool = true) throws -> Data {
        try NativeDictionaryKeys.validate(value, stage: "serialize")
        func hasFloating(_ value: Any, depth: Int = 0) throws -> Bool {
            guard depth <= 512 else { throw invalid("JSON exceeds the nesting limit") }
            if let value = value as? NSNumber { return NativeScalarString.isFloating(value) }
            if let values = value as? [Any] {
                return try values.contains { try hasFloating($0, depth: depth + 1) }
            }
            if let values = value as? [String: Any] {
                return try values.values.contains { try hasFloating($0, depth: depth + 1) }
            }
            return false
        }
        var options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
        if pretty { options.insert(.prettyPrinted) }
        // Keep existing byte identities for inputs with no floating values.
        guard try hasFloating(value) else { return try JSONSerialization.data(withJSONObject: value, options: options) }
        func encode(_ value: Any, depth: Int = 0) throws -> String {
            guard depth <= 512 else { throw invalid("JSON exceeds the nesting limit") }
            if let number = value as? NSNumber, NativeScalarString.isFloating(number) {
                guard number.doubleValue.isFinite else { throw invalid("JSON numbers must be finite") }
                return String(number.doubleValue)
            }
            let indent = String(repeating: "  ", count: depth)
            let childIndent = indent + "  "
            if let values = value as? [Any] {
                let entries = try values.map { try encode($0, depth: depth + 1) }
                return pretty && !entries.isEmpty
                    ? "[\n" + childIndent + entries.joined(separator: ",\n" + childIndent) + "\n" + indent + "]"
                    : "[" + entries.joined(separator: ",") + "]"
            }
            if let values = value as? [String: Any] {
                let entries = try values.sorted(by: { $0.key < $1.key }).map {
                    try encode($0.key, depth: depth + 1) + (pretty ? " : " : ":") + encode($0.value, depth: depth + 1)
                }
                return pretty && !entries.isEmpty
                    ? "{\n" + childIndent + entries.joined(separator: ",\n" + childIndent) + "\n" + indent + "}"
                    : "{" + entries.joined(separator: ",") + "}"
            }
            return String(
                decoding: try JSONSerialization.data(
                    withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes]), as: UTF8.self)
        }
        return Data(try encode(value).utf8)
    }

    private static func invalid(_ message: String) -> Diagnostic {
        Diagnostic("SP-JSON-VALUE", stage: "serialize", message)
    }
}
