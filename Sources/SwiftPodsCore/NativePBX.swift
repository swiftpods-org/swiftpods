import Foundation

/// A native OpenStep project graph. Unknown user project objects are retained.
final class NativePBX {
    var objects: [String: [String: Any]] = [:]
    var root: [String: Any] = [:]
    let url: URL
    private var original: String
    var randomIdentifiers = false
    private var identifiers: [String: String] = [:]
    init(_ url: URL, existing: Bool = false) throws {
        self.url = url
        original = try FileFingerprint.tree(url)
        if existing {
            guard
                let value = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
                    as? [String: Any],
                let objects = value["objects"] as? [String: [String: Any]]
            else { throw Diagnostic("SP-XCODE-PROJECT", stage: "integrate", "Invalid Xcode project", file: url.path) }
            root = value
            self.objects = objects
        }
    }
    @discardableResult func add(_ key: String, _ object: [String: Any]) -> String {
        let id =
            randomIdentifiers
            ? (identifiers[key] ?? UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24).uppercased())
            : Self.identifier(key)
        identifiers[key] = id
        objects[id] = object
        return id
    }
    static func identifier(_ key: String) -> String { String(digest(Data(key.utf8)).prefix(24)).uppercased() }
    func save() throws {
        guard try FileFingerprint.tree(url) == original else {
            throw Diagnostic(
                "SP-XCODE-CONFLICT", stage: "integrate", "Project changed during installation", file: url.path)
        }
        root["objects"] = objects
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data(("// !$*UTF8*$!\n" + Self.serialize(root) + "\n").utf8)
        if (try? Data(contentsOf: url)) != data { try data.writeIfChanged(to: url, options: .atomic) }
        original = try FileFingerprint.tree(url)
    }
    static func serialize(_ value: Any, level: Int = 0) -> String {
        let indentation = String(repeating: "\t", count: level)
        let childIndentation = indentation + "\t"
        if let dictionary = value as? [String: Any] {
            let entries: [String] = dictionary.keys.sorted().map { key in
                let serialized = serialize(dictionary[key]!, level: level + 1)
                return "\(childIndentation)\(quote(key)) = \(serialized);"
            }
            return "{\n\(entries.joined(separator: "\n"))\n\(indentation)}"
        }
        if let array = value as? [Any] {
            let entries: [String] = array.map { element in
                "\(childIndentation)\(serialize(element, level: level + 1)),"
            }
            return "(\n\(entries.joined(separator: "\n"))\n\(indentation))"
        }
        return quote(String(describing: value))
    }
    private static func quote(_ value: String) -> String {
        "\""
            + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r") + "\""
    }
}
