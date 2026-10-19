import Foundation

/// Single-quoted Ruby literals preserve interpolation text and embedded quotes.
enum NativeRubyString {
    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'"
    }
}
