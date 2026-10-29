/// Typed access to a statement's arguments; unread options are errors.
struct Arguments {
    let statement: Statement
    private var options: [(key: String, node: Node, keyLocation: SourceLocation)] = []
    private(set) var settings: [(key: String, value: Node)] = []

    /// String keys (`'KEY' => value`) are collected separately only when `allowsStringKeys`.
    init(_ statement: Statement, allowsStringKeys: Bool = false) throws(ManifestError) {
        self.statement = statement
        var seen: [String: SourceLocation] = [:]
        for (key, value) in statement.options {
            switch key.value {
            case .symbol(let name):
                if let previous = seen[name] {
                    throw ManifestError("Option `\(name)` is given twice", at: key.location, related: previous)
                }
                seen[name] = key.location
                options.append((name, value, key.location))
            case .string(let name) where allowsStringKeys:
                settings.append((name, value))
            default:
                throw ManifestError(
                    "`\(statement.name)` option keys must be symbols, found \(key.kindName)", at: key.location)
            }
        }
    }

    var location: SourceLocation { statement.location }
    var positional: [Node] { statement.positional }

    mutating func take(_ name: String) -> Node? {
        guard let index = options.firstIndex(where: { $0.key == name }) else { return nil }
        return options.remove(at: index).node
    }

    func keyLocation(_ name: String) -> SourceLocation? { options.first { $0.key == name }?.keyLocation }

    /// Takes every option not read yet, in the order written.
    mutating func takeAll() -> [(key: String, node: Node, keyLocation: SourceLocation)] {
        defer { options = [] }
        return options
    }

    func finish(allowed: [String]) throws(ManifestError) {
        if let unknown = options.first {
            throw ManifestError(
                "`\(statement.name)` has no option `\(unknown.key)`", at: unknown.keyLocation,
                hint: allowed.isEmpty ? nil : "Options: " + allowed.joined(separator: ", "))
        }
    }

    func requireNoBlock() throws(ManifestError) {
        if statement.block != nil {
            throw ManifestError("`\(statement.name)` does not take a block", at: statement.location)
        }
    }

    func positionalCount(_ range: ClosedRange<Int>, usage: String) throws(ManifestError) {
        guard range.contains(positional.count) else {
            throw ManifestError("Usage: \(usage)", at: positional.dropFirst(range.upperBound).first?.location ?? location)
        }
    }
}

enum Convert {
    static func string(_ node: Node, _ what: String) throws(ManifestError) -> String {
        if case .string(let text) = node.value { return text }
        throw ManifestError("\(what) must be a string, found \(node.kindName)", at: node.location)
    }

    /// Versions may be written as numbers; the spelling is kept.
    static func versionText(_ node: Node, _ what: String) throws(ManifestError) -> String {
        switch node.value {
        case .string(let text), .number(let text): return text
        default: throw ManifestError("\(what) must be a version string, found \(node.kindName)", at: node.location)
        }
    }

    static func name(_ node: Node, _ what: String) throws(ManifestError) -> String {
        switch node.value {
        case .string(let text), .symbol(let text): return text
        default: throw ManifestError("\(what) must be a symbol or string, found \(node.kindName)", at: node.location)
        }
    }

    static func bool(_ node: Node, _ what: String) throws(ManifestError) -> Bool {
        if case .bool(let value) = node.value { return value }
        throw ManifestError("\(what) must be true or false, found \(node.kindName)", at: node.location)
    }

    /// A string or an array of strings.
    static func strings(_ node: Node, _ what: String) throws(ManifestError) -> [String] {
        switch node.value {
        case .string(let text): return [text]
        case .array(let elements): return try elements.map { (element) throws(ManifestError) in try string(element, what + " entries") }
        default: throw ManifestError("\(what) must be a string or an array of strings, found \(node.kindName)", at: node.location)
        }
    }

    static func nonEmpty(_ value: String, _ what: String, at location: SourceLocation) throws(ManifestError) -> String {
        guard !value.isEmpty else { throw ManifestError("\(what) must not be empty", at: location) }
        return value
    }
}
