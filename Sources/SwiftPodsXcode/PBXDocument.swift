import Foundation

/// Keeps the concrete OpenStep syntax so an edit does not reformat unrelated project records.
struct PBXDocument: Sendable {
    private struct Entry: Sendable {
        let key: String
        let start: Int
        let value: Node
        let end: Int
    }
    private indirect enum Contents: Sendable {
        case scalar
        case dictionary([Entry])
        case array([Node], [Int])
    }
    private struct Node: Sendable {
        let range: Range<Int>
        let contents: Contents
    }
    private struct Edit {
        let range: Range<Int>
        let replacement: String
    }

    private let bytes: [UInt8]
    private let root: Node
    let value: PBXValue
    private let newline: String

    init(_ source: String) throws(XcodeError) {
        bytes = Array(source.utf8)
        newline = bytes.contains(13) ? "\r\n" : "\n"
        // Validate the bounded OpenStep structure before asking Foundation to recursively decode it.
        // This keeps adversarial nesting and object counts from reaching PropertyListSerialization.
        var parser = Parser(bytes: bytes)
        root = try parser.node()
        try parser.finish()
        let list: Any
        do {
            list = try PropertyListSerialization.propertyList(from: Data(bytes), format: nil)
        } catch {
            throw XcodeError("Invalid project file: \(error.localizedDescription)")
        }
        value = try PBXValue(propertyList: list)
        guard value.dictionary != nil else { throw XcodeError("A project file must contain a dictionary") }
        try Self.validate(root, value: value)
    }

    /// Every concrete entry must map one-to-one to Foundation's decoded value. This rejects duplicate keys and
    /// uncommon escaped spellings that the minimal-diff parser cannot safely associate with the decoded dictionary.
    private static func validate(_ node: Node, value: PBXValue) throws(XcodeError) {
        switch node.contents {
        case .dictionary(let entries):
            guard let dictionary = value.dictionary, entries.count == dictionary.count,
                Set(entries.map(\.key)).count == entries.count,
                Set(entries.map(\.key)) == Set(dictionary.keys)
            else { throw XcodeError("Project dictionary keys do not map uniquely to their decoded values") }
            for entry in entries {
                guard let child = dictionary[entry.key] else {
                    throw XcodeError("Project dictionary key cannot be decoded safely")
                }
                try validate(entry.value, value: child)
            }
        case .array(let nodes, _):
            guard let values = value.array, nodes.count == values.count else {
                throw XcodeError("Project array syntax does not match its decoded values")
            }
            for (child, value) in zip(nodes, values) { try validate(child, value: value) }
        case .scalar:
            break
        }
    }

    /// The source text with only the records that differ from `value` rewritten.
    func updating(_ new: PBXValue) -> String {
        var edits: [Edit] = []
        update(root, before: value, after: new, edits: &edits)
        var result = bytes
        for edit in edits.sorted(by: {
            if $0.range.lowerBound == $1.range.lowerBound { return $0.range.upperBound > $1.range.upperBound }
            return $0.range.lowerBound > $1.range.lowerBound
        }) {
            result.replaceSubrange(edit.range, with: edit.replacement.utf8)
        }
        return Self.removingEmptySections(String(decoding: result, as: UTF8.self), keeping: text(0..<bytes.count))
    }

    /// Xcode writes no empty object sections; drop those left by removed objects.
    private static func removingEmptySections(_ text: String, keeping original: String) -> String {
        let pattern = #"\r?\n/\* Begin ([A-Za-z]+) section \*/\r?\n/\* End \1 section \*/\r?\n"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return text }
        let existing = Set(
            expression.matches(in: original, range: NSRange(original.startIndex..., in: original)).compactMap {
                Range($0.range(at: 1), in: original).map { String(original[$0]) }
            })
        var result = text
        for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: text), let name = Range(match.range(at: 1), in: text),
                !existing.contains(String(text[name]))
            else { continue }
            result.removeSubrange(range)
        }
        return result
    }

    private func update(_ node: Node, before: PBXValue, after: PBXValue, edits: inout [Edit], isObjects: Bool = false) {
        if before == after { return }
        if case .dictionary(let entries) = node.contents, let old = before.dictionary, let new = after.dictionary {
            // An object whose class changed is rewritten in its new class's section.
            let moved = Set(
                entries.compactMap { entry -> String? in
                    guard isObjects, let previous = old[entry.key]?.dictionary?.isa,
                        let current = new[entry.key]?.dictionary?.isa, previous != current
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
                // Reuse the last surviving record of each class as the insertion point. Looking it up independently for
                // every addition made a large object table with a new class quadratic; moved records stay excluded just
                // as they were from the previous backwards search because their original ranges are removed below.
                var lastEntryByISA: [String: Entry] = [:]
                lastEntryByISA.reserveCapacity(entries.count)
                for entry in entries where !moved.contains(entry.key) {
                    if let isa = old[entry.key]?.dictionary?.isa { lastEntryByISA[isa] = entry }
                }
                var insertions: [Int: [String]] = [:]
                var sections: [String: [String]] = [:]
                for key in additions {
                    // Put new project objects next to the existing section of the same class.
                    let isa = new[key]?.dictionary?.isa
                    let matching = isa.flatMap { lastEntryByISA[$0] }
                    let position = matching.map { insertionAfter($0.end) } ?? closingPosition(node)
                    let separator = multiline ? indent : " "
                    let entry =
                        separator + PBXFormatting.atom(key) + " = " + formatted(new[key]!, indent: indent) + ";"
                        + (multiline ? newline : "")
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
        if case .array(let elements, let ends) = node.contents, let old = before.array, let new = after.array,
            old.count == elements.count
        {
            let multiline = bytes[node.range].contains(10)
            let indent =
                elements.first.map { indentation(at: $0.range.lowerBound) }
                ?? (indentation(at: node.range.lowerBound) + "\t")
            // Keep the original spelling for each surviving value, including duplicates, without repeatedly scanning
            // and compacting the complete old array. A project-controlled array may contain hundreds of thousands of
            // values, so the previous `first(where:)` + `removeAll` loop was quadratic.
            var available: [PBXValue: [Int]] = [:]
            available.reserveCapacity(old.count)
            for (index, value) in old.enumerated() { available[value, default: []].append(index) }
            var consumed: [PBXValue: Int] = [:]
            consumed.reserveCapacity(available.count)
            var parts: [String] = []
            parts.reserveCapacity(new.count)
            for value in new {
                let offset = consumed[value, default: 0]
                if let indices = available[value], offset < indices.count {
                    let index = indices[offset]
                    consumed[value] = offset + 1
                    let start = index == 0 ? node.range.lowerBound + 1 : ends[index - 1]
                    var original = text(start..<ends[index])
                    if bytes[ends[index] - 1] != 44 { original += "," }
                    parts.append(original)
                } else {
                    parts.append((multiline ? newline + indent : " ") + formatted(value, indent: indent) + ",")
                }
            }
            let tail = text((ends.last ?? (node.range.lowerBound + 1))..<(node.range.upperBound - 1))
            edits.append(Edit(range: node.range, replacement: "(" + parts.joined() + tail + ")"))
            return
        }
        edits.append(Edit(range: node.range, replacement: formatted(after, indent: indentation(at: node.range.lowerBound))))
    }

    private func formatted(_ value: PBXValue, indent: String) -> String {
        PBXFormatting.value(value, indent: indent).replacingOccurrences(of: "\n", with: newline)
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
        private static let maximumDepth = 128
        private static let maximumNodes = 250_000

        let bytes: [UInt8]
        var cursor = 0
        var nodes = 0

        mutating func node(depth: Int = 0) throws(XcodeError) -> Node {
            guard depth <= Self.maximumDepth else {
                throw XcodeError("OpenStep project nesting exceeds the \(Self.maximumDepth)-level limit")
            }
            nodes += 1
            guard nodes <= Self.maximumNodes else {
                throw XcodeError("OpenStep project contains more than \(Self.maximumNodes) values")
            }
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
                    let value = try node(depth: depth + 1)
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
                    elements.append(try node(depth: depth + 1))
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

        mutating func finish() throws(XcodeError) {
            try trivia()
            guard cursor == bytes.count else { throw invalid() }
        }

        mutating func scalar() throws(XcodeError) -> String {
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
                        // Keys are compared unescaped; the property list parser already decoded values.
                        let token = String(decoding: bytes[(start + 1)..<(cursor - 1)], as: UTF8.self)
                        return token.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
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

        mutating func consume(_ byte: UInt8) throws(XcodeError) {
            try trivia()
            guard cursor < bytes.count && bytes[cursor] == byte else { throw invalid() }
            cursor += 1
        }

        mutating func trivia() throws(XcodeError) {
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

        private func invalid() -> XcodeError { XcodeError("Invalid OpenStep project syntax near byte \(cursor)") }
    }
}
