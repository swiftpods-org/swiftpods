import Foundation

/// Raw declarations and their evaluation bindings have different lifetimes.
/// In particular, a literal built-in path must never become a new expression.
struct NativeBuildSettingScope {
    private(set) var values: [String: Any]
    let settingTypes: NativeBuildSettingTypes
    private var bindings: [String: NativeBuildSettingExpression]
    private var assignmentDefaults: [String: NativeBuildSettingExpression]

    init(
        _ values: [String: Any] = [:], literalKeys: Set<String> = [], assignmentDefaults: [String: String] = [:],
        settingTypes: NativeBuildSettingTypes = .current
    ) {
        self.settingTypes = settingTypes
        self.values = values
        self.assignmentDefaults = assignmentDefaults.mapValues { .literal($0) }
        bindings = values.mapValues { _ in .literal("") }
        for (key, value) in values {
            let text = nativeStrings(value).joined(separator: " ")
            bindings[key] =
                literalKeys.contains(key) ? .literal(text) : .source(key, text, self.assignmentDefaults[key])
        }
    }

    func merging(_ additions: [String: Any], literals: Set<String> = []) -> Self {
        var result = self
        result.values = NativeBuildSettings.merge(values, additions)
        for (key, value) in additions {
            let text = nativeStrings(value).joined(separator: " ")
            if literals.contains(key) {
                result.values[key] = value
                result.bindings[key] = .literal(text)
            } else {
                result.bindings[key] = .source(key, text, bindings[key] ?? assignmentDefaults[key])
            }
        }
        return result
    }

    /// A computed scope already contains its inherited bindings.
    func merging(_ scope: Self) -> Self {
        var result = self
        result.values.merge(scope.values) { _, value in value }
        result.bindings.merge(scope.bindings) { _, value in value }
        result.assignmentDefaults.merge(scope.assignmentDefaults) { _, value in value }
        return result
    }

    func expandedValue(_ key: String, undefinedAsEmpty: Bool = false) throws -> String? {
        try NativeBuildSettingEvaluation(
            bindings: bindings, undefinedAsEmpty: undefinedAsEmpty, settingTypes: settingTypes
        ).value(key, frames: [])
    }

    func expandedPathExpression(_ text: String) throws -> String {
        try NativeBuildSettingEvaluation(bindings: bindings, undefinedAsEmpty: true, settingTypes: settingTypes)
            .expression(text)
    }

    func finalizedDefaults() throws -> Self {
        guard let source = values["SOURCE_ROOT"] as? String, ["$(SRCROOT)", "${SRCROOT}"].contains(source),
            let expanded = try expandedValue("SOURCE_ROOT")
        else { return self }
        return merging(["SOURCE_ROOT": expanded], literals: ["SOURCE_ROOT"])
    }

}

private indirect enum NativeBuildSettingExpression {
    case literal(String)
    case source(String, String, NativeBuildSettingExpression?)
}

private struct NativeBuildSettingFrame {
    let key: String
    let previous: NativeBuildSettingExpression?
}

private final class NativeBuildSettingEvaluation {
    let bindings: [String: NativeBuildSettingExpression]
    let undefinedAsEmpty: Bool
    let settingTypes: NativeBuildSettingTypes

    init(
        bindings: [String: NativeBuildSettingExpression], undefinedAsEmpty: Bool, settingTypes: NativeBuildSettingTypes
    ) {
        self.bindings = bindings
        self.undefinedAsEmpty = undefinedAsEmpty
        self.settingTypes = settingTypes
    }

    func value(_ key: String, frames: [NativeBuildSettingFrame]) throws -> String? {
        let expression: NativeBuildSettingExpression
        if let frame = frames.last(where: { $0.key == key }) {
            guard let previous = frame.previous else {
                throw Diagnostic(
                    "SP-XCCONFIG-CYCLE", stage: "analyze",
                    "Cyclic build setting: " + (frames.map(\.key) + [key]).joined(separator: " -> "))
            }
            expression = previous
        } else {
            guard let binding = bindings[key] else { return nil }
            expression = binding
        }
        _ = try settingTypes.isScalar(key)
        let result = try evaluate(expression, frames: frames)
        guard key != "SDKROOT" || !result.utf8.contains(0) else {
            throw Diagnostic("SP-XCCONFIG-PATH", stage: "analyze", "SDKROOT cannot contain NUL", file: key)
        }
        return result
    }

    /// Anonymous expressions have no declaration or synthetic name in the scope.
    func expression(_ text: String) throws -> String {
        var parser = NativeBuildSettingParser(
            text: text, stringSetting: true, undefinedAsEmpty: undefinedAsEmpty,
            lookup: { try self.value($0, frames: []) })
        return try parser.fragment()
    }

    private func evaluate(_ expression: NativeBuildSettingExpression, frames: [NativeBuildSettingFrame]) throws
        -> String
    {
        switch expression {
        case .literal(let text): return text
        case .source(let key, let text, let inherited):
            let nested = frames + [NativeBuildSettingFrame(key: key, previous: inherited)]
            var parser = NativeBuildSettingParser(
                text: text, stringSetting: try settingTypes.isScalar(key),
                undefinedAsEmpty: undefinedAsEmpty,
                lookup: { name in
                    if ["inherited", "value"].contains(name), let inherited {
                        return try self.evaluate(inherited, frames: nested)
                    }
                    return try self.value(name, frames: nested)
                })
            return try parser.fragment()
        }
    }
}

/// Scan Unicode scalars so a combining mark cannot hide an ASCII delimiter.
private struct NativeBuildSettingParser {
    let scalars: [Unicode.Scalar]
    let stringSetting: Bool
    let undefinedAsEmpty: Bool
    let lookup: (String) throws -> String?
    private var position = 0

    init(text: String, stringSetting: Bool, undefinedAsEmpty: Bool, lookup: @escaping (String) throws -> String?) {
        scalars = Array(text.unicodeScalars)
        self.stringSetting = stringSetting
        self.undefinedAsEmpty = undefinedAsEmpty
        self.lookup = lookup
    }

    private func text(_ range: Range<Int>) -> String {
        String(String.UnicodeScalarView(scalars[range]))
    }

    private func peek(_ offset: Int = 0) -> Unicode.Scalar? {
        position + offset < scalars.count ? scalars[position + offset] : nil
    }

    private func nameStart(_ scalar: Unicode.Scalar?) -> Bool {
        guard let scalar else { return false }
        return scalar == "_" || (65...90).contains(scalar.value) || (97...122).contains(scalar.value)
    }

    private func namePart(_ scalar: Unicode.Scalar?) -> Bool {
        nameStart(scalar) || scalar.map { (48...57).contains($0.value) } == true
    }

    mutating func fragment(stopping: Set<Unicode.Scalar> = []) throws -> String {
        var result = ""
        while let scalar = peek(), !stopping.contains(scalar) {
            if !stringSetting, stopping.isEmpty, scalar == "\\", let escaped = peek(1) {
                result.unicodeScalars.append(scalar)
                result.unicodeScalars.append(escaped)
                position += 2
            } else if scalar == "$" {
                result += try reference()
            } else {
                result.unicodeScalars.append(scalar)
                position += 1
            }
        }
        return result
    }

    private mutating func reference() throws -> String {
        let start = position
        position += 1
        if peek() == "$" {
            position += 1
            return "$"
        }
        let name: String
        var bracketed = false
        var modifiers: [(String, String?)] = []
        if peek() == "(" || peek() == "{" {
            bracketed = true
            let close: Unicode.Scalar = peek() == "(" ? ")" : "}"
            position += 1
            name = try fragment(stopping: [":", close])
            while peek() == ":" {
                position += 1
                let begin = position
                while let scalar = peek(), !["=", ":", close].contains(scalar) { position += 1 }
                let modifier = text(begin..<position)
                var argument: String?
                if peek() == "=" {
                    position += 1
                    argument = try fragment(stopping: [":", close])
                }
                modifiers.append((modifier, argument))
            }
            guard peek() == close else {
                throw Diagnostic("SP-XCCONFIG-EXPRESSION", stage: "analyze", "Unterminated build setting expression")
            }
            position += 1
        } else if nameStart(peek()) {
            let begin = position
            position += 1
            while namePart(peek()) { position += 1 }
            var shortName = text(begin..<position)
            if peek() == "$", peek(1) == "(" { shortName += try reference() }
            name = shortName
        } else {
            return "$"
        }
        let found = try lookup(name)
        var value = found ?? ""
        var defaulted = false
        for (modifier, argument) in modifiers {
            if modifier == "default", let argument {
                if value.isEmpty { value = argument }
                defaulted = true
            } else if !value.isEmpty {
                value = NativeBuildSettingModifiers.apply(modifier, to: value, argument: argument)
            }
        }
        if found == nil, !bracketed { return "$" + name }
        if found == nil, !defaulted, !undefinedAsEmpty { return text(start..<position) }
        return value
    }
}
