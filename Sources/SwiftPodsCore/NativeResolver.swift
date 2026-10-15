import Foundation

struct PodVersion: Comparable, Hashable, CustomStringConvertible {
    let description: String
    private let parts: [String]
    var isPrerelease: Bool { parts.contains { !$0.allSatisfy(\.isNumber) } }
    init(_ value: String) throws {
        guard value.range(of: #"\A[0-9]+(?:\.[0-9A-Za-z]+)*(?:-[0-9A-Za-z.]+)?\z"#, options: .regularExpression) != nil else {
            throw Diagnostic("SP-SPEC-VERSION", stage: "resolve", "Invalid pod version: \(value)")
        }
        description = value
        let normalized = value.replacingOccurrences(of: "-", with: ".pre.")
        let expression = try NSRegularExpression(pattern: "[0-9]+|[A-Za-z]+")
        parts = expression.matches(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)).compactMap {
            Range($0.range, in: normalized).map { String(normalized[$0]) }
        }
    }
    static func == (lhs: Self, rhs: Self) -> Bool { !(lhs < rhs) && !(rhs < lhs) }
    func hash(into hasher: inout Hasher) {
        var normalized = parts.map { part in
            if part.allSatisfy(\.isNumber) { let trimmed = part.drop(while: { $0 == "0" }); return trimmed.isEmpty ? "0" : String(trimmed) }
            return part
        }
        while normalized.last == "0" { normalized.removeLast() }
        hasher.combine(normalized)
    }
    static func < (lhs: Self, rhs: Self) -> Bool {
        for index in 0..<max(lhs.parts.count, rhs.parts.count) {
            let a = index < lhs.parts.count ? lhs.parts[index] : "0"
            let b = index < rhs.parts.count ? rhs.parts[index] : "0"
            if a == b { continue }
            let aNumeric = a.allSatisfy(\.isNumber), bNumeric = b.allSatisfy(\.isNumber)
            if aNumeric && bNumeric {
                let x = a.drop(while: { $0 == "0" }), y = b.drop(while: { $0 == "0" })
                if x.count != y.count { return x.count < y.count }
                if x != y { return x.lexicographicallyPrecedes(y) }
            } else if aNumeric != bNumeric { return !aNumeric }
            else { return a < b }
        }
        return false
    }
}

struct PodRequirement {
    private let clauses: [(String, PodVersion, PodVersion?)]
    let allowsPrerelease: Bool
    init(_ strings: [String]) throws {
        var parsed: [(String, PodVersion, PodVersion?)] = []
        for text in (strings.isEmpty ? [">= 0"] : strings).flatMap({ $0.split(separator: ",").map(String.init) }) {
            let pattern = #"\A\s*(~>|>=|<=|!=|=|>|<)?\s*([^\s]+)\s*\z"#
            let expression = try NSRegularExpression(pattern: pattern)
            guard let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 2), in: text) else { throw Diagnostic("SP-SPEC-REQUIREMENT", stage: "resolve", "Invalid version requirement: \(text)") }
            let operation = Range(match.range(at: 1), in: text).map { String(text[$0]) } ?? "="
            let value = String(text[range]), version = try PodVersion(value)
            var upper: PodVersion?
            if operation == "~>" {
                var numbers = value.split(whereSeparator: { $0 == "." || $0 == "-" }).prefix(while: { !$0.isEmpty && $0.allSatisfy(\.isNumber) }).map(String.init)
                guard !numbers.isEmpty else { throw Diagnostic("SP-SPEC-REQUIREMENT", stage: "resolve", "Invalid pessimistic requirement") }
                let bump = max(0, numbers.count - 2)
                var digits = Array(numbers[bump].utf8), carry: UInt8 = 1
                for index in digits.indices.reversed() {
                    let digit = digits[index] - 48 + carry
                    digits[index] = digit % 10 + 48; carry = digit / 10
                    if carry == 0 { break }
                }
                if carry != 0 { digits.insert(49, at: 0) }
                numbers[bump] = String(decoding: digits, as: UTF8.self)
                numbers = Array(numbers.prefix(bump + 1))
                upper = try PodVersion(numbers.joined(separator: "."))
            }
            parsed.append((operation, version, upper))
        }
        clauses = parsed; allowsPrerelease = parsed.contains { $0.1.isPrerelease }
    }
    func accepts(_ version: PodVersion) -> Bool {
        clauses.allSatisfy { operation, expected, upper in
            switch operation {
            case "=": return version == expected
            case "!=": return version != expected
            case ">": return version > expected
            case ">=": return version >= expected
            case "<": return version < expected
            case "<=": return version <= expected
            case "~>": return version >= expected && version < upper!
            default: return false
            }
        }
    }
}

struct NativeDependency {
    let name: String
    let requirements: [String]
    var options: [String: Any] = [:]
    var platform = "ios"
    var deployment = "0"
    var chain: [String] = []
    var root: String { String(name.split(separator: "/").first ?? "") }
    var external: Bool { ["path", "git", "podspec", "http", "svn", "hg"].contains { options[$0] != nil } }
    init(_ value: [String: Any], platform: String = "ios", deployment: String = "0") throws {
        guard let name = value["name"] as? String,
              name.range(of: #"\A[A-Za-z0-9_+.-]+(?:/[A-Za-z0-9_+.-]+)*\z"#, options: .regularExpression) != nil,
              !name.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw Diagnostic("SP-SPEC-NAME", stage: "resolve", "Invalid dependency name")
        }
        guard value["requirements"] == nil || value["requirements"] is [String] else { throw Diagnostic("SP-SPEC-REQUIREMENT", stage: "resolve", "Version requirements must be strings", file: name) }
        self.name = name; requirements = value["requirements"] as? [String] ?? [">= 0"]
        options = value["options"] as? [String: Any] ?? [:]
        let known: Set<String> = ["path", "git", "podspec", "http", "svn", "hg", "tag", "branch", "commit", "revision", "folder", "submodules", "flatten", "type", "sha256", "sha1", "headers", "source", "subspecs", "testspecs", "appspecs", "configurations", "configuration", "inhibit_warnings", "modular_headers", "project_name"]
        if let unknown = Set(options.keys).subtracting(known).sorted().first { throw Diagnostic("SP-DSL-POD-OPTION", stage: "resolve", "Unknown pod option: " + unknown, file: name) }
        for key in ["path", "git", "podspec", "http", "svn", "hg", "tag", "branch", "commit", "folder", "source", "project_name"] where options[key] != nil && !(options[key] is String) { throw Diagnostic("SP-DSL-POD-OPTION", stage: "resolve", key + " must be a string", file: name) }
        for key in ["submodules", "flatten", "inhibit_warnings", "modular_headers"] {
            if let value = options[key], CFGetTypeID(value as CFTypeRef) != CFBooleanGetTypeID() { throw Diagnostic("SP-DSL-POD-OPTION", stage: "resolve", key + " must be boolean", file: name) }
        }
        for key in ["subspecs", "testspecs", "appspecs", "configurations", "configuration"] where options[key] != nil && !(options[key] is String) && !(options[key] is [String]) { throw Diagnostic("SP-DSL-POD-OPTION", stage: "resolve", key + " must contain names", file: name) }
        if let headers = options["headers"], !(headers is [String: String]) { throw Diagnostic("SP-DSL-POD-OPTION", stage: "resolve", "HTTP headers must map names to strings", file: name) }
        self.platform = platform; self.deployment = deployment
        _ = try PodRequirement(requirements)
    }
}

struct NativeSpec {
    let data: [String: Any]
    let version: PodVersion
    let repository: String
    let checksum: String?
    var directory: URL?
    var local: Bool
    var checkout: [String: String] = [:]
    var name: String { data["name"] as! String }
    var moduleName: String {
        let value = data["module_name"] as? String ?? data["header_dir"] as? String ?? name
        var normalized = value.replacingOccurrences(of: "[^A-Za-z0-9_]", with: "_", options: .regularExpression)
        if normalized.first?.isNumber == true { normalized = "_" + normalized }
        return normalized
    }
    init(data: [String: Any], repository: String = "", directory: URL? = nil, local: Bool = false, checksum: String? = nil) throws {
        try NativeSpecSchema.validate(data)
        guard let name = data["name"] as? String, !name.isEmpty, !name.contains("/"),
              name.range(of: #"\A[A-Za-z0-9_+.-]+\z"#, options: .regularExpression) != nil,
              name != ".", name != "..", let version = data["version"] as? String else {
            throw Diagnostic("SP-SPEC-SCHEMA", stage: "resolve", "Podspec requires a valid root name and version")
        }
        self.data = data; self.version = try PodVersion(version)
        if let required = data["cocoapods_version"] as? String, try !PodRequirement([required]).accepts(PodVersion("1.17.0")) { throw Diagnostic("SP-SPEC-PROFILE", stage: "resolve", "Specification requires a newer compatibility profile", file: name) }
        if let module = data["module_name"] as? String, module.range(of: #"\A[A-Za-z_][A-Za-z0-9_]*\z"#, options: .regularExpression) == nil { throw Diagnostic("SP-SPEC-MODULE", stage: "resolve", "module_name must be a C99 identifier", file: name) }
        self.repository = repository; self.directory = directory; self.local = local; self.checksum = checksum
    }
    func attributes(_ fullname: String, platform: String) throws -> [String: Any] {
        try supplementaryAttributes(fullname, platform: platform)
    }

    static func merge(_ parent: [String: Any], _ child: [String: Any]) -> [String: Any] {
        var merged = parent
        for (key, value) in child {
            if ["platforms", "info_plist"].contains(key), let a = parent[key] as? [String: Any], let b = value as? [String: Any] {
                merged[key] = key == "platforms" ? b : a.merging(b) { _, new in new }
            } else if ["xcconfig", "pod_target_xcconfig", "user_target_xcconfig", "resource_bundles"].contains(key), let a = parent[key] as? [String: Any], let b = value as? [String: Any] {
                merged[key] = a.merging(b) { old, new in
                    if key == "resource_bundles" || old is [Any] || new is [Any] { return nativeStrings(old) + nativeStrings(new) }
                    return String(describing: old) + " " + String(describing: new)
                }
            } else if key == "dependencies", let a = parent[key] as? [String: Any], let b = value as? [String: Any] {
                var dependencies = a
                for (name, requirements) in b { dependencies[name] = nativeStrings(a[name]) + nativeStrings(requirements) }
                merged[key] = dependencies
            } else if let a = parent[key] as? [String: Any], let b = value as? [String: Any] { merged[key] = merge(a, b) }
            else if NativeAttributeContract.arrays.contains(key), let before = parent[key] {
                merged[key] = nativeStrings(before) + nativeStrings(value)
            } else { merged[key] = value }
        }
        return merged
    }
    func dependencies(for request: NativeDependency) throws -> [NativeDependency] {
        let attributes = try attributes(request.name, platform: request.platform)
        if let platforms = attributes["platforms"] as? [String: Any], !platforms.isEmpty, platforms[request.platform] == nil { throw Diagnostic("SP-PLATFORM-CONFLICT", stage: "resolve", "\(request.name) does not support \(request.platform)") }
        let minimum = (attributes["platforms"] as? [String: Any])?[request.platform] as? String ?? attributes["deployment_target"] as? String ?? (attributes[request.platform] as? [String: Any])?["deployment_target"] as? String
        if try kind(request.name) == .library, let minimum, let requested = try? PodVersion(request.deployment), try PodVersion(minimum) > requested {
            throw Diagnostic("SP-PLATFORM-CONFLICT", stage: "resolve", "\(request.name) requires \(request.platform) \(minimum), target uses \(request.deployment)")
        }
        var dependencies = try (attributes["dependencies"] as? [String: Any] ?? [:]).sorted(by: { $0.key < $1.key }).map { name, constraints in
            try NativeDependency(["name": name, "requirements": nativeStrings(constraints)], platform: request.platform, deployment: request.deployment)
        }
        let node = try nodes(request.name).last!.data
        let defaults = nativeStrings(node["default_subspecs"] ?? node["default_subspec"])
        let children = defaults.isEmpty ? (node["subspecs"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String } : defaults.filter { $0 != "none" }
        dependencies += try children.map { try NativeDependency(["name": request.name + "/" + $0, "requirements": ["= " + version.description]], platform: request.platform, deployment: request.deployment) }

        return dependencies
    }
}

func nativeStrings(_ value: Any?) -> [String] {
    if let value = value as? String { return [value] }
    return (value as? [Any] ?? []).compactMap { $0 as? String }
}

struct NativeResolution {
    let specs: [String: NativeSpec]
    let requests: [NativeDependency]
}

struct NativeResolver {
    var candidates: (NativeDependency) throws -> [NativeSpec]
    var materialize: (NativeSpec) throws -> NativeSpec = { $0 }
    var locked: [String: String] = [:]
    var update = Set<String>()
    func resolve(_ dependencies: [NativeDependency]) throws -> NativeResolution {
        var failure: Error?
        var conflicts = Set<String>()
        func search(_ queue: [NativeDependency], selected: [String: NativeSpec], expanded: Set<String>, requests: [NativeDependency]) throws -> NativeResolution? {
            try NativeCancellation.check()
            guard !queue.isEmpty else {
                for (root, spec) in selected where spec.version.isPrerelease {
                    let allowed = requests.contains { request in request.root == root && (request.external || (try? PodRequirement(request.requirements).allowsPrerelease) == true) }
                    if !allowed { return nil }
                }
                return NativeResolution(specs: selected, requests: requests)
            }
            // The profile activates existing, external, prerelease and previously
            // conflicting requirements first, then the most constrained set.
            var ordered: [(index: Int, request: NativeDependency, score: [Int])] = []
            for (index, candidate) in queue.enumerated() {
                let requirement = try PodRequirement(candidate.requirements)
                let pin = update.contains(candidate.root) ? nil : try locked[candidate.root].map(PodVersion.init)
                let possible = try (selected[candidate.root].map { [$0] } ?? candidates(candidate)).filter { spec in
                    requirement.accepts(spec.version) && (pin == nil || spec.version == pin) && dependencies.filter { $0.root == candidate.root }.allSatisfy { (try? PodRequirement($0.requirements).accepts(spec.version)) == true }
                }.count
                ordered.append((index, candidate, [requests.contains { $0.name == candidate.name } ? 0 : 1, candidate.external ? 0 : 1, requirement.allowsPrerelease ? 0 : 1, conflicts.contains(candidate.name) ? 0 : 1, possible, index]))
            }
            ordered.sort { $0.score.lexicographicallyPrecedes($1.score) }
            let first = ordered[0], request = first.request
            var remainder = queue; remainder.remove(at: first.index)
            let requirement = try PodRequirement(request.requirements)
            let choices: [NativeSpec]
            if let existing = selected[request.root] { choices = [existing] }
            else {
                let found = try candidates(request)
                choices = found.sorted {
                    let pin = update.contains(request.root) ? nil : locked[request.root]
                    if ($0.version.description == pin) != ($1.version.description == pin) { return $0.version.description == pin }
                    return $0.version > $1.version
                }
            }
            let pin = update.contains(request.root) ? nil : try locked[request.root].map(PodVersion.init)
            for spec in choices where requirement.accepts(spec.version) && (pin == nil || spec.version == pin) {
                try NativeCancellation.check()
                let spec = try materialize(spec)
                var chosen = selected; chosen[request.root] = spec
                let key = request.name + ":" + request.platform + ":" + request.deployment
                if expanded.contains(key) {
                    if let value = try search(remainder, selected: chosen, expanded: expanded, requests: requests + [request]) { return value }
                    continue
                }
                do {
                    try spec.validateSupplementary(request)
                    let more = try spec.dependencies(for: request).map { dependency -> NativeDependency in
                        var child = dependency; child.chain = request.chain + [request.name]; return child
                    }
                    if let value = try search(more + remainder, selected: chosen, expanded: expanded.union([key]), requests: requests + [request]) { return value }
                } catch let error as Diagnostic where ["SP-SPEC-SUBSPEC", "SP-PLATFORM-CONFLICT"].contains(error.code) { failure = error }
            }
            conflicts.insert(request.name)
            if (failure as? Diagnostic)?.dependencyChain.count ?? 0 <= request.chain.count {
                failure = Diagnostic("SP-RESOLVE-CONFLICT", stage: "resolve", "No compatible version for \(request.name) (\(request.requirements.joined(separator: ", ")))" + (pin.map { "; locked at " + $0.description } ?? ""), dependencyChain: request.chain + [request.name])
            }
            return nil
        }
        if let result = try search(dependencies, selected: [:], expanded: [], requests: []) { return result }
        throw failure ?? Diagnostic("SP-RESOLVE-CONFLICT", stage: "resolve", "Dependency constraints cannot be satisfied")
    }
}
