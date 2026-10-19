import Foundation

enum NativeSourceOptions {
    static func resolvedLocation(_ location: String, project: URL) -> String {
        // VCS separators remain delimiters when a combining scalar joins their grapheme.
        let scalars = location.unicodeScalars
        if let colon = scalars.firstIndex(of: ":"), !scalars[..<colon].contains("/") { return location }
        return URL(fileURLWithPath: location, relativeTo: URL(fileURLWithPath: project.path, isDirectory: true))
            .standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func validate(_ source: [String: Any], file: String) throws {
        for key in [
            "path", "podspec", "git", "http", "svn", "hg", "branch", "tag", "commit", "revision", "folder",
            "source", "project_name", "sha1", "sha256", "type",
        ] {
            if let value = source[key] as? String, value.utf8.contains(0) {
                throw Diagnostic(
                    "SP-DSL-POD-OPTION", stage: "resolve", key + " cannot contain NUL", file: file)
            }
        }
        for key in ["git", "http", "svn", "hg", "branch", "folder", "sha1", "sha256", "type"]
        where source[key] != nil && !(source[key] is NSNull) && !(source[key] is String) {
            throw Diagnostic("SP-DSL-POD-OPTION", stage: "resolve", key + " must be a string", file: file)
        }
        for key in ["tag", "commit"] {
            if let value = source[key], !(value is NSNull), !(value is String) {
                guard source["git"] is String, NativeScalarString.number(value) != nil else {
                    throw Diagnostic(
                        "SP-DSL-POD-OPTION", stage: "resolve", key + " must be a string or numeric Git selector",
                        file: file)
                }
            }
        }
        for key in ["submodules", "flatten"] {
            if let value = source[key], !(value is NSNull), CFGetTypeID(value as CFTypeRef) != CFBooleanGetTypeID() {
                throw Diagnostic("SP-DSL-POD-OPTION", stage: "resolve", key + " must be boolean", file: file)
            }
        }
        if let headers = source["headers"], !(headers is NSNull), !(headers is [String: String]) {
            throw Diagnostic("SP-DSL-POD-OPTION", stage: "resolve", "headers must map names to strings", file: file)
        }
        if let headers = source["headers"] as? [String: String],
            headers.contains(where: { $0.key.utf8.contains(0) || $0.value.utf8.contains(0) })
        {
            throw Diagnostic("SP-DSL-POD-OPTION", stage: "resolve", "Source headers cannot contain NUL", file: file)
        }
        _ = try revision(source["revision"], file: file)
    }

    static func gitSelector(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        return value as? String ?? NativeScalarString.number(value)
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
