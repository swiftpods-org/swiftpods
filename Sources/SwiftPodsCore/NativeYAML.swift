import Foundation

/// Data-only, single-document YAML used by lockfiles. Tags and aliases are not evaluated.
enum NativeYAML {
    private struct Line {
        let raw: String
        let indent: Int
        let text: String
        let number: Int
        let terminated: Bool
    }

    static func object(_ text: String, file: String? = nil) throws -> [String: Any] {
        if let data = text.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data) {
            try NativeDictionaryKeys.validate(value, file: file)
            if let json = value as? [String: Any] { return json }
        }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{85}", with: "\n")
        var physical = normalized.components(separatedBy: "\n")
        let terminated = normalized.unicodeScalars.last == "\n"
        if terminated { physical.removeLast() }
        var lines: [Line] = []
        var started = false
        var ended = false
        for (index, raw) in physical.enumerated() {
            guard
                raw.unicodeScalars.allSatisfy({ scalar in
                    scalar == "\t"
                        || (scalar.value >= 0x20 && !(0x7F...0x9F).contains(scalar.value)
                            && ![0xFFFE, 0xFFFF].contains(scalar.value))
                })
            else {
                throw Diagnostic(
                    "SP-LOCK-YAML", stage: "resolve", "Non-printable character in YAML", file: file, line: index + 1)
            }
            let value = NativeYAMLScalar.trimmed(raw)
            let indent = raw.unicodeScalars.prefix(while: { $0 == " " }).count
            let comment = value.unicodeScalars.first == "#"
            if !value.isEmpty, !comment {
                let marker =
                    indent == 0 ? try NativeYAMLScalar(file: file, line: index + 1).inspected(value).text : value
                if marker == "---" {
                    guard !started, !ended else {
                        throw Diagnostic(
                            "SP-LOCK-YAML", stage: "resolve", "Lockfiles must contain one YAML document", file: file,
                            line: index + 1)
                    }
                    started = true
                    continue
                }
                if marker == "..." {
                    guard !ended else {
                        throw Diagnostic(
                            "SP-LOCK-YAML", stage: "resolve", "Unexpected YAML document end", file: file,
                            line: index + 1)
                    }
                    ended = true
                    continue
                }
                guard !ended else {
                    throw Diagnostic(
                        "SP-LOCK-YAML", stage: "resolve", "Content after the YAML document end", file: file,
                        line: index + 1)
                }
                started = true
            }
            lines.append(
                Line(
                    raw: raw, indent: indent, text: value, number: index + 1,
                    terminated: index < physical.count - 1 || terminated))
        }
        var cursor = 0
        func skip() {
            while cursor < lines.count, lines[cursor].text.isEmpty || lines[cursor].text.unicodeScalars.first == "#" {
                cursor += 1
            }
        }
        func isItem(_ text: String) -> Bool {
            let scalars = text.unicodeScalars
            return scalars.first == "-" && (scalars.count == 1 || [" ", "\t"].contains(scalars.dropFirst().first))
        }
        func failure(_ message: String) -> Diagnostic {
            Diagnostic(
                "SP-LOCK-YAML", stage: "resolve", message, file: file,
                line: cursor < lines.count ? lines[cursor].number : lines.last?.number)
        }
        func blockScalar(_ header: String, parent: Int, scalar: NativeYAMLScalar) throws -> String {
            guard
                (header as NSString).range(of: #"\A[|>](?:[+-][1-9]?|[1-9][+-]?)?\z"#, options: .regularExpression)
                    .location != NSNotFound
            else {
                throw scalar.failure("Invalid YAML block scalar header")
            }
            let explicit = header.compactMap(\.wholeNumberValue).first
            var indentation = explicit.map { parent + $0 }
            var end = cursor
            while end < lines.count {
                let row = lines[end]
                if !row.text.isEmpty {
                    if row.indent <= parent { break }
                    if indentation == nil { indentation = row.indent }
                    guard row.indent >= indentation! else {
                        throw NativeYAMLScalar(file: file, line: row.number).failure(
                            "Invalid YAML block scalar indentation")
                    }
                }
                end += 1
            }
            let base = indentation ?? parent + 1
            let body = lines[cursor..<end].map { row in
                (
                    text: String(row.raw.unicodeScalars.dropFirst(min(base, row.raw.unicodeScalars.count))),
                    more: row.indent > base && !row.text.isEmpty, terminated: row.terminated
                )
            }
            cursor = end
            var result = ""
            if header.unicodeScalars.first == "|" {
                for row in body { result += row.text + (row.terminated ? "\n" : "") }
            } else {
                var index = 0
                while index < body.count {
                    let row = body[index]
                    result += row.text
                    if row.text.isEmpty {
                        if row.terminated { result += "\n" }
                        index += 1
                        continue
                    }
                    var next = index + 1
                    while next < body.count, body[next].text.isEmpty { next += 1 }
                    if next < body.count {
                        let blanks = next - index - 1
                        result +=
                            blanks == 0 && !row.more && !body[next].more
                            ? " " : String(repeating: "\n", count: blanks + (row.more || body[next].more ? 1 : 0))
                    } else {
                        result += String(repeating: "\n", count: body[index...].filter(\.terminated).count)
                    }
                    index = next
                }
            }
            let hadBreak = result.unicodeScalars.last == "\n"
            if !header.contains("+") {
                while result.unicodeScalars.last == "\n" { result.unicodeScalars.removeLast() }
                if !header.contains("-"), hadBreak, body.contains(where: { !$0.text.isEmpty }) { result += "\n" }
            }
            return result
        }
        func readValue(_ raw: String, parent: Int, scalar: NativeYAMLScalar, depth: Int) throws -> Any {
            let initial = try scalar.inspected(raw)
            if initial.text.isEmpty {
                skip()
                if cursor < lines.count,
                    lines[cursor].indent > parent || (lines[cursor].indent == parent && isItem(lines[cursor].text))
                {
                    return try block(lines[cursor].indent, depth: depth + 1, mappingEnd: lines[cursor].indent == parent)
                }
                return NSNull()
            }
            if ["|", ">"].contains(initial.text.unicodeScalars.first) {
                return try blockScalar(initial.text, parent: parent, scalar: scalar)
            }
            var value = initial.text
            var state = initial
            var blanks = 0
            while state.incomplete {
                guard cursor < lines.count else { throw scalar.failure("Unterminated YAML scalar or collection") }
                let row = lines[cursor]
                cursor += 1
                let part = NativeYAMLScalar.trimmed(row.raw)
                if part.isEmpty {
                    blanks += 1
                    continue
                }
                let escaped = value.unicodeScalars.reversed().prefix(while: { $0 == "\\" }).count % 2 == 1
                if state.quoted == "\"", escaped {
                    value.unicodeScalars.removeLast()
                } else {
                    value += blanks == 0 ? " " : String(repeating: "\n", count: blanks)
                }
                blanks = 0
                value += part
                state = try scalar.inspected(value)
                value = state.text
            }
            if !["'", "\"", "[", "{"].contains(initial.text.unicodeScalars.first) {
                while cursor < lines.count {
                    var next = cursor
                    while next < lines.count, lines[next].text.isEmpty { next += 1 }
                    guard next < lines.count, lines[next].indent > parent,
                        lines[next].text.unicodeScalars.first != "#"
                    else { break }
                    let joined =
                        value + (next == cursor ? " " : String(repeating: "\n", count: next - cursor))
                        + lines[next].text
                    guard try scalar.parts(joined, separator: ":", mapping: true).count == 1 else {
                        throw NativeYAMLScalar(file: file, line: lines[next].number).failure(
                            "Invalid plain scalar continuation")
                    }
                    value = try scalar.inspected(joined).text
                    cursor = next + 1
                }
            }
            return try scalar.value(value, depth: depth)
        }
        func block(_ indent: Int, depth: Int = 0, mappingEnd: Bool = false) throws -> Any {
            try NativeCancellation.check()
            guard depth <= 512 else { throw failure("YAML exceeds the nesting limit") }
            skip()
            guard cursor < lines.count else { return NSNull() }
            let sequence = isItem(lines[cursor].text)
            var array: [Any] = []
            var map: [String: Any] = [:]
            while cursor < lines.count, lines[cursor].indent == indent {
                let row = lines[cursor]
                let scalar = NativeYAMLScalar(file: file, line: row.number)
                guard !row.raw.unicodeScalars.prefix(while: { $0 == " " || $0 == "\t" }).contains("\t") else {
                    throw scalar.failure("Tabs in YAML indentation")
                }
                let item = isItem(row.text)
                if sequence, !item, mappingEnd { break }
                guard item == sequence else { throw scalar.failure("Mixed YAML sequence and mapping") }
                let raw = sequence ? NativeYAMLScalar.trimmed(String(row.text.unicodeScalars.dropFirst())) : row.text
                let content = try scalar.inspected(raw).text
                let pair = try scalar.parts(content, separator: ":", mapping: true)
                cursor += 1
                if pair.count == 2 {
                    guard let key = try scalar.value(pair[0], depth: depth) as? String else {
                        throw scalar.failure("YAML keys must be strings")
                    }
                    let parent = indent + (sequence ? 2 : 0)
                    let value = try readValue(pair[1], parent: parent, scalar: scalar, depth: depth)
                    if sequence {
                        var entry = [key: value]
                        skip()
                        if cursor < lines.count, lines[cursor].indent > indent {
                            guard lines[cursor].indent == parent,
                                let extra = try block(parent, depth: depth + 1) as? [String: Any]
                            else { throw failure("Invalid YAML sequence mapping") }
                            for (key, value) in extra {
                                guard entry[key] == nil else { throw failure("Duplicate YAML key: " + key) }
                                entry[key] = value
                            }
                        }
                        array.append(entry)
                    } else {
                        guard map[key] == nil else { throw scalar.failure("Duplicate YAML key: " + key) }
                        map[key] = value
                    }
                } else if sequence {
                    array.append(try readValue(content, parent: indent, scalar: scalar, depth: depth))
                } else {
                    throw scalar.failure("Expected YAML key and value")
                }
                skip()
            }
            if cursor < lines.count, lines[cursor].indent > indent { throw failure("Unexpected YAML indentation") }
            return sequence ? array : map
        }
        skip()
        if cursor == lines.count { return [:] }
        guard let result = try block(lines[cursor].indent) as? [String: Any], cursor == lines.count else {
            throw failure("Invalid lockfile YAML structure")
        }
        return result
    }

    static func quoted(_ text: String, single: Bool = false) -> String {
        let special = text.unicodeScalars.contains {
            $0.value < 0x20 || (0x7F...0x9F).contains($0.value) || [0x2028, 0x2029].contains($0.value)
        }
        if single, !special {
            let value = text as NSString
            return "'"
                + value.replacingOccurrences(
                    of: "'", with: "''", options: .literal, range: NSRange(location: 0, length: value.length)) + "'"
        }
        let escapes: [Unicode.Scalar: String] = [
            "\"": "\\\"", "\\": "\\\\", "\n": "\\n", "\r": "\\r", "\t": "\\t", "\u{8}": "\\b", "\u{c}": "\\f",
        ]
        return "\""
            + text.unicodeScalars.map { scalar in
                if let escaped = escapes[scalar] { return escaped }
                if scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value)
                    || [0x2028, 0x2029].contains(scalar.value)
                {
                    return String(format: "\\u%04X", scalar.value)
                }
                return String(scalar)
            }.joined() + "\""
    }

    static func encode(_ value: Any, indent: Int = 0) throws -> String {
        try NativeDictionaryKeys.validate(value, stage: "serialize")
        func atom(_ value: Any) throws -> String {
            if value is NSNull { return "null" }
            if let text = value as? String { return quoted(text) }
            if let text = NativeScalarString.number(value) { return text }
            return String(
                decoding: try JSONSerialization.data(
                    withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]),
                as: UTF8.self)
        }
        func emit(_ value: Any, indent: Int) throws -> String {
            let prefix = String(repeating: " ", count: indent)
            if let values = value as? [String: Any], !values.isEmpty {
                return try values.sorted { $0.key < $1.key }.map { key, item in
                    let nested = (item as? [Any])?.isEmpty == false || (item as? [String: Any])?.isEmpty == false
                    return prefix + (try atom(key)) + ":"
                        + (nested ? "\n" + (try emit(item, indent: indent + 2)) : " " + (try atom(item)) + "\n")
                }.joined()
            }
            if let values = value as? [Any], !values.isEmpty {
                return try values.map { item in
                    let nested = item is [Any] || item is [String: Any]
                    return prefix + "-"
                        + (nested ? "\n" + (try emit(item, indent: indent + 2)) : " " + (try atom(item)) + "\n")
                }.joined()
            }
            return prefix + (try atom(value)) + "\n"
        }
        return try emit(value, indent: indent)
    }
}
