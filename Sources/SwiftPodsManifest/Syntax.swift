/// A literal value with the place it was written.
struct Node {
    indirect enum Value {
        case string(String)
        case symbol(String)
        /// Kept as written, so `15.0` stays `15.0`.
        case number(String)
        case bool(Bool)
        case null
        case array([Node])
        case hash([(key: Node, value: Node)])
    }

    let value: Value
    let location: SourceLocation

    var kindName: String {
        switch value {
        case .string: "a string"
        case .symbol: "a symbol"
        case .number: "a number"
        case .bool: "a boolean"
        case .null: "nil"
        case .array: "an array"
        case .hash: "a hash"
        }
    }
}

/// `name positional..., key: value... do ... end`
struct Statement {
    let name: String
    let location: SourceLocation
    let positional: [Node]
    let options: [(key: Node, value: Node)]
    let block: [Statement]?
}

/// Builds statements from tokens. Anything that would need evaluation is an error.
struct Parser {
    private static let maximumNestingDepth = 128
    private static let maximumTokenUnits = 200_000
    private static let maximumSyntaxNodes = 50_000

    final class Budget {
        fileprivate var tokenUnits = 0
        fileprivate var syntaxNodes = 0

        func consumeTokenUnits(_ count: Int, at location: SourceLocation) throws(ManifestError) {
            try requireTokenCapacity(count, at: location)
            tokenUnits += count
        }

        func requireTokenCapacity(_ count: Int, at location: SourceLocation) throws(ManifestError) {
            guard count >= 0, tokenUnits <= Parser.maximumTokenUnits - count else {
                throw ManifestError(
                    "Podfile exceeds the parser token budget of \(Parser.maximumTokenUnits)", at: location)
            }
        }

        fileprivate func consumeSyntaxNodes(_ count: Int, at location: SourceLocation) throws(ManifestError) {
            guard count >= 0, syntaxNodes <= Parser.maximumSyntaxNodes - count else {
                throw ManifestError(
                    "Podfile exceeds the syntax node budget of \(Parser.maximumSyntaxNodes)", at: location)
            }
            syntaxNodes += count
        }
    }

    private let tokens: [Token]
    private let budget: Budget
    private var index = 0

    private static let unsupported: [String: (String, String)] = [
        "def": ("Methods are not supported", "Use `group :name do … end` and `use :name`"),
        "if": ("Conditionals are not supported", "Declare separate groups and `use` the one each target needs"),
        "unless": ("Conditionals are not supported", "Declare separate groups and `use` the one each target needs"),
        "case": ("Conditionals are not supported", "Declare separate groups and `use` the one each target needs"),
        "while": ("Loops are not supported", "List the declarations explicitly"),
        "until": ("Loops are not supported", "List the declarations explicitly"),
        "for": ("Loops are not supported", "List the declarations explicitly"),
        "require": ("`require` is not supported", "Use `include 'path.podfile'`"),
        "require_relative": ("`require_relative` is not supported", "Use `include 'path.podfile'`"),
        "load": ("`load` is not supported", "Use `include 'path.podfile'`"),
        "eval": ("Code evaluation is not supported", "Write the declarations directly"),
    ]

    /// Their blocks hold Ruby code, so they are rejected before it is parsed.
    private static let hooks: Set = ["pre_install", "post_install", "pre_integrate", "post_integrate"]

    init(_ tokens: [Token], budget: Budget) {
        self.tokens = tokens
        self.budget = budget
    }

    static func statements(_ text: String, file: String) throws(ManifestError) -> [Statement] {
        try statements(text, file: file, budget: Budget())
    }

    static func statements(_ text: String, file: String, budget: Budget) throws(ManifestError) -> [Statement] {
        var parser = Parser(try Lexer.tokens(text, file: file, budget: budget), budget: budget)
        return try parser.statements(untilEnd: false, depth: 0)
    }

    private var token: Token { tokens[index] }
    private var kind: TokenKind { token.kind }

    private mutating func advance() { if index < tokens.count - 1 { index += 1 } }

    private mutating func skipNewlines() {
        while kind == .newline || kind == .semicolon { advance() }
    }

    private func error(_ message: String, hint: String? = nil) -> ManifestError {
        ManifestError(message, at: token.location, hint: hint)
    }

    private func checkNesting(_ depth: Int, at location: SourceLocation) throws(ManifestError) {
        guard depth <= Self.maximumNestingDepth else {
            throw ManifestError(
                "Podfile syntax is nested more than \(Self.maximumNestingDepth) levels", at: location)
        }
    }

    private mutating func consumeNodes(_ count: Int = 1, at location: SourceLocation) throws(ManifestError) {
        try budget.consumeSyntaxNodes(count, at: location)
    }

    private mutating func node(_ value: Node.Value, at location: SourceLocation, cost: Int = 1) throws(ManifestError) -> Node {
        try consumeNodes(cost, at: location)
        return Node(value: value, location: location)
    }

    private func describe(_ kind: TokenKind) -> String {
        switch kind {
        case .identifier(let name): "'\(name)'"
        case .label(let name): "'\(name):'"
        case .string: "a string"
        case .symbol(let name): "':\(name)'"
        case .number(let text): "'\(text)'"
        case .words: "a word list"
        case .comma: "','"
        case .leftParen: "'('"
        case .rightParen: "')'"
        case .leftBracket: "'['"
        case .rightBracket: "']'"
        case .leftBrace: "'{'"
        case .rightBrace: "'}'"
        case .arrow: "'=>'"
        case .assign: "'='"
        case .dot: "'.'"
        case .pipe: "'|'"
        case .semicolon: "';'"
        case .newline: "end of line"
        case .end: "end of file"
        }
    }

    private mutating func statements(untilEnd: Bool, depth: Int) throws(ManifestError) -> [Statement] {
        try checkNesting(depth, at: token.location)
        var result: [Statement] = []
        while true {
            skipNewlines()
            switch kind {
            case .end:
                if untilEnd { throw error("Missing `end` for this block") }
                return result
            case .identifier("end"):
                if !untilEnd { throw error("Unexpected `end`") }
                advance()
                return result
            case .identifier(let name):
                result.append(try statement(name, depth: depth))
            default:
                throw error("Expected a declaration, found \(describe(kind))")
            }
        }
    }

    private mutating func statement(_ name: String, depth: Int) throws(ManifestError) -> Statement {
        let location = token.location
        try consumeNodes(at: location)
        if let (message, hint) = Self.unsupported[name] {
            throw ManifestError(message, at: location, hint: "Podfiles are read as data, not executed. " + hint)
        }
        if Self.hooks.contains(name) {
            throw ManifestError(
                "Install hooks are not supported", at: location,
                hint: "Declare build settings with `settings` and run scripts with `script_phase`")
        }
        advance()
        switch kind {
        case .assign:
            throw ManifestError(
                "Variables are not supported", at: location,
                hint: "Podfiles are read as data, not executed. Write the value where it is used, or share declarations with `group`")
        case .dot:
            throw ManifestError("Method calls are not supported", at: location)
        default: break
        }
        var positional: [Node] = []
        var options: [(key: Node, value: Node)] = []
        let parenthesized = kind == .leftParen
        if parenthesized {
            try checkNesting(depth + 1, at: token.location)
            advance()
            try arguments(&positional, &options, closing: .rightParen, depth: depth + 1)
            advance()
        } else if startsArgument {
            try arguments(&positional, &options, closing: nil, depth: depth)
        }
        var block: [Statement]?
        if kind == .identifier("do") {
            try checkNesting(depth + 1, at: token.location)
            advance()
            if kind == .pipe {
                throw error("Block parameters are not supported", hint: "Podfiles are read as data, not executed")
            }
            block = try statements(untilEnd: true, depth: depth + 1)
        } else if kind == .leftBrace {
            throw error("Use `do … end` for blocks")
        }
        switch kind {
        case .newline, .semicolon, .end, .identifier("end"): break
        case .dot: throw error("Method calls are not supported")
        default: throw error("Unexpected \(describe(kind)) after `\(name)`")
        }
        return Statement(name: name, location: location, positional: positional, options: options, block: block)
    }

    private var startsArgument: Bool {
        switch kind {
        case .string, .symbol, .number, .words, .label, .leftBracket, .leftBrace: true
        case .identifier(let name): name != "do" && name != "end"
        default: false
        }
    }

    private mutating func arguments(
        _ positional: inout [Node], _ options: inout [(key: Node, value: Node)], closing: TokenKind?, depth: Int
    ) throws(ManifestError) {
        if closing != nil { skipNewlines() }
        if let closing, kind == closing { return }
        while true {
            if case .label(let name) = kind {
                let key = try node(.symbol(name), at: token.location)
                advance()
                skipNewlines()
                options.append((key, try value(depth: depth)))
            } else {
                let value = try value(depth: depth)
                if kind == .arrow {
                    advance()
                    skipNewlines()
                    options.append((value, try self.value(depth: depth)))
                } else {
                    if !options.isEmpty {
                        throw ManifestError("Positional arguments must come before options", at: value.location)
                    }
                    positional.append(value)
                }
            }
            if closing != nil { skipNewlines() }
            guard kind == .comma else { break }
            advance()
            skipNewlines()
            if let closing, kind == closing { break }
        }
        if let closing, kind != closing { throw error("Expected \(describe(closing)), found \(describe(kind))") }
    }

    private mutating func value(depth: Int) throws(ManifestError) -> Node {
        let location = token.location
        switch kind {
        case .string(let text):
            advance()
            return try node(.string(text), at: location)
        case .symbol(let name):
            advance()
            return try node(.symbol(name), at: location)
        case .number(let text):
            advance()
            return try node(.number(text), at: location)
        case .words(let words, let symbols):
            try consumeNodes(1 + words.count, at: location)
            advance()
            let elements = words.map { Node(value: symbols ? .symbol($0) : .string($0), location: location) }
            return Node(value: .array(elements), location: location)
        case .identifier("true"):
            advance()
            return try node(.bool(true), at: location)
        case .identifier("false"):
            advance()
            return try node(.bool(false), at: location)
        case .identifier("nil"):
            advance()
            return try node(.null, at: location)
        case .identifier(let name):
            throw ManifestError(
                "'\(name)' is not a value", at: location,
                hint: "Podfiles are read as data: constants, variables and method calls are not supported. Write the value itself")
        case .leftBracket:
            try checkNesting(depth + 1, at: location)
            advance()
            var elements: [Node] = []
            skipNewlines()
            while kind != .rightBracket {
                elements.append(try value(depth: depth + 1))
                skipNewlines()
                if kind == .comma {
                    advance()
                    skipNewlines()
                } else if kind != .rightBracket {
                    throw error("Expected ',' or ']', found \(describe(kind))")
                }
            }
            advance()
            return try node(.array(elements), at: location)
        case .leftBrace:
            try checkNesting(depth + 1, at: location)
            advance()
            var positional: [Node] = []
            var pairs: [(key: Node, value: Node)] = []
            try arguments(&positional, &pairs, closing: .rightBrace, depth: depth + 1)
            if let stray = positional.first { throw ManifestError("Expected `key => value` in a hash", at: stray.location) }
            advance()
            return try node(.hash(pairs), at: location)
        default:
            throw error("Expected a value, found \(describe(kind))")
        }
    }
}
