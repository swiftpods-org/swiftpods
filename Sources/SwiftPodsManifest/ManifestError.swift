/// A position in a Podfile or an included file.
public struct SourceLocation: Sendable, Hashable, Codable, CustomStringConvertible {
    public let file: String
    public let line: Int
    public let column: Int

    public init(file: String, line: Int, column: Int) {
        self.file = file
        self.line = line
        self.column = column
    }

    public var description: String { "\(file):\(line):\(column)" }
}

/// A Podfile that cannot be honoured, with where and, when known, how to fix it.
public struct ManifestError: Error, Sendable, Equatable, CustomStringConvertible {
    public let message: String
    public let location: SourceLocation?
    public let hint: String?
    /// Another declaration involved in a conflict.
    public let related: SourceLocation?

    public init(_ message: String, at location: SourceLocation?, hint: String? = nil, related: SourceLocation? = nil) {
        self.message = message
        self.location = location
        self.hint = hint
        self.related = related
    }

    public var description: String {
        var text = (location.map { "\($0): " } ?? "") + "error: " + message
        if let related { text += "\n\(related): note: also declared here" }
        if let hint { text += "\n  hint: " + hint }
        return text
    }
}
