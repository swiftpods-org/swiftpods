import Foundation

/// Inline YAML tokens use scalar boundaries; punctuation inside plain text is data.
struct NativeYAMLScalar {
    let file: String?
    let line: Int

    func failure(_ message: String) -> Diagnostic {
        Diagnostic("SP-LOCK-YAML", stage: "resolve", message, file: file, line: line)
    }

    static func trimmed(_ text: String) -> String {
        let scalars = text.unicodeScalars
        var start = scalars.startIndex
        var end = scalars.endIndex
        while start < end, space(scalars[start]) { start = scalars.index(after: start) }
        while start < end, space(scalars[scalars.index(before: end)]) { end = scalars.index(before: end) }
        return String(scalars[start..<end])
    }

    private static func space(_ scalar: Unicode.Scalar) -> Bool { [" ", "\t", "\n", "\r"].contains(scalar) }

    func inspected(_ text: String) throws -> (text: String, incomplete: Bool, quoted: Unicode.Scalar?) {
        let result = try lex(text, incompleteAllowed: true)
        return (result.parts[0], result.incomplete, result.quoted)
    }

    func parts(_ text: String, separator: Unicode.Scalar, mapping: Bool = false, flow: Bool = false) throws -> [String]
    {
        try lex(text, separator: separator, mapping: mapping, flow: flow).parts
    }

    private func lex(
        _ text: String, separator: Unicode.Scalar? = nil, mapping: Bool = false, flow: Bool = false,
        incompleteAllowed: Bool = false
    ) throws -> (parts: [String], incomplete: Bool, quoted: Unicode.Scalar?) {
        let scalars = text.unicodeScalars
        var quote: Unicode.Scalar?
        var escaped = false
        var containers: [Unicode.Scalar] = []
        var tokenStart = true
        var closed = false
        var quotedKey = false
        var result: [String] = []
        var start = scalars.startIndex
        var end = scalars.endIndex
        var index = start
        while index < scalars.endIndex {
            let char = scalars[index]
            let next = scalars.index(after: index)
            if escaped {
                escaped = false
            } else if char == "\\", quote == "\"" {
                escaped = true
            } else if let active = quote {
                if char == active {
                    if active == "'", next < scalars.endIndex, scalars[next] == "'" {
                        index = next
                    } else {
                        quote = nil
                        closed = true
                        quotedKey = true
                    }
                }
            } else if char == "#", index == scalars.startIndex || Self.space(scalars[scalars.index(before: index)]) {
                end = index
                break
            } else if Self.space(char) {
                // Whitespace does not start a new scalar inside a plain value.
            } else {
                if char == ":", flow || !containers.isEmpty, !quotedKey, next < scalars.endIndex,
                    [",", "]", "}"].contains(scalars[next])
                {
                    throw failure("Missing separation after a plain YAML key")
                }
                let colon = char == ":" && (next == scalars.endIndex || Self.space(scalars[next]) || quotedKey)
                if char == separator, containers.isEmpty, !mapping || colon {
                    result.append(Self.trimmed(String(scalars[start..<index])))
                    start = next
                    if mapping {
                        result.append(Self.trimmed(String(scalars[start...])))
                        return (result, false, nil)
                    }
                    tokenStart = true
                    closed = false
                    quotedKey = false
                } else if colon || (char == "," && (flow || !containers.isEmpty)) {
                    tokenStart = true
                    closed = false
                    quotedKey = false
                } else if char == "'" || char == "\"", tokenStart {
                    quote = char
                    tokenStart = false
                    closed = false
                    quotedKey = false
                } else if char == "[" || char == "{" {
                    if tokenStart {
                        containers.append(char == "[" ? "]" : "}")
                        tokenStart = true
                        closed = false
                        quotedKey = false
                    } else if flow || !containers.isEmpty || closed {
                        throw failure("Unexpected YAML collection delimiter")
                    }
                } else if char == "]" || char == "}", flow || !containers.isEmpty || tokenStart {
                    guard containers.last == char else { throw failure("Mismatched YAML collection delimiter") }
                    containers.removeLast()
                    tokenStart = false
                    closed = true
                    quotedKey = false
                } else {
                    guard !closed else { throw failure("Unexpected text after a YAML scalar") }
                    tokenStart = false
                    quotedKey = false
                }
            }
            index = scalars.index(after: index)
        }
        let incomplete = quote != nil || !containers.isEmpty
        guard incompleteAllowed || !incomplete else { throw failure("Unterminated YAML scalar or collection") }
        result.append(Self.trimmed(String(scalars[start..<end])))
        return (result, incomplete, quote)
    }

    func value(_ raw: String, flow: Bool = false, depth: Int = 0) throws -> Any {
        guard depth <= 512 else { throw failure("YAML exceeds the nesting limit") }
        let text = try lex(Self.trimmed(raw), flow: flow).parts[0]
        let scalars = text.unicodeScalars
        guard try parts(text, separator: ":", mapping: true).count == 1 else { throw failure("Invalid YAML scalar") }
        if scalars.first == "'" {
            let body = String(scalars.dropFirst().dropLast()) as NSString
            return body.replacingOccurrences(
                of: "''", with: "'", options: .literal, range: NSRange(location: 0, length: body.length))
        }
        if scalars.first == "\"" { return try doubleQuoted(text) }
        if scalars.first == "[" || scalars.first == "{" {
            let body = Self.trimmed(String(scalars.dropFirst().dropLast()))
            var entries = body.isEmpty ? [] : try parts(body, separator: ",", flow: true)
            if entries.last == "" { entries.removeLast() }
            guard entries.allSatisfy({ !$0.isEmpty }) else { throw failure("Empty YAML flow entry") }
            if scalars.first == "[" {
                return try entries.map { entry -> Any in
                    let pair = try parts(entry, separator: ":", mapping: true, flow: true)
                    if pair.count == 2 {
                        guard let key = try value(pair[0], flow: true, depth: depth + 1) as? String else {
                            throw failure("YAML keys must be strings")
                        }
                        return [key: try value(pair[1], flow: true, depth: depth + 1)]
                    }
                    return try value(entry, flow: true, depth: depth + 1)
                }
            }
            var result: [String: Any] = [:]
            for entry in entries {
                let pair = try parts(entry, separator: ":", mapping: true, flow: true)
                guard let key = try value(pair[0], flow: true, depth: depth + 1) as? String, result[key] == nil else {
                    throw failure("Invalid or duplicate YAML key")
                }
                result[key] = pair.count == 1 ? NSNull() : try value(pair[1], flow: true, depth: depth + 1)
            }
            return result
        }
        guard !["!", "&", "*"].contains(scalars.first) else {
            throw failure("YAML tags, anchors and aliases are not accepted in lockfiles")
        }
        guard !["|", ">", "@", "`", "%", ","].contains(scalars.first),
            try parts(text, separator: ":", mapping: true).count == 1
        else { throw failure("Invalid plain YAML scalar") }
        if ["-", "?", ":"].contains(scalars.first), scalars.count == 1 || Self.space(scalars.dropFirst().first!) {
            throw failure("Unexpected YAML indicator")
        }
        switch text.lowercased() {
        case "", "~", "null": return NSNull()
        case "true", "yes", "on": return true
        case "false", "no", "off": return false
        case ".inf", "+.inf", "-.inf", ".nan": throw failure("Non-finite YAML numbers are not supported")
        default:
            if let number = try number(text) { return number }
            return text
        }
    }

    private func doubleQuoted(_ text: String) throws -> String {
        let scalars = Array(text.unicodeScalars.dropFirst().dropLast())
        let escapes: [Unicode.Scalar: Unicode.Scalar] = [
            "0": "\0", "a": "\u{7}", "b": "\u{8}", "t": "\t", "n": "\n", "v": "\u{b}", "f": "\u{c}", "r": "\r",
            "e": "\u{1b}", " ": " ", "\"": "\"", "/": "/", "\\": "\\", "N": "\u{85}", "_": "\u{a0}", "L": "\u{2028}",
            "P": "\u{2029}",
        ]
        var result = ""
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            index += 1
            guard scalar == "\\" else {
                result.unicodeScalars.append(scalar)
                continue
            }
            guard index < scalars.count else { throw failure("Invalid quoted YAML escape") }
            let escape = scalars[index]
            index += 1
            if let decoded = escapes[escape] {
                result.unicodeScalars.append(decoded)
                continue
            }
            guard let length = ["x": 2, "u": 4, "U": 8][String(escape)], index + length <= scalars.count,
                scalars[index..<(index + length)].allSatisfy({
                    (0x30...0x39).contains($0.value) || (0x41...0x46).contains($0.value)
                        || (0x61...0x66).contains($0.value)
                }),
                let code = UInt32(String(String.UnicodeScalarView(scalars[index..<(index + length)])), radix: 16)
            else { throw failure("Invalid quoted YAML escape") }
            index += length
            if let decoded = Unicode.Scalar(code) {
                result.unicodeScalars.append(decoded)
            } else {
                throw failure("Invalid Unicode scalar in YAML escape")
            }
        }
        return result
    }

    private func number(_ text: String) throws -> NSNumber? {
        func matches(_ pattern: String) -> Bool {
            (text as NSString).range(of: "\\A(?:" + pattern + ")\\z", options: .regularExpression).location
                != NSNotFound
        }
        if matches(#"[-+]?[0-9][0-9_]*(?::[0-5]?[0-9]){1,2}(?:\.[0-9_]*)?"#) {
            let fields = text.replacingOccurrences(of: "_", with: "").components(separatedBy: ":")
            // The pinned Psych scanner weights two fields as hours/minutes.
            if text.contains(".") {
                let value = fields.enumerated().reduce(0.0) { result, entry in
                    result + Double(entry.element)! * pow(60, Double(2 - entry.offset))
                }
                guard value.isFinite else { throw failure("YAML number exceeds supported range") }
                return NSNumber(value: value)
            }
            var total = Decimal(0)
            for (index, field) in fields.enumerated() {
                let negative = field.first == "-"
                let digits = String(field.drop(while: { $0 == "+" || $0 == "-" || $0 == "0" }))
                let canonical = (negative ? "-" : "") + (digits.isEmpty ? "0" : digits)
                guard let parsed = try number(canonical) else { throw failure("Invalid YAML integer") }
                var component = parsed.decimalValue
                var weight = Decimal(index == 0 ? 3600 : index == 1 ? 60 : 1)
                var weighted = Decimal()
                var sum = Decimal()
                guard NSDecimalMultiply(&weighted, &component, &weight, .plain) == .noError,
                    NSDecimalAdd(&sum, &total, &weighted, .plain) == .noError
                else { throw failure("YAML integer exceeds supported precision") }
                total = sum
            }
            return NSDecimalNumber(decimal: total)
        }
        if matches(
            #"[-+]?(?:0b[_,]*[01][01_,]*|0[_,]*[0-7][0-7_,]*|0|[1-9](?:[0-9]|[,_][0-9])*|0x[_,]*[0-9a-fA-F][0-9a-fA-F_,]*)"#
        ) {
            var digits = text.replacingOccurrences(of: "_", with: "").replacingOccurrences(of: ",", with: "")
            let negative = digits.first == "-"
            if digits.first == "-" || digits.first == "+" { digits.removeFirst() }
            let radix: Int
            if digits.hasPrefix("0b") {
                radix = 2
                digits.removeFirst(2)
            } else if digits.hasPrefix("0x") {
                radix = 16
                digits.removeFirst(2)
            } else if digits.count > 1, digits.first == "0" {
                radix = 8
                digits.removeFirst()
            } else {
                radix = 10
            }
            if let integer = UInt64(digits, radix: radix) {
                if negative, integer <= UInt64(Int64.max) { return NSNumber(value: -Int64(integer)) }
                if negative, integer == UInt64(Int64.max) + 1 { return NSNumber(value: Int64.min) }
                if !negative { return NSNumber(value: integer) }
            }
            var decimal = Decimal(0)
            var base = Decimal(radix)
            for char in digits {
                guard let value = char.hexDigitValue, value < radix else { throw failure("Invalid YAML integer") }
                var digit = Decimal(value)
                var multiplied = Decimal()
                var added = Decimal()
                guard NSDecimalMultiply(&multiplied, &decimal, &base, .plain) == .noError,
                    NSDecimalAdd(&added, &multiplied, &digit, .plain) == .noError
                else { throw failure("YAML integer exceeds supported precision") }
                decimal = added
            }
            return NSDecimalNumber(decimal: negative ? -decimal : decimal)
        }
        if matches(#"[-+]?(?:[0-9][0-9_,]*)?\.[0-9]*(?:[eE][-+][0-9]+)?"#), ![".", "+.", "-."].contains(text) {
            let normalized = text.replacingOccurrences(of: "_", with: "").replacingOccurrences(of: ",", with: "")
            guard let value = Double(normalized), value.isFinite else {
                throw failure("YAML number exceeds supported range")
            }
            return NSNumber(value: value)
        }
        return nil
    }
}
