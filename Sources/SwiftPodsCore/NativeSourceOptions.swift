import Foundation

enum NativeSourceOptions {
    static func validate(_ source: [String: Any], file: String) throws {
        for key in ["sha1", "sha256", "type"]
        where source[key] != nil && !(source[key] is NSNull) && !(source[key] is String) {
            throw Diagnostic("SP-DSL-POD-OPTION", stage: "resolve", key + " must be a string", file: file)
        }
        _ = try revision(source["revision"], file: file)
    }

    /// Both source DSLs accept integer VCS revisions. Preserve integer precision
    /// and reject booleans/fractions before a missing string cast can select HEAD.
    static func revision(_ value: Any?, file: String) throws -> String? {
        guard let value, !(value is NSNull) else { return nil }
        if let string = value as? String { return string }
        if let number = value as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite
        {
            var decimal = number.decimalValue
            var integer = Decimal()
            NSDecimalRound(&integer, &decimal, 0, .plain)
            if decimal == integer { return NSDecimalNumber(decimal: integer).stringValue }
        }
        throw Diagnostic("SP-DSL-POD-OPTION", stage: "resolve", "revision must be a string or integer", file: file)
    }
}
