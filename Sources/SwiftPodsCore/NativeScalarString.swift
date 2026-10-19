import Foundation

/// String coercion for values whose input API uses Ruby scalar spelling.
enum NativeScalarString {
    static func boolean(_ value: Any) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    static func isFloating(_ number: NSNumber) -> Bool {
        !(number is NSDecimalNumber) && ["d", "f"].contains(String(cString: number.objCType))
            && CFGetTypeID(number) != CFBooleanGetTypeID()
    }

    static func number(_ value: Any) -> String? {
        guard let number = value as? NSNumber, boolean(number) == nil, number.doubleValue.isFinite else { return nil }
        return isFloating(number) ? floating(number.doubleValue) : number.stringValue
    }

    private static func floating(_ value: Double) -> String {
        let sign = value.sign == .minus ? "-" : ""
        let parts = String(abs(value)).lowercased().split(separator: "e")
        let coefficient = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        var position = coefficient[0].count + (parts.count > 1 ? Int(parts[1])! : 0)
        var digits = Array(coefficient.joined())
        while digits.count > 1 && digits.first == "0" {
            digits.removeFirst()
            position -= 1
        }
        while digits.count > 1 && digits.last == "0" { digits.removeLast() }
        if digits == ["0"] { return sign + "0.0" }
        let exponent = position - 1
        // Ruby retains decimal spelling when a large value has a fractional part.
        if exponent < -4 || (exponent >= 15 && position >= digits.count) {
            let fraction = digits.count > 1 ? String(digits.dropFirst()) : "0"
            let power = String(abs(exponent))
            return sign + String(digits[0]) + "." + fraction + "e" + (exponent < 0 ? "-" : "+")
                + (power.count < 2 ? "0" : "") + power
        }
        if position <= 0 { return sign + "0." + String(repeating: "0", count: -position) + String(digits) }
        if position >= digits.count {
            return sign + String(digits) + String(repeating: "0", count: position - digits.count) + ".0"
        }
        return sign + String(digits.prefix(position)) + "." + String(digits.dropFirst(position))
    }

    static func string(_ value: Any) -> String {
        if value is NSNull { return "" }
        if let value = value as? String { return value }
        if let value = boolean(value) { return value ? "true" : "false" }
        if let value = number(value) { return value }
        return inspect(value)
    }

    static func inspect(_ value: Any) -> String {
        if value is NSNull { return "nil" }
        if let value = value as? String {
            var text = "\""
            let escapes: [UInt32: String] = [
                7: "\\a", 8: "\\b", 9: "\\t", 10: "\\n", 11: "\\v", 12: "\\f", 13: "\\r", 27: "\\e",
                34: "\\\"", 92: "\\\\",
            ]
            let scalars = Array(value.unicodeScalars)
            for (index, scalar) in scalars.enumerated() {
                if let escaped = escapes[scalar.value] {
                    text += escaped
                } else if scalar.properties.generalCategory == .control {
                    text += String(format: "\\u%04X", scalar.value)
                } else if scalar == "#", index + 1 < scalars.count, ["{", "@", "$"].contains(scalars[index + 1]) {
                    text += "\\#"
                } else {
                    text += String(scalar)
                }
            }
            return text + "\""
        }
        if let value = boolean(value) { return value ? "true" : "false" }
        if let value = number(value) { return value }
        if let values = value as? [Any] { return "[" + values.map(inspect).joined(separator: ", ") + "]" }
        if let values = value as? [String: Any] {
            return "{"
                + values.sorted(by: { $0.key < $1.key }).map {
                    inspect($0.key) + " => " + inspect($0.value)
                }.joined(separator: ", ") + "}"
        }
        return String(describing: value)
    }

    static func prefixContents(_ values: [Any]) -> String {
        func flatten(_ values: [Any]) -> [String] {
            values.flatMap { ($0 as? [Any]).map(flatten) ?? [string($0)] }
        }
        var text = flatten(values).joined(separator: "\n")
        if text.hasSuffix("\r\n") || text.hasSuffix("\n") || text.hasSuffix("\r") {
            text.removeLast()
        }
        return text
    }
}
