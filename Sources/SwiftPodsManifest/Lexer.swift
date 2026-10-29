enum TokenKind: Equatable {
    case identifier(String)
    /// `name:` directly followed by whitespace: a hash key.
    case label(String)
    case string(String)
    case symbol(String)
    case number(String)
    /// `%w[…]` or `%i[…]`.
    case words([String], symbols: Bool)
    case comma, leftParen, rightParen, leftBracket, rightBracket, leftBrace, rightBrace
    case arrow, assign, dot, pipe, semicolon, newline, end
}

struct Token {
    let kind: TokenKind
    let location: SourceLocation
}

/// Tokenizes the declarative subset of Ruby syntax a Podfile may use.
struct Lexer {
    private let scalars: [Unicode.Scalar]
    private let file: String
    private var index = 0
    private var line = 1
    private var column = 1

    init(_ text: String, file: String) {
        scalars = Array(text.unicodeScalars)
        self.file = file
    }

    static func tokens(_ text: String, file: String) throws(ManifestError) -> [Token] {
        var lexer = Lexer(text, file: file)
        var tokens: [Token] = []
        while true {
            let token = try lexer.next()
            tokens.append(token)
            if token.kind == .end { return tokens }
        }
    }

    private var current: Unicode.Scalar? { index < scalars.count ? scalars[index] : nil }
    private func peek(_ offset: Int = 1) -> Unicode.Scalar? {
        index + offset < scalars.count ? scalars[index + offset] : nil
    }
    private var location: SourceLocation { SourceLocation(file: file, line: line, column: column) }

    private mutating func advance() {
        if current == "\n" {
            line += 1
            column = 1
        } else {
            column += 1
        }
        index += 1
    }

    private func error(_ message: String, at location: SourceLocation, hint: String? = nil) -> ManifestError {
        ManifestError(message, at: location, hint: hint)
    }

    private mutating func next() throws(ManifestError) -> Token {
        while let scalar = current {
            if scalar == " " || scalar == "\t" || scalar == "\r" {
                advance()
            } else if scalar == "#" {
                while let next = current, next != "\n" { advance() }
            } else if scalar == "\\" && peek() == "\n" {
                advance()
                advance()
            } else {
                break
            }
        }
        let start = location
        guard let scalar = current else { return Token(kind: .end, location: start) }
        func single(_ kind: TokenKind) -> Token {
            advance()
            return Token(kind: kind, location: start)
        }
        switch scalar {
        case "\n": return single(.newline)
        case ",": return single(.comma)
        case "(": return single(.leftParen)
        case ")": return single(.rightParen)
        case "[": return single(.leftBracket)
        case "]": return single(.rightBracket)
        case "{": return single(.leftBrace)
        case "}": return single(.rightBrace)
        case "|": return single(.pipe)
        case ";": return single(.semicolon)
        case ".": return single(.dot)
        case "=":
            if peek() == ">" {
                advance()
                return single(.arrow)
            }
            if peek() == "b", line == start.line, column == 1 {
                throw error("Block comments are not supported", at: start, hint: "Use # comments")
            }
            return single(.assign)
        case "'", "\"": return Token(kind: .string(try string(quote: scalar)), location: start)
        case ":":
            if let next = peek(), next == "\"" || next == "'" {
                advance()
                return Token(kind: .symbol(try string(quote: next)), location: start)
            }
            if let next = peek(), Self.isIdentifierStart(next) {
                advance()
                return Token(kind: .symbol(identifier()), location: start)
            }
            throw error("Unexpected ':'", at: start)
        case "%": return Token(kind: try words(), location: start)
        default:
            if ("0"..."9").contains(scalar) || scalar == "-" && peek().map({ ("0"..."9").contains($0) }) == true {
                return Token(kind: .number(number()), location: start)
            }
            if Self.isIdentifierStart(scalar) {
                let name = identifier()
                if current == ":" && peek() != ":" {
                    advance()
                    return Token(kind: .label(name), location: start)
                }
                return Token(kind: .identifier(name), location: start)
            }
            throw error("Unexpected character '\(Character(scalar))'", at: start)
        }
    }

    private static func isIdentifierStart(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "_" || scalar.properties.isAlphabetic
    }

    private mutating func identifier() -> String {
        var text = String.UnicodeScalarView()
        while let scalar = current, scalar == "_" || scalar.properties.isAlphabetic || ("0"..."9").contains(scalar) {
            text.append(scalar)
            advance()
        }
        if let scalar = current, scalar == "!" || scalar == "?" {
            text.append(scalar)
            advance()
        }
        return String(text)
    }

    private mutating func number() -> String {
        var text = String.UnicodeScalarView()
        if current == "-" {
            text.append("-")
            advance()
        }
        while let scalar = current, ("0"..."9").contains(scalar) || scalar == "." || scalar == "_" {
            if scalar == ".", peek().map({ !("0"..."9").contains($0) }) ?? true { break }
            if scalar != "_" { text.append(scalar) }
            advance()
        }
        return String(text)
    }

    private mutating func string(quote: Unicode.Scalar) throws(ManifestError) -> String {
        let start = location
        advance()
        var text = String.UnicodeScalarView()
        while true {
            guard let scalar = current else { throw error("Unterminated string", at: start) }
            if scalar == quote {
                advance()
                return String(text)
            }
            if scalar == "\\" {
                advance()
                guard let escaped = current else { throw error("Unterminated string", at: start) }
                if quote == "'" {
                    if escaped != "'" && escaped != "\\" { text.append("\\") }
                    text.append(escaped)
                } else {
                    switch escaped {
                    case "n": text.append("\n")
                    case "t": text.append("\t")
                    case "\"", "\\", "#": text.append(escaped)
                    default:
                        throw error("Unsupported escape sequence '\\\(Character(escaped))'", at: location)
                    }
                }
                advance()
                continue
            }
            if quote == "\"" && scalar == "#" && peek() == "{" {
                throw error(
                    "String interpolation is not supported", at: location,
                    hint: "Podfiles are read as data; write the value, or use single quotes for a literal #{")
            }
            text.append(scalar)
            advance()
        }
    }

    private mutating func words() throws(ManifestError) -> TokenKind {
        let start = location
        advance()
        guard let kind = current, kind == "w" || kind == "i" else {
            throw error("Only %w[…] and %i[…] literals are supported", at: start)
        }
        advance()
        let closing: Unicode.Scalar
        switch current {
        case "[": closing = "]"
        case "(": closing = ")"
        case "{": closing = "}"
        case "<": closing = ">"
        default: throw error("Expected a bracket after %\(Character(kind))", at: location)
        }
        advance()
        var words: [String] = []
        var word = String.UnicodeScalarView()
        while true {
            guard let scalar = current else { throw error("Unterminated %\(Character(kind)) literal", at: start) }
            advance()
            if scalar == closing || scalar.properties.isWhitespace {
                if !word.isEmpty { words.append(String(word)) }
                word = String.UnicodeScalarView()
                if scalar == closing { return .words(words, symbols: kind == "i") }
            } else {
                word.append(scalar)
            }
        }
    }
}
