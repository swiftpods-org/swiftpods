import Foundation

/// Data-only YAML used by lockfiles. No Ruby, object tags or aliases are evaluated.
enum NativeYAML {
    private struct Line { let indent: Int; let text: String; let number: Int }
    static func object(_ text: String, file: String? = nil) throws -> [String: Any] {
        if let data = text.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return json }
        var lines: [Line] = []
        for (index, raw) in text.components(separatedBy: .newlines).enumerated() {
            let value = raw.trimmingCharacters(in: .whitespaces)
            if value.isEmpty || value.hasPrefix("#") || ["---", "..."].contains(value) { continue }
            guard !raw.prefix(while: { $0.isWhitespace }).contains("\t") else { throw Diagnostic("SP-LOCK-YAML", stage: "resolve", "Tabs in YAML indentation", file: file, line: index + 1) }
            lines.append(Line(indent: raw.prefix(while: { $0 == " " }).count, text: value, number: index + 1))
        }
        var cursor = 0
        func failure(_ message: String) -> Diagnostic { Diagnostic("SP-LOCK-YAML", stage: "resolve", message, file: file, line: cursor < lines.count ? lines[cursor].number : nil) }
        func split(_ value: String, separator: Character, mapping: Bool = false) -> [String] {
            var quote: Character?, escaped = false, depth = 0, parts: [String] = [], start = value.startIndex
            var index = value.startIndex
            while index < value.endIndex {
                let char = value[index], next = value.index(after: index)
                if escaped { escaped = false }
                else if char == "\\" && quote == "\"" { escaped = true }
                else if let active = quote {
                    if char == active { if active == "'", next < value.endIndex, value[next] == "'" { index = next } else { quote = nil } }
                } else if char == "'" || char == "\"" { quote = char }
                else if char == "[" || char == "{" { depth += 1 }
                else if char == "]" || char == "}" { depth -= 1 }
                else if char == separator && depth == 0 && (!mapping || next == value.endIndex || value[next].isWhitespace) {
                    parts.append(String(value[start..<index]).trimmingCharacters(in: .whitespaces)); start = next
                    if mapping { parts.append(String(value[start...]).trimmingCharacters(in: .whitespaces)); return parts }
                }
                index = value.index(after: index)
            }
            parts.append(String(value[start...]).trimmingCharacters(in: .whitespaces)); return parts
        }
        func scalar(_ raw: String) throws -> Any {
            let value = raw.trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("'") {
                guard value.count >= 2, value.hasSuffix("'") else { throw failure("Unterminated YAML string") }
                return String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
            }
            if value.hasPrefix("\"") {
                guard let data = value.data(using: .utf8), let result = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? String else { throw failure("Invalid quoted YAML string") }
                return result
            }
            if value.hasPrefix("[") {
                guard value.hasSuffix("]") else { throw failure("Unterminated YAML sequence") }
                let body = String(value.dropFirst().dropLast())
                return body.trimmingCharacters(in: .whitespaces).isEmpty ? [] : try split(body, separator: ",").map(scalar)
            }
            if value.hasPrefix("{") {
                guard value.hasSuffix("}") else { throw failure("Unterminated YAML mapping") }
                var result: [String: Any] = [:]
                let body = String(value.dropFirst().dropLast())
                if !body.trimmingCharacters(in: .whitespaces).isEmpty {
                    for entry in split(body, separator: ",") {
                        let pair = split(entry, separator: ":", mapping: true)
                        guard pair.count == 2, let key = try scalar(pair[0]) as? String, result[key] == nil else { throw failure("Invalid or duplicate YAML key") }
                        result[key] = try scalar(pair[1])
                    }
                }
                return result
            }
            guard !value.hasPrefix("!"), !value.hasPrefix("&"), !value.hasPrefix("*") else { throw failure("YAML tags, anchors and aliases are not accepted in lockfiles") }
            let plain = value.components(separatedBy: " #").first ?? value
            if ["null", "Null", "NULL", "~"].contains(plain) || plain.isEmpty { return NSNull() }
            if ["true", "True", "TRUE"].contains(plain) { return true }
            if ["false", "False", "FALSE"].contains(plain) { return false }
            return plain
        }
        func block(_ indent: Int) throws -> Any {
            try NativeCancellation.check()
            guard cursor < lines.count else { return NSNull() }
            let sequence = lines[cursor].text == "-" || lines[cursor].text.hasPrefix("- ")
            var array: [Any] = [], map: [String: Any] = [:]
            while cursor < lines.count, lines[cursor].indent == indent {
                let row = lines[cursor]
                let isItem = row.text == "-" || row.text.hasPrefix("- ")
                guard isItem == sequence else { throw failure("Mixed YAML sequence and mapping") }
                let content = sequence ? String(row.text.dropFirst()).trimmingCharacters(in: .whitespaces) : row.text
                let pair = split(content, separator: ":", mapping: true)
                cursor += 1
                let hasChild = cursor < lines.count && lines[cursor].indent > indent
                if pair.count == 2 {
                    guard let key = try scalar(pair[0]) as? String else { throw failure("YAML keys must be strings") }
                    let value = pair[1].isEmpty ? (hasChild ? try block(lines[cursor].indent) : NSNull()) : try scalar(pair[1])
                    if sequence { array.append([key: value]) }
                    else { guard map[key] == nil else { throw failure("Duplicate YAML key: " + key) }; map[key] = value }
                } else if sequence {
                    array.append(content.isEmpty && hasChild ? try block(lines[cursor].indent) : try scalar(content))
                } else { throw failure("Expected YAML key and value") }
            }
            return sequence ? array : map
        }
        if lines.isEmpty { return [:] }
        guard let result = try block(lines[0].indent) as? [String: Any], cursor == lines.count else { throw failure("Invalid lockfile YAML structure") }
        return result
    }

    static func encode(_ value: Any, indent: Int = 0) throws -> String {
        let prefix = String(repeating: " ", count: indent)
        func atom(_ value: Any) throws -> String {
            if value is NSNull { return "null" }
            return String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
        }
        if let values = value as? [String: Any], !values.isEmpty {
            return try values.sorted { $0.key < $1.key }.map { key, item in
                let nested = (item as? [Any])?.isEmpty == false || (item as? [String: Any])?.isEmpty == false
                return prefix + (try atom(key)) + ":" + (nested ? "\n" + (try encode(item, indent: indent + 2)) : " " + (try atom(item)) + "\n")
            }.joined()
        }
        if let values = value as? [Any], !values.isEmpty {
            return try values.map { item in
                let nested = item is [Any] || item is [String: Any]
                return prefix + "-" + (nested ? "\n" + (try encode(item, indent: indent + 2)) : " " + (try atom(item)) + "\n")
            }.joined()
        }
        return prefix + (try atom(value)) + "\n"
    }
}
