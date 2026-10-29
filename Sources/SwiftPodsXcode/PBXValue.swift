import Foundation

/// A value of an OpenStep property list as Xcode writes `project.pbxproj`.
public indirect enum PBXValue: Sendable, Hashable {
    case string(String)
    case array([PBXValue])
    case dictionary([String: PBXValue])
    case data(Data)

    public var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var array: [PBXValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var dictionary: [String: PBXValue]? {
        if case .dictionary(let value) = self { return value }
        return nil
    }

    /// The strings of an array value; nil when the value is not an array of strings.
    public var strings: [String]? {
        guard let array else { return nil }
        let values = array.compactMap(\.string)
        return values.count == array.count ? values : nil
    }

    init(propertyList value: Any) throws(XcodeError) {
        switch value {
        case let string as String: self = .string(string)
        case let array as [Any]:
            var values: [PBXValue] = []
            for element in array { values.append(try PBXValue(propertyList: element)) }
            self = .array(values)
        case let dictionary as [String: Any]:
            var values: [String: PBXValue] = [:]
            for (key, element) in dictionary { values[key] = try PBXValue(propertyList: element) }
            self = .dictionary(values)
        case let data as Data: self = .data(data)
        default: throw XcodeError("Unsupported property list value \(type(of: value))")
        }
    }
}

extension PBXValue: ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: PBXValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, PBXValue)...) {
        self = .dictionary(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

/// An object in the `objects` table, keyed by property name.
public typealias PBXObject = [String: PBXValue]

extension Dictionary where Key == String, Value == PBXValue {
    public var isa: String? { self["isa"]?.string }
    public func string(_ key: String) -> String? { self[key]?.string }
    public func strings(_ key: String) -> [String] { self[key]?.strings ?? [] }
}

public struct XcodeError: Error, Sendable, Equatable, CustomStringConvertible {
    public let message: String
    public let file: String?

    public init(_ message: String, file: String? = nil) {
        self.message = message
        self.file = file
    }

    public var description: String { (file.map { $0 + ": " } ?? "") + "error: " + message }
}

/// Conventional OpenStep spelling for new records; existing text belongs to the document.
enum PBXFormatting {
    static func atom(_ value: String) -> String {
        let safe =
            !value.isEmpty
            && value.utf8.allSatisfy {
                (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
                    || [95, 46, 47, 36].contains($0)
            }
        if safe && !value.contains("//") && !value.contains("/*") { return value }
        return quote(value)
    }

    static func quote(_ value: String) -> String {
        "\""
            + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t") + "\""
    }

    static func value(_ value: PBXValue, indent: String = "") -> String {
        switch value {
        case .string(let string): return atom(string)
        case .data(let data): return "<" + data.map { String(format: "%02x", $0) }.joined() + ">"
        case .array(let array):
            if array.isEmpty { return "()" }
            return "(\n" + array.map { indent + "\t" + self.value($0, indent: indent + "\t") + ",\n" }.joined()
                + indent + ")"
        case .dictionary(let dictionary):
            if dictionary.isEmpty { return "{}" }
            let keys = dictionary.keys.sorted {
                if $0 == "isa" { return $1 != "isa" }
                if $1 == "isa" { return false }
                return $0 < $1
            }
            if ["PBXBuildFile", "PBXFileReference"].contains(dictionary.isa ?? ""),
                dictionary.values.allSatisfy({ $0.array == nil && $0.dictionary == nil })
            {
                return "{" + keys.map { atom($0) + " = " + self.value(dictionary[$0]!, indent: indent) + "; " }.joined()
                    + "}"
            }
            return "{\n"
                + keys.map {
                    indent + "\t" + atom($0) + " = " + self.value(dictionary[$0]!, indent: indent + "\t") + ";\n"
                }.joined() + indent + "}"
        }
    }
}
