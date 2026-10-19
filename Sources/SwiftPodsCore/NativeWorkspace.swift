import Foundation

#if canImport(FoundationXML)
    import FoundationXML
#endif

/// Changes only references recorded as added by this installation.
enum NativeWorkspace {
    struct Update {
        let path: URL
        let before: String
        let data: Data
        let owned: [String]

        func save() throws {
            guard try FileFingerprint.tree(path) == before else {
                throw Diagnostic(
                    "SP-WORKSPACE-CONFLICT", stage: "integrate", "Workspace changed during integration", file: path.path
                )
            }
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.writeIfChanged(to: path, options: .atomic)
        }
    }

    static func update(_ path: URL, references: [String], previous: [String], expected: String? = nil) throws
        -> [String]
    {
        let update = try prepare(path, references: references, previous: previous, expected: expected)
        try update.save()
        return update.owned
    }

    /// Parse and reconcile before callers save any other managed project.
    static func prepare(_ path: URL, references: [String], previous: [String], expected: String? = nil) throws
        -> Update
    {
        let before = try FileFingerprint.tree(path)
        if let expected, expected != before {
            throw Diagnostic(
                "SP-WORKSPACE-CONFLICT", stage: "integrate", "Workspace changed during installation", file: path.path)
        }
        let data =
            try FileManager.default.fileExists(atPath: path.path)
            ? Data(contentsOf: path) : Data("<?xml version=\"1.0\"?><Workspace version=\"1.0\"></Workspace>".utf8)
        let document = try XMLDocument(data: data)
        guard let root = document.rootElement(), root.name == "Workspace" else {
            throw Diagnostic("SP-WORKSPACE", stage: "integrate", "Invalid workspace", file: path.path)
        }
        let container = path.deletingLastPathComponent().deletingLastPathComponent()
        let requested = Set(references.compactMap { resolve($0, parent: container, container: container) })
        var owned: [String] = []
        var remaining = Set(previous)
        // This writer only adds direct children. Legacy receipts contain raw
        // locations, so they must never claim references inside user groups.
        for element in root.children?.compactMap({ $0 as? XMLElement }) ?? [] where element.name == "FileRef" {
            guard let location = element.attribute(forName: "location")?.stringValue,
                remaining.remove(location) != nil
            else {
                continue
            }
            if let identity = resolve(location, parent: container, container: container), requested.contains(identity) {
                owned.append(location)
            } else {
                element.detach()
            }
        }
        var existing = Set(
            try document.nodes(forXPath: "//FileRef").compactMap { node -> String? in
                guard let element = node as? XMLElement,
                    let location = element.attribute(forName: "location")?.stringValue
                else { return nil }
                var groups: [XMLElement] = []
                var ancestor = element.parent
                while let node = ancestor {
                    if let group = node as? XMLElement, group.name == "Group" { groups.append(group) }
                    ancestor = node.parent
                }
                var parent = container
                for group in groups.reversed() {
                    guard let location = group.attribute(forName: "location")?.stringValue else { continue }
                    guard let resolved = resolve(location, parent: parent, container: container) else { return nil }
                    parent = URL(fileURLWithPath: resolved)
                }
                return resolve(location, parent: parent, container: container)
            })
        for reference in references.sorted() {
            guard let identity = resolve(reference, parent: container, container: container),
                existing.insert(identity).inserted
            else { continue }
            let node = XMLElement(name: "FileRef")
            node.addAttribute(XMLNode.attribute(withName: "location", stringValue: reference) as! XMLNode)
            root.addChild(node)
            owned.append(reference)
        }
        return Update(
            path: path, before: before, data: try xmlData(document), owned: owned.sorted())
    }

    /// Foundation emits literal attribute whitespace, which XML readers normalize to spaces.
    /// Re-encode only attribute values, preserving comments, CDATA and processing instructions.
    private static func xmlData(_ document: XMLDocument) throws -> Data {
        document.characterEncoding = "UTF-8"
        var text = document.xmlString(options: .nodePrettyPrint)
        let tokens = try NSRegularExpression(
            pattern:
                #"<!--.*?-->|<!\[CDATA\[.*?\]\]>|<\?.*?\?>|<!DOCTYPE(?:[^\"'\[\]>]|\"[^\"]*\"|'[^']*'|\[(?:[^\"'\]]|\"[^\"]*\"|'[^']*')*\])*>|<(?:[^\"'<>]|\"[^\"]*\"|'[^']*')*>"#,
            options: .dotMatchesLineSeparators)
        let attributes = try NSRegularExpression(pattern: #"([\"'])(.*?)\1"#, options: .dotMatchesLineSeparators)
        for match in tokens.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: text) else { continue }
            var token = String(text[range])
            guard !token.hasPrefix("<!"), !token.hasPrefix("<?") else { continue }
            for attribute in attributes.matches(in: token, range: NSRange(token.startIndex..., in: token)).reversed() {
                guard let value = Range(attribute.range(at: 2), in: token) else { continue }
                let escaped = token[value].replacingOccurrences(of: "\t", with: "&#9;")
                    .replacingOccurrences(of: "\n", with: "&#10;").replacingOccurrences(of: "\r", with: "&#13;")
                token.replaceSubrange(value, with: escaped)
            }
            text.replaceSubrange(range, with: token)
        }
        return Data(text.utf8)
    }

    private static func resolve(_ location: String, parent: URL, container: URL) -> String? {
        let scalars = location.unicodeScalars
        guard let separator = scalars.firstIndex(of: ":") else { return nil }
        let value = String(scalars[scalars.index(after: separator)...])
        let path: URL
        switch String(scalars[..<separator]) {
        case "group": path = parent.appendingPathComponent(value)
        case "container": path = container.appendingPathComponent(value)
        case "absolute": path = URL(fileURLWithPath: value)
        default: return nil
        }
        return path.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
