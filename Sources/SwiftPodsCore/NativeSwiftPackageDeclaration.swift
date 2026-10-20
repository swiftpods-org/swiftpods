import Foundation

/// Validate the package DSL before hooks or Xcode project mutations.
struct NativeSwiftPackageDeclaration {
    let url: String
    let requirement: [String: String]
    let products: [String]
    let link: Bool

    static func list(_ value: Any?, file: String? = nil) throws -> [Self] {
        guard let value, !(value is NSNull) else { return [] }
        guard let entries = value as? [[String: Any]] else {
            throw Diagnostic("SP-SPM-DECLARATION", stage: "analyze", "Swift packages must be objects", file: file)
        }
        return try entries.map { try Self($0, file: file) }
    }

    init(_ data: [String: Any], file: String? = nil) throws {
        func invalid(_ code: String, _ message: String) -> Diagnostic {
            Diagnostic(code, stage: "analyze", message, file: file)
        }
        func text(_ value: Any?) -> String? {
            guard let value = value as? String,
                !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                value.rangeOfCharacter(from: .controlCharacters) == nil
            else { return nil }
            return value
        }
        let selectors = ["exact", "from", "range", "branch", "revision"]
        let allowed = Set(selectors + ["name", "git", "products", "link"])
        guard Set(data.keys).isSubset(of: allowed) else {
            throw invalid(
                "SP-SPM-OPTION",
                "Unknown Swift package options: " + Set(data.keys).subtracting(allowed).sorted().joined(separator: ", ")
            )
        }
        if let name = data["name"], text(name) == nil {
            throw invalid("SP-SPM-NAME", "Swift package names must be nonempty strings")
        }
        guard let url = text(data["git"]) else {
            throw invalid("SP-SPM-URL", "Swift packages require a nonempty :git string")
        }
        self.url = url
        if let value = data["link"] {
            guard let value = NativeScalarString.boolean(value) else {
                throw invalid("SP-SPM-LINK", "Swift package :link must be a boolean")
            }
            link = value
        } else {
            link = true
        }
        let keys = selectors.filter { data[$0] != nil && !(data[$0] is NSNull) }
        guard keys.count == 1 else {
            throw invalid("SP-SPM-REQUIREMENT", "Specify one Swift package requirement")
        }
        let key = keys[0]
        if key == "range" {
            guard let bounds = data[key] as? [String], bounds.count == 2,
                let lower = NativeSwiftPackageVersion(bounds[0]), let upper = NativeSwiftPackageVersion(bounds[1]),
                lower < upper
            else { throw invalid("SP-SPM-REQUIREMENT", "Swift package range needs two increasing versions") }
            requirement = ["kind": "versionRange", "minimumVersion": bounds[0], "maximumVersion": bounds[1]]
        } else {
            guard let value = text(data[key]) else {
                throw invalid("SP-SPM-REQUIREMENT", "Swift package " + key + " must be a nonempty string")
            }
            if ["exact", "from"].contains(key) {
                guard let version = NativeSwiftPackageVersion(value), key != "from" || version.major < Int.max else {
                    throw invalid("SP-SPM-REQUIREMENT", "Invalid Swift package version")
                }
            }
            let fields = [
                "exact": ("exactVersion", "version"), "from": ("upToNextMajorVersion", "minimumVersion"),
                "branch": ("branch", "branch"), "revision": ("revision", "revision"),
            ]
            let field = fields[key]!
            requirement = ["kind": field.0, field.1: value]
        }
        if data["products"] == nil || data["products"] is NSNull {
            products = []
        } else {
            let values = (data["products"] as? String).map { [$0] } ?? (data["products"] as? [String])
            guard let values, values.allSatisfy({ text($0) != nil }) else {
                throw invalid("SP-SPM-PRODUCTS", "Swift package products must be nonempty name strings")
            }
            products = values
        }
    }
}

/// PackageDescription's version spelling and ordering, independent of pod versions.
struct NativeSwiftPackageVersion: Comparable {
    private let release: [Int]
    private let prerelease: [String]?
    var major: Int { release[0] }

    init?(_ value: String) {
        guard
            value.range(
                of: #"\A[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]*)?(?:\+[0-9A-Za-z.-]*)?\z"#,
                options: .regularExpression) != nil
        else { return nil }
        let body = value.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)[0]
        let parts = body.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let release = parts[0].split(separator: ".").compactMap { Int($0) }
        guard release.count == 3 else { return nil }
        self.release = release
        prerelease = parts.count == 1 ? nil : String(parts[1]).components(separatedBy: ".")
    }

    static func == (lhs: Self, rhs: Self) -> Bool { compare(lhs, rhs) == 0 }
    static func < (lhs: Self, rhs: Self) -> Bool { compare(lhs, rhs) < 0 }

    private static func compare(_ lhs: Self, _ rhs: Self) -> Int {
        if lhs.release != rhs.release { return lhs.release.lexicographicallyPrecedes(rhs.release) ? -1 : 1 }
        guard let left = lhs.prerelease else { return rhs.prerelease == nil ? 0 : 1 }
        guard let right = rhs.prerelease else { return -1 }
        for (a, b) in zip(left, right) where a != b {
            switch (Int(a), Int(b)) {
            case (let x?, let y?):
                if x != y { return x < y ? -1 : 1 }
            case (_?, nil): return -1
            case (nil, _?): return 1
            case (nil, nil): return a < b ? -1 : 1
            }
        }
        return left.count == right.count ? 0 : (left.count < right.count ? -1 : 1)
    }
}
