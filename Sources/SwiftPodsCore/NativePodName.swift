import Foundation

/// Pod identity is Unicode; path separators and traversal are never identities.
enum NativePodName {
    static func components(_ value: String) -> [String] {
        value.unicodeScalars.split(separator: "/", omittingEmptySubsequences: false).map { String($0) }
    }

    static func root(_ value: String) -> String { components(value).first ?? "" }

    static func relativeName(of value: String, to ancestor: String) -> String? {
        let parts = components(value)
        let prefix = components(ancestor)
        guard parts.starts(with: prefix) else { return nil }
        return parts.dropFirst(prefix.count).joined(separator: "/")
    }

    static func isWithin(_ value: String, _ ancestor: String) -> Bool {
        relativeName(of: value, to: ancestor) != nil
    }

    static func isValid(_ value: String, subspecs: Bool = false) -> Bool {
        let parts = components(value)
        guard subspecs || parts.count == 1 else { return false }
        return parts.allSatisfy {
            !$0.isEmpty && $0.utf8.first != 46 && !$0.utf8.contains(92)
                && $0.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
                && !$0.unicodeScalars.contains { $0.properties.generalCategory == .control }
        }
    }
}
