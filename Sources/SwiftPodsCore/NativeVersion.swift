import Foundation

/// Pod versions preserve their spelling while comparing numeric components
/// without integer overflow and normalizing zeros before prerelease components.
struct PodVersion: Comparable, Hashable, CustomStringConvertible {
    private enum Segment: Comparable, Hashable {
        case number(String)
        case text(String)

        init(_ value: String) {
            if value.allSatisfy(\.isNumber) {
                let trimmed = value.drop(while: { $0 == "0" })
                self = .number(trimmed.isEmpty ? "0" : String(trimmed))
            } else {
                self = .text(value)
            }
        }

        var isNumber: Bool {
            if case .number = self { return true }
            return false
        }

        var spelling: String {
            switch self {
            case .number(let value), .text(let value): return value
            }
        }

        static func < (lhs: Self, rhs: Self) -> Bool {
            switch (lhs, rhs) {
            case (.number(let left), .number(let right)):
                if left.count != right.count { return left.count < right.count }
                return left.lexicographicallyPrecedes(right)
            case (.text(let left), .text(let right)):
                return left < right
            case (.text, .number): return true
            case (.number, .text): return false
            }
        }
    }

    let description: String
    private let releaseSegments: [Segment]
    private let comparisonSegments: [Segment]
    let isPrerelease: Bool

    init(_ value: String) throws {
        guard value.range(of: #"\A[0-9]+(?:\.[0-9A-Za-z]+)*(?:-[0-9A-Za-z.]+)?\z"#, options: .regularExpression) != nil
        else {
            throw Diagnostic("SP-SPEC-VERSION", stage: "resolve", "Invalid pod version: \(value)")
        }
        description = value
        let normalized = value.replacingOccurrences(of: "-", with: ".pre.")
        let expression = try NSRegularExpression(pattern: "[0-9]+|[A-Za-z]+")
        let segments = expression.matches(in: normalized, range: NSRange(normalized.startIndex..., in: normalized))
            .compactMap {
                Range($0.range, in: normalized).map { Segment(String(normalized[$0])) }
            }
        releaseSegments = Array(segments.prefix(while: \.isNumber))
        let prerelease = Array(segments.dropFirst(releaseSegments.count))
        isPrerelease = !prerelease.isEmpty
        comparisonSegments = Self.trimZeros(releaseSegments) + Self.trimZeros(prerelease)
    }

    private init(releaseSegments: [Segment]) {
        description = releaseSegments.map(\.spelling).joined(separator: ".")
        self.releaseSegments = releaseSegments
        comparisonSegments = Self.trimZeros(releaseSegments)
        isPrerelease = false
    }

    var release: Self { Self(releaseSegments: releaseSegments) }

    /// Precision comes from the declared numeric components, including a digit
    /// component immediately followed by a prerelease letter, as in 1.2.3a.
    func pessimisticUpperBound() throws -> Self {
        var numbers = releaseSegments.map(\.spelling)
        if numbers.count > 1 { numbers.removeLast() }
        let last = numbers.count - 1
        var digits = Array(numbers[last].utf8)
        var carry: UInt8 = 1
        for index in digits.indices.reversed() {
            let value = digits[index] - 48 + carry
            digits[index] = value % 10 + 48
            carry = value / 10
            if carry == 0 { break }
        }
        if carry != 0 { digits.insert(49, at: 0) }
        numbers[last] = String(decoding: digits, as: UTF8.self)
        return try Self(numbers.joined(separator: "."))
    }

    private static func trimZeros(_ segments: [Segment]) -> [Segment] {
        var result = segments
        while result.last == .number("0") { result.removeLast() }
        return result
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.comparisonSegments == rhs.comparisonSegments
    }

    func hash(into hasher: inout Hasher) { hasher.combine(comparisonSegments) }

    static func < (lhs: Self, rhs: Self) -> Bool {
        for index in 0..<max(lhs.comparisonSegments.count, rhs.comparisonSegments.count) {
            let left = index < lhs.comparisonSegments.count ? lhs.comparisonSegments[index] : .number("0")
            let right = index < rhs.comparisonSegments.count ? rhs.comparisonSegments[index] : .number("0")
            if left != right { return left < right }
        }
        return false
    }
}

struct PodRequirement {
    private enum Relation: String {
        case equal = "="
        case notEqual = "!="
        case greater = ">"
        case atLeast = ">="
        case less = "<"
        case atMost = "<="
        case pessimistic = "~>"
    }

    private struct Clause {
        let relation: Relation
        let version: PodVersion
        let upperBound: PodVersion?

        func accepts(_ candidate: PodVersion) -> Bool {
            switch relation {
            case .equal: return candidate == version
            case .notEqual: return candidate != version
            case .greater: return candidate > version
            case .atLeast: return candidate >= version
            case .less: return candidate < version
            case .atMost: return candidate <= version
            case .pessimistic:
                guard let upperBound else { return false }
                return candidate >= version && candidate.release < upperBound
            }
        }
    }

    private let clauses: [Clause]
    let allowsPrerelease: Bool

    init(_ strings: [String]) throws {
        let expression = try NSRegularExpression(pattern: #"\A\s*(~>|>=|<=|!=|=|>|<)?\s*([^\s]+)\s*\z"#)
        var parsed: [Clause] = []
        for text in (strings.isEmpty ? [">= 0"] : strings).flatMap({
            $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        }) {
            guard let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                let range = Range(match.range(at: 2), in: text)
            else {
                throw Diagnostic("SP-SPEC-REQUIREMENT", stage: "resolve", "Invalid version requirement: \(text)")
            }
            let operation = Range(match.range(at: 1), in: text).map { String(text[$0]) } ?? "="
            guard let relation = Relation(rawValue: operation) else {
                throw Diagnostic("SP-SPEC-REQUIREMENT", stage: "resolve", "Invalid version requirement: \(text)")
            }
            let version = try PodVersion(String(text[range]))
            let upperBound = relation == .pessimistic ? try version.pessimisticUpperBound() : nil
            parsed.append(Clause(relation: relation, version: version, upperBound: upperBound))
        }
        clauses = parsed
        allowsPrerelease = parsed.contains { $0.version.isPrerelease }
    }

    func accepts(_ version: PodVersion) -> Bool { clauses.allSatisfy { $0.accepts(version) } }
}
