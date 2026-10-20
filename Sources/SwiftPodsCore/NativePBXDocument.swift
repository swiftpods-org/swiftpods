import Foundation

/// Keeps the concrete OpenStep syntax so an edit does not reformat unrelated project records.
struct NativePBXDocument {
    private struct Entry {
        let key: String
        let start: Int
        let value: Node
        let end: Int
    }
    private indirect enum Contents {
        case scalar
        case dictionary([Entry])
        case array([Node], [Int])
    }
    private struct Node {
        let range: Range<Int>
        let contents: Contents
    }
    private struct Edit {
        let range: Range<Int>
        let replacement: String
    }

    private let bytes: [UInt8]
    private let root: Node
    private let values: [String: Any]
    private var newline: String { bytes.contains(13) ? "\r\n" : "\n" }

    init(_ source: String) throws {
        bytes = Array(source.utf8)
        values = try PropertyListSerialization.propertyList(from: Data(bytes), format: nil) as? [String: Any] ?? [:]
        var parser = Parser(bytes: bytes)
        root = try parser.node()
    }

    func updating(_ value: [String: Any]) -> String {
        var edits: [Edit] = []
        update(root, before: values, after: value, edits: &edits)
        var result = bytes
        for edit in edits.sorted(by: {
            if $0.range.lowerBound == $1.range.lowerBound { return $0.range.upperBound > $1.range.upperBound }
            return $0.range.lowerBound > $1.range.lowerBound
        }) {
            result.replaceSubrange(edit.range, with: edit.replacement.utf8)
        }
        return String(decoding: result, as: UTF8.self)
    }

    private func update(_ node: Node, before: Any, after: Any, edits: inout [Edit], isObjects: Bool = false) {
        if NativePBX.serialize(before) == NativePBX.serialize(after) { return }
        if case .dictionary(let entries) = node.contents,
            let old = before as? [String: Any], let new = after as? [String: Any]
        {
            let moved = Set(
                entries.compactMap { entry -> String? in
                    guard isObjects,
                        let previous = (old[entry.key] as? [String: Any])?["isa"] as? String,
                        let current = (new[entry.key] as? [String: Any])?["isa"] as? String,
                        previous != current
                    else { return nil }
                    return entry.key
                })
            for entry in entries {
                if !moved.contains(entry.key), let value = new[entry.key], let previous = old[entry.key] {
                    update(
                        entry.value, before: previous, after: value, edits: &edits,
                        isObjects: node.range == root.range && entry.key == "objects")
                } else {
                    edits.append(Edit(range: removalRange(entry.start..<entry.end), replacement: ""))
                }
            }
            let additions = new.keys.filter { old[$0] == nil || moved.contains($0) }.sorted()
            if !additions.isEmpty {
                let multiline = bytes[node.range].contains(10)
                let indent =
                    entries.first.map { indentation(at: $0.start) } ?? (indentation(at: node.range.lowerBound) + "\t")
                var insertions: [Int: [String]] = [:]
                var sections: [String: [String]] = [:]
                for key in additions {
                    // Put new project objects next to the existing section of the same class.
                    let isa = (new[key] as? [String: Any])?["isa"] as? String
                    let matching = isa.flatMap { kind in
                        entries.last {
                            !moved.contains($0.key) && (old[$0.key] as? [String: Any])?["isa"] as? String == kind
                        }
                    }
                    let position = matching.map { insertionAfter($0.end) } ?? closingPosition(node)
                    let separator = multiline ? indent : " "
                    let entry =
                        separator + NativePBXFormatting.atom(key) + " = "
                        + formatted(new[key]!, indent: indent) + ";" + (multiline ? newline : "")
                    if isObjects, multiline, matching == nil, let isa {
                        sections[isa, default: []].append(entry)
                    } else {
                        insertions[position, default: []].append(entry)
                    }
                }
                for isa in sections.keys.sorted() {
                    let section =
                        newline + "/* Begin \(isa) section */" + newline + sections[isa]!.joined()
                        + "/* End \(isa) section */" + newline
                    insertions[closingPosition(node), default: []].append(section)
                }
                for (position, lines) in insertions {
                    edits.append(Edit(range: position..<position, replacement: lines.joined()))
                }
            }
            return
        }
        if case .array(let elements, let ends) = node.contents,
            let old = before as? [Any], let new = after as? [Any], old.count == elements.count
        {
            let multiline = bytes[node.range].contains(10)
            let indent =
                elements.first.map { indentation(at: $0.range.lowerBound) }
                ?? (indentation(at: node.range.lowerBound) + "\t")
            var available = Array(old.indices)
            var parts: [String] = []
            for value in new {
                if let index = available.first(where: { NativePBX.serialize(old[$0]) == NativePBX.serialize(value) }) {
                    available.removeAll { $0 == index }
                    let start = index == 0 ? node.range.lowerBound + 1 : ends[index - 1]
                    var original = text(start..<ends[index])
                    if bytes[ends[index] - 1] != 44 { original += "," }
                    parts.append(original)
                } else {
                    parts.append(
                        (multiline ? newline + indent : " ") + formatted(value, indent: indent) + ",")
                }
            }
            let tail = text((ends.last ?? (node.range.lowerBound + 1))..<(node.range.upperBound - 1))
            edits.append(Edit(range: node.range, replacement: "(" + parts.joined() + tail + ")"))
            return
        }
        edits.append(
            Edit(
                range: node.range,
                replacement: formatted(after, indent: indentation(at: node.range.lowerBound))))
    }

    private func formatted(_ value: Any, indent: String) -> String {
        NativePBXFormatting.value(value, indent: indent).replacingOccurrences(of: "\n", with: newline)
    }

    private func text(_ range: Range<Int>) -> String { String(decoding: bytes[range], as: UTF8.self) }
    private func lineStart(_ offset: Int) -> Int {
        var start = offset
        while start > 0 && bytes[start - 1] != 10 { start -= 1 }
        return start
    }
    private func indentation(at offset: Int) -> String {
        let start = lineStart(offset)
        let end = bytes[start..<offset].prefix { $0 == 9 || $0 == 32 }.count + start
        return text(start..<end)
    }
    private func closingPosition(_ node: Node) -> Int {
        let close = node.range.upperBound - 1
        let start = lineStart(close)
        return bytes[start..<close].allSatisfy { $0 == 9 || $0 == 32 } ? start : close
    }
    private func insertionAfter(_ end: Int) -> Int {
        var cursor = end
        while cursor < bytes.count && (bytes[cursor] == 9 || bytes[cursor] == 32 || bytes[cursor] == 13) { cursor += 1 }
        return cursor < bytes.count && bytes[cursor] == 10 ? cursor + 1 : end
    }
    private func removalRange(_ range: Range<Int>) -> Range<Int> {
        let start = lineStart(range.lowerBound)
        guard bytes[start..<range.lowerBound].allSatisfy({ $0 == 9 || $0 == 32 }) else { return range }
        return start..<insertionAfter(range.upperBound)
    }

    private struct Parser {
        let bytes: [UInt8]
        var cursor = 0

        mutating func node() throws -> Node {
            try trivia()
            let start = cursor
            guard cursor < bytes.count else { throw invalid() }
            if bytes[cursor] == 123 {
                cursor += 1
                var entries: [Entry] = []
                try trivia()
                while cursor < bytes.count && bytes[cursor] != 125 {
                    let keyStart = cursor
                    let key = try scalar()
                    try consume(61)
                    let value = try node()
                    try consume(59)
                    entries.append(Entry(key: key, start: keyStart, value: value, end: cursor))
                    try trivia()
                }
                try consume(125)
                return Node(range: start..<cursor, contents: .dictionary(entries))
            }
            if bytes[cursor] == 40 {
                cursor += 1
                var elements: [Node] = []
                var ends: [Int] = []
                try trivia()
                while cursor < bytes.count && bytes[cursor] != 41 {
                    elements.append(try node())
                    try trivia()
                    if cursor < bytes.count && bytes[cursor] == 44 { cursor += 1 }
                    ends.append(cursor)
                    try trivia()
                }
                try consume(41)
                return Node(range: start..<cursor, contents: .array(elements, ends))
            }
            _ = try scalar()
            return Node(range: start..<cursor, contents: .scalar)
        }

        mutating func scalar() throws -> String {
            try trivia()
            let start = cursor
            guard cursor < bytes.count else { throw invalid() }
            if bytes[cursor] == 34 {
                cursor += 1
                while cursor < bytes.count {
                    let byte = bytes[cursor]
                    cursor += 1
                    if byte == 92 {
                        guard cursor < bytes.count else { throw invalid() }
                        cursor += 1
                    } else if byte == 34 {
                        let token = String(decoding: bytes[start..<cursor], as: UTF8.self)
                        if !token.contains("\\") { return String(token.dropFirst().dropLast()) }
                        let wrapped = Data(("{value = " + token + ";}").utf8)
                        let decoded =
                            try PropertyListSerialization.propertyList(from: wrapped, format: nil) as? [String: Any]
                        guard let value = decoded?["value"] as? String else { throw invalid() }
                        return value
                    }
                }
                throw invalid()
            }
            if bytes[cursor] == 60 {
                while cursor < bytes.count && bytes[cursor] != 62 { cursor += 1 }
                guard cursor < bytes.count else { throw invalid() }
                cursor += 1
                return String(decoding: bytes[start..<cursor], as: UTF8.self)
            }
            while cursor < bytes.count {
                let byte = bytes[cursor]
                if [9, 10, 13, 32, 40, 41, 44, 59, 61, 123, 125].contains(byte) { break }
                if byte == 47 && cursor + 1 < bytes.count && [42, 47].contains(bytes[cursor + 1]) { break }
                cursor += 1
            }
            guard cursor > start else { throw invalid() }
            return String(decoding: bytes[start..<cursor], as: UTF8.self)
        }

        mutating func consume(_ byte: UInt8) throws {
            try trivia()
            guard cursor < bytes.count && bytes[cursor] == byte else { throw invalid() }
            cursor += 1
        }

        mutating func trivia() throws {
            while cursor < bytes.count {
                if [9, 10, 13, 32].contains(bytes[cursor]) {
                    cursor += 1
                    continue
                }
                guard bytes[cursor] == 47 && cursor + 1 < bytes.count else { return }
                if bytes[cursor + 1] == 47 {
                    while cursor < bytes.count && bytes[cursor] != 10 { cursor += 1 }
                } else if bytes[cursor + 1] == 42 {
                    cursor += 2
                    while cursor + 1 < bytes.count && !(bytes[cursor] == 42 && bytes[cursor + 1] == 47) { cursor += 1 }
                    guard cursor + 1 < bytes.count else { throw invalid() }
                    cursor += 2
                } else {
                    return
                }
            }
        }

        private func invalid() -> Diagnostic {
            Diagnostic("SP-XCODE-PROJECT", stage: "integrate", "Invalid OpenStep project syntax near byte \(cursor)")
        }
    }
}

/// Conventional OpenStep spelling for new records; existing text belongs to the document.
enum NativePBXFormatting {
    static func atom(_ value: String) -> String {
        let safe =
            !value.isEmpty
            && value.utf8.allSatisfy {
                (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
                    || [95, 46, 47, 36].contains($0)
            }
        if safe && !value.contains("//") && !value.contains("/*") { return value }
        return NativePBX.serialize(value)
    }

    static func value(_ value: Any, indent: String = "") -> String {
        if let dictionary = value as? [String: Any] {
            if dictionary.isEmpty { return "{}" }
            let keys = dictionary.keys.sorted {
                if $0 == $1 { return false }
                if $0 == "isa" { return true }
                if $1 == "isa" { return false }
                return $0 < $1
            }
            if ["PBXBuildFile", "PBXFileReference"].contains(dictionary["isa"] as? String ?? ""),
                dictionary.values.allSatisfy({ !($0 is [Any]) && !($0 is [String: Any]) })
            {
                return "{" + keys.map { atom($0) + " = " + self.value(dictionary[$0]!, indent: indent) + "; " }.joined()
                    + "}"
            }
            return "{\n"
                + keys.map {
                    indent + "\t" + atom($0) + " = " + self.value(dictionary[$0]!, indent: indent + "\t") + ";\n"
                }.joined() + indent + "}"
        }
        if let array = value as? [Any] {
            if array.isEmpty { return "()" }
            return "(\n" + array.map { indent + "\t" + self.value($0, indent: indent + "\t") + ",\n" }.joined()
                + indent + ")"
        }
        return atom(NativeScalarString.string(value))
    }
}
