import Foundation

#if canImport(FoundationXML)
    import FoundationXML
#endif

/// Changes only references recorded as added by this installation.
enum NativeWorkspace {
    static func update(_ path: URL, references: [String], previous: [String], expected: String? = nil) throws
        -> [String]
    {
        let before = try FileFingerprint.tree(path)
        if let expected, expected != before {
            throw Diagnostic(
                "SP-WORKSPACE-CONFLICT", stage: "integrate", "Workspace changed during installation", file: path.path)
        }
        let data =
            (try? Data(contentsOf: path)) ?? Data("<?xml version=\"1.0\"?><Workspace version=\"1.0\"></Workspace>".utf8)
        let document = try XMLDocument(data: data)
        guard let root = document.rootElement(), root.name == "Workspace" else {
            throw Diagnostic("SP-WORKSPACE", stage: "integrate", "Invalid workspace", file: path.path)
        }
        var owned: [String] = []
        for element in try document.nodes(forXPath: "//FileRef").compactMap({ $0 as? XMLElement }) {
            guard let location = element.attribute(forName: "location")?.stringValue, previous.contains(location) else {
                continue
            }
            if !references.contains(location) { element.detach() } else { owned.append(location) }
        }
        let existing = Set(try document.nodes(forXPath: "//FileRef/@location").compactMap(\.stringValue))
        for reference in references.sorted() where !existing.contains(reference) {
            let node = XMLElement(name: "FileRef")
            node.addAttribute(XMLNode.attribute(withName: "location", stringValue: reference) as! XMLNode)
            root.addChild(node)
            owned.append(reference)
        }
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard try FileFingerprint.tree(path) == before else {
            throw Diagnostic(
                "SP-WORKSPACE-CONFLICT", stage: "integrate", "Workspace changed during integration", file: path.path)
        }
        try document.xmlData(options: .nodePrettyPrint).write(to: path, options: .atomic)
        return owned.sorted()
    }
}

enum NativeWorkspaceReferences {
    static func read(_ path: URL) throws -> [String] {
        let document = try XMLDocument(contentsOf: path)
        return try document.nodes(forXPath: "//FileRef/@location").compactMap(\.stringValue)
    }
}
