import Foundation

/// Pod versions preserve their spelling while comparing numeric components
/// without integer overflow. Only release components normalize trailing zeros.
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
            case (.text, .number): return false
            case (.number, .text): return true
            }
        }
    }

    let description: String
    private let releaseSegments: [Segment]
    private let canonicalRelease: [Segment]
    private let prereleaseSegments: [Segment]?
    let isPrerelease: Bool

    init(_ value: String) throws {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            value.range(of: #"\A[0-9]+(?:\.[0-9A-Za-z-]++)*(?:\+[0-9A-Za-z.-]+)?\z"#, options: .regularExpression)
                != nil
        else {
            throw Diagnostic("SP-SPEC-VERSION", stage: "resolve", "Invalid pod version: \(value)")
        }
        description = value
        // Build metadata is retained for serialization but has no version precedence.
        let comparable = String(value.split(separator: "+", maxSplits: 1)[0])
        // CocoaPods classifies hyphenated versions as prereleases, while numeric
        // segments before the first letter still contribute to release precedence.
        isPrerelease = comparable.contains { $0.isLetter || $0 == "-" }
        let expression = try NSRegularExpression(pattern: "[0-9]+|[A-Za-z]+")
        func tokenize(_ text: String) -> [Segment] {
            expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
                Range($0.range, in: text).map { Segment(String(text[$0])) }
            }
        }
        let segments = tokenize(comparable)
        releaseSegments = Array(segments.prefix(while: \.isNumber))
        let prerelease = Array(segments.dropFirst(releaseSegments.count))
        prereleaseSegments = prerelease.isEmpty ? nil : prerelease
        canonicalRelease = Self.trimZeros(releaseSegments)
    }

    private init(releaseSegments: [Segment]) {
        description = releaseSegments.map(\.spelling).joined(separator: ".")
        self.releaseSegments = releaseSegments
        canonicalRelease = Self.trimZeros(releaseSegments)
        prereleaseSegments = nil
        isPrerelease = false
    }

    var release: Self { Self(releaseSegments: releaseSegments) }

    /// Keep precedence semantic, but select a deterministic spelling for equal versions.
    func isPreferred(to other: Self) -> Bool {
        self == other ? description > other.description : self > other
    }

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
        lhs.canonicalRelease == rhs.canonicalRelease && lhs.prereleaseSegments == rhs.prereleaseSegments
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(canonicalRelease)
        hasher.combine(prereleaseSegments)
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.canonicalRelease != rhs.canonicalRelease {
            return lhs.canonicalRelease.lexicographicallyPrecedes(rhs.canonicalRelease)
        }
        switch (lhs.prereleaseSegments, rhs.prereleaseSegments) {
        case (nil, _): return false
        case (_, nil): return true
        case (.some(let left), .some(let right)):
            return left.lexicographicallyPrecedes(right)
        }
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
