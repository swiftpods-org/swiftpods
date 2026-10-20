import Foundation

/// A native OpenStep project graph. Unknown user project objects are retained.
final class NativePBX {
    var objects: [String: [String: Any]] = [:]
    var root: [String: Any] = [:]
    let url: URL
    private var original: String
    private var document: NativePBXDocument?
    var normalizedConfigurationPaths: [String: String] = [:]
    var randomIdentifiers = false
    private var identifiers: [String: String] = [:]
    var sourceRoot: URL {
        let directory = url.deletingLastPathComponent().deletingLastPathComponent()
        let path = objects[root["rootObject"] as? String ?? ""]?["projectDirPath"] as? String ?? ""
        return URL(fileURLWithPath: path.isEmpty ? "." : path, relativeTo: directory).standardizedFileURL
    }
    init(_ url: URL, existing: Bool = false) throws {
        self.url = url
        original = try FileFingerprint.tree(url)
        if existing {
            let data = try Data(contentsOf: url)
            let decoded = try PropertyListSerialization.propertyList(from: data, format: nil)
            try NativeDictionaryKeys.validate(decoded, file: url.path, stage: "integrate")
            guard
                let value = decoded as? [String: Any],
                let objects = value["objects"] as? [String: [String: Any]]
            else { throw Diagnostic("SP-XCODE-PROJECT", stage: "integrate", "Invalid Xcode project", file: url.path) }
            root = value
            self.objects = objects
            try NativePBXPaths.validateGraph(objects, file: url.path)
            if let text = String(data: data, encoding: .utf8) {
                let start = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if start.hasPrefix("//") || start.hasPrefix("{") { document = try NativePBXDocument(text) }
            }
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
    func isGeneratedConfigurationReference(_ id: String) -> Bool {
        guard objects[id]?["isa"] as? String == "PBXFileReference",
            let path = objects[id]?["path"] as? String
        else { return false }
        return id == Self.identifier("swiftpods:xcconfig:" + path)
            || normalizedConfigurationPaths[id] == path
    }
    static func identifier(_ key: String) -> String { String(digest(Data(key.utf8)).prefix(24)).uppercased() }

    func relativeFileReference(_ path: URL, type: String? = nil) -> [String: Any] {
        var reference: [String: Any] = [
            "isa": "PBXFileReference", "path": relativeFilePath(path), "sourceTree": "SOURCE_ROOT",
        ]
        if let type { reference["lastKnownFileType"] = type }
        return reference
    }

    func relativeFilePath(_ path: URL) -> String {
        NativeBuildSetting.literal(NativePath.relativePath(of: path, to: sourceRoot))
    }

    func buildSettingPath(_ path: URL) -> String {
        let relative = NativePath.relativePath(of: path, to: sourceRoot)
        return relative == "." ? "$(SRCROOT)" : "$(SRCROOT)/" + NativeBuildSetting.scalarLiteral(relative)
    }

    /// Recognize both portable references and the absolute references written by earlier releases.
    func ownedFileKey(_ id: String, prefix: String) -> String? {
        guard objects[id]?["isa"] as? String == "PBXFileReference", let path = objects[id]?["path"] as? String else {
            return nil
        }
        return [path, NativeBuildSetting.decodedLiteral(path)].map { prefix + $0 }.first { Self.identifier($0) == id }
    }

    /// Drop obsolete managed objects, retaining anything still used outside navigation groups.
    func removeUnreferencedObjects(_ candidates: Set<String>) {
        func references(_ value: Any) -> Set<String> {
            if let id = value as? String { return candidates.contains(id) ? [id] : [] }
            if let values = value as? [Any] { return values.reduce(into: []) { $0.formUnion(references($1)) } }
            if let values = value as? [String: Any] { return references(Array(values.values)) }
            return []
        }
        var remaining = candidates.intersection(objects.keys)
        while !remaining.isEmpty {
            let used = objects.values.reduce(into: references(root["rootObject"] ?? "")) { used, object in
                if !["PBXGroup", "PBXVariantGroup"].contains(object["isa"] as? String ?? "") {
                    used.formUnion(references(object))
                }
            }
            let unused = remaining.subtracting(used)
            guard !unused.isEmpty else { return }
            for id in unused { objects.removeValue(forKey: id) }
            for id in Array(objects.keys) {
                if let children = objects[id]?["children"] as? [String] {
                    objects[id]?["children"] = children.filter { !unused.contains($0) }
                }
            }
            remaining.subtract(unused)
        }
    }

    func save() throws {
        try NativePBXPaths.validateGraph(objects, file: url.path)
        guard try FileFingerprint.tree(url) == original else {
            throw Diagnostic(
                "SP-XCODE-CONFLICT", stage: "integrate", "Project changed during installation", file: url.path)
        }
        root["objects"] = objects
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = document?.updating(root) ?? ("// !$*UTF8*$!\n" + NativePBXFormatting.value(root) + "\n")
        let data = Data(text.utf8)
        let decoded = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard Self.serialize(decoded) == Self.serialize(root) else {
            throw Diagnostic("SP-XCODE-PROJECT", stage: "integrate", "Project edit changed its graph", file: url.path)
        }
        if (try? Data(contentsOf: url)) != data { try data.writeIfChanged(to: url, options: .atomic) }
        document = try NativePBXDocument(text)
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
        return quote(NativeScalarString.string(value))
    }
    private static func quote(_ value: String) -> String {
        "\""
            + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r") + "\""
    }
}
