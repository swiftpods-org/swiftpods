/// A semantic version as Swift Package Manager accepts it.
public struct Version: Sendable, Hashable, Comparable, Codable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let prerelease: [String]
    public let build: String?

    public init(_ major: Int, _ minor: Int, _ patch: Int, prerelease: [String] = [], build: String? = nil) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
        self.build = build
    }

    /// Accepts `1`, `1.2` and `1.2.3`, each with optional SemVer `-prerelease` and `+build` identifiers.
    public init?(_ text: String) {
        func isIdentifier(_ identifier: Substring) -> Bool {
            !identifier.isEmpty && identifier.utf8.allSatisfy { byte in
                byte == 45 || (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
            }
        }
        var rest = Substring(text)
        var build: String?
        if let plus = rest.firstIndex(of: "+") {
            let metadata = rest[rest.index(after: plus)...]
            rest = rest[..<plus]
            let identifiers = metadata.split(separator: ".", omittingEmptySubsequences: false)
            guard !identifiers.isEmpty, identifiers.allSatisfy(isIdentifier) else { return nil }
            build = String(metadata)
        }
        var prerelease: [String] = []
        if let dash = rest.firstIndex(of: "-") {
            let identifiers = rest[rest.index(after: dash)...].split(separator: ".", omittingEmptySubsequences: false)
            rest = rest[..<dash]
            guard !identifiers.isEmpty, identifiers.allSatisfy(isIdentifier) else {
                return nil
            }
            prerelease = identifiers.map(String.init)
        }
        let numbers = rest.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(numbers.count) else { return nil }
        var values: [Int] = []
        for number in numbers {
            guard !number.isEmpty, number.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(number) else {
                return nil
            }
            values.append(value)
        }
        while values.count < 3 { values.append(0) }
        self.init(values[0], values[1], values[2], prerelease: prerelease, build: build)
    }

    public var description: String {
        "\(major).\(minor).\(patch)" + (prerelease.isEmpty ? "" : "-" + prerelease.joined(separator: "."))
            + (build.map { "+" + $0 } ?? "")
    }

    public static func < (lhs: Version, rhs: Version) -> Bool {
        if (lhs.major, lhs.minor, lhs.patch) != (rhs.major, rhs.minor, rhs.patch) {
            return (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
        }
        // A prerelease sorts before its release; identifiers compare numerically when both are numbers.
        switch (lhs.prerelease.isEmpty, rhs.prerelease.isEmpty) {
        case (true, true), (true, false): return false
        case (false, true): return true
        case (false, false): break
        }
        for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
            let leftIsNumeric = left.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
            let rightIsNumeric = right.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
            switch (leftIsNumeric, rightIsNumeric) {
            case (true, true):
                let normalizedLeft = left.drop(while: { $0 == "0" })
                let normalizedRight = right.drop(while: { $0 == "0" })
                if normalizedLeft.count != normalizedRight.count { return normalizedLeft.count < normalizedRight.count }
                if normalizedLeft != normalizedRight { return normalizedLeft < normalizedRight }
                // SwiftPM accepts leading zeroes and treats numerically equal identifiers as equivalent for precedence.
                continue
            case (true, false): return true
            case (false, true): return false
            case (false, false): return left < right
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }

    public static func == (lhs: Version, rhs: Version) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(major)
        hasher.combine(minor)
        hasher.combine(patch)
        hasher.combine(prerelease.count)
        for identifier in prerelease {
            let numeric = identifier.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
            hasher.combine(numeric)
            if numeric {
                let normalized = identifier.drop(while: { $0 == "0" })
                hasher.combine(normalized.isEmpty ? "0" : String(normalized))
            } else {
                hasher.combine(identifier)
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let version = Version(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid version " + text))
        }
        self = version
    }
}

/// A version requirement in the forms Xcode stores in a project.
public enum Requirement: Sendable, Hashable, Codable, CustomStringConvertible {
    case exact(Version)
    case upToNextMajor(Version)
    case upToNextMinor(Version)
    /// Lower bound inclusive, upper bound exclusive.
    case range(Version, Version)
    case branch(String)
    case revision(String)

    public var description: String {
        switch self {
        case .exact(let version): "exactly \(version)"
        case .upToNextMajor(let version): "\(version) up to next major"
        case .upToNextMinor(let version): "\(version) up to next minor"
        case .range(let lower, let upper): "\(lower) ..< \(upper)"
        case .branch(let name): "branch \(name)"
        case .revision(let revision): "revision \(revision)"
        }
    }

    /// Whether a resolved version satisfies the requirement. Branches and revisions are checked by the caller.
    public func allows(_ version: Version) -> Bool {
        switch self {
        case .exact(let required): return version == required
        case .upToNextMajor(let lower):
            let (upperMajor, overflow) = lower.major.addingReportingOverflow(1)
            return version >= lower && (overflow || version < Version(upperMajor, 0, 0))
        case .upToNextMinor(let lower):
            let (upperMinor, overflow) = lower.minor.addingReportingOverflow(1)
            return version >= lower && (overflow ? version.major == lower.major : version < Version(lower.major, upperMinor, 0))
        case .range(let lower, let upper): return version >= lower && version < upper
        case .branch, .revision: return false
        }
    }

    /// Reads CocoaPods-style requirement strings: `'1.2.3'`, `'= 1.2.3'`, `'~> 1.2'`, `'~> 1.2.3'`,
    /// or a `'>= …'` and `'< …'` pair.
    static func parse(_ texts: [(String, SourceLocation)]) throws(ManifestError) -> Requirement {
        func version(_ text: Substring, at location: SourceLocation) throws(ManifestError) -> (Version, Int) {
            let trimmed = text.trimmingCharacters(in: " ")
            guard let version = Version(trimmed) else {
                throw ManifestError(
                    "'\(trimmed)' is not a version Swift Package Manager accepts", at: location,
                    hint: "Use at most three numeric components, for example 1.2.3")
            }
            let core = trimmed.split(separator: "-")[0].split(separator: "+")[0]
            return (version, core.split(separator: ".").count)
        }
        func split(_ text: String) -> (String, Substring) {
            let trimmed = Substring(text.trimmingCharacters(in: " "))
            for op in ["~>", ">=", "<=", "!=", "=", ">", "<"] where trimmed.hasPrefix(op) {
                return (op, trimmed.dropFirst(op.count))
            }
            return ("", trimmed)
        }
        if texts.count == 1 {
            let (text, location) = texts[0]
            let (op, rest) = split(text)
            switch op {
            case "", "=": return .exact(try version(rest, at: location).0)
            case "~>":
                let (value, components) = try version(rest, at: location)
                return components == 3 ? .upToNextMinor(value) : .upToNextMajor(value)
            case ">=":
                let lower = try version(rest, at: location).0
                let (nextMajor, overflow) = lower.major.addingReportingOverflow(1)
                throw ManifestError(
                    "'\(text)' has no upper bound", at: location,
                    hint: overflow
                        ? "Use an exact version at this upper boundary"
                        : "Add one, for example '\(text)', '< \(nextMajor).0'")
            default:
                throw ManifestError(
                    "'\(text)' cannot be expressed as a Swift package requirement", at: location,
                    hint: "Use an exact version, '~> x.y', '~> x.y.z' or a '>= x' and '< y' pair")
            }
        }
        if texts.count == 2 {
            let parts = texts.map { (split($0.0), $0.1) }
            let lower = parts.first { $0.0.0 == ">=" }
            let upper = parts.first { $0.0.0 == "<" }
            if let lower, let upper {
                let low = try version(lower.0.1, at: lower.1).0
                let high = try version(upper.0.1, at: upper.1).0
                guard low < high else {
                    throw ManifestError("The lower bound must be below the upper bound", at: lower.1)
                }
                return .range(low, high)
            }
        }
        throw ManifestError(
            "Unsupported combination of version requirements", at: texts.first?.1,
            hint: "Use one requirement, or a '>= x' and '< y' pair")
    }
}

extension Requirement {
    /// Reads requirements for packages with packed versions (see `CatalogEntry.VersionFormat.packed`):
    /// `'13.9.0.0'` is exactly 13090000.0.0, and `'~> 13.9.0.0'` is 13090000.0.0 ..< 13090100.0.0.
    static func parsePacked(_ texts: [(String, SourceLocation)]) throws(ManifestError) -> Requirement {
        func components(_ text: Substring, at location: SourceLocation) throws(ManifestError) -> [Int] {
            let parts = text.trimmingCharacters(in: " ").split(separator: ".", omittingEmptySubsequences: false)
            let values = parts.compactMap { part in part.allSatisfy(\.isNumber) ? Int(part) : nil }
            guard !parts.isEmpty, values.count == parts.count, values.dropFirst().allSatisfy({ $0 < 100 }), parts.count <= 9 else {
                throw ManifestError(
                    "'\(text.trimmingCharacters(in: " "))' is not a version this package publishes", at: location,
                    hint: "Write the version as the vendor does, for example 13.9.0.0")
            }
            return values
        }
        func pack(_ values: [Int], at location: SourceLocation) throws(ManifestError) -> Version {
            guard let first = values.first else {
                throw ManifestError("A packed version needs at least one component", at: location)
            }
            let text = String(first) + values.dropFirst().map { $0 < 10 ? "0\($0)" : "\($0)" }.joined()
            guard let packed = Int(text) else {
                throw ManifestError("The packed version is too large to represent", at: location)
            }
            return Version(packed, 0, 0)
        }
        func increment(_ value: Int, at location: SourceLocation) throws(ManifestError) -> Int {
            let (incremented, overflow) = value.addingReportingOverflow(1)
            guard !overflow else {
                throw ManifestError("The packed version's upper bound is too large to represent", at: location)
            }
            return incremented
        }
        func split(_ text: String) -> (String, Substring) {
            let trimmed = Substring(text.trimmingCharacters(in: " "))
            for op in ["~>", ">=", "<=", "!=", "=", ">", "<"] where trimmed.hasPrefix(op) {
                return (op, trimmed.dropFirst(op.count))
            }
            return ("", trimmed)
        }
        if texts.count == 1 {
            let (text, location) = texts[0]
            let (op, rest) = split(text)
            let values = try components(rest, at: location)
            switch op {
            case "", "=": return .exact(try pack(values, at: location))
            case "~>":
                // As in CocoaPods: the last written component may grow, the one before it may not.
                var upper = Array(values.dropLast())
                if upper.isEmpty {
                    upper = [try increment(values[0], at: location)]
                } else {
                    upper[upper.count - 1] = try increment(upper[upper.count - 1], at: location)
                }
                upper += Array(repeating: 0, count: values.count - upper.count)
                return .range(try pack(values, at: location), try pack(upper, at: location))
            default: break
            }
        } else if texts.count == 2 {
            let parts = texts.map { (split($0.0), $0.1) }
            if let lower = parts.first(where: { $0.0.0 == ">=" }), let upper = parts.first(where: { $0.0.0 == "<" }) {
                let low = try pack(try components(lower.0.1, at: lower.1), at: lower.1)
                let high = try pack(try components(upper.0.1, at: upper.1), at: upper.1)
                guard low < high else { throw ManifestError("The lower bound must be below the upper bound", at: lower.1) }
                return .range(low, high)
            }
        }
        throw ManifestError(
            "Unsupported version requirement for a package with packed versions", at: texts.first?.1,
            hint: "Use an exact version such as '13.9.0.0', '~> 13.9.0.0', or a '>= x' and '< y' pair")
    }
}

extension StringProtocol {
    func trimmingCharacters(in character: Character) -> String {
        var slice = Substring(self)
        while slice.first == character { slice = slice.dropFirst() }
        while slice.last == character { slice = slice.dropLast() }
        return String(slice)
    }
}
