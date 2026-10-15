import CryptoKit
import Foundation

struct NativeLock {
    let path: URL
    let originalFingerprint: String
    let raw: [String: Any]
    let versions: [String: String]
    let checksum: String?
    let specChecksums: [String: String]
    let manifestChecksum: String?
    let checkoutOptions: [String: [String: String]]
    let externalSources: [String: [String: Any]]
    let repositories: [String: String]
    let declarations: [String: [String]]
    let dependencies: [String: Set<String>]
    let lockingDependencies: [String: Set<String>]
    init(_ path: URL) throws {
        self.path = path
        originalFingerprint = try FileFingerprint.tree(path)
        let data =
            FileManager.default.fileExists(atPath: path.path)
            ? try NativeYAML.object(String(contentsOf: path, encoding: .utf8), file: path.path) : [:]
        guard try FileFingerprint.tree(path) == originalFingerprint else {
            throw Diagnostic("SP-LOCK-CONFLICT", stage: "resolve", "Lockfile changed while reading", file: path.path)
        }
        raw = data
        func strings(_ value: Any?) -> [String: String] {
            (value as? [String: Any] ?? [:]).reduce(into: [:]) { result, entry in
                if let value = entry.value as? String {
                    result[entry.key] = value
                } else if let value = entry.value as? NSNumber {
                    result[entry.key] =
                        CFGetTypeID(value) == CFBooleanGetTypeID()
                        ? (value.boolValue ? "true" : "false") : value.stringValue
                }
            }
        }
        func sourceKeys<Value>(_ values: [String: Value]) throws -> [String: Value] {
            var normalized: [String: Value] = [:]
            for (key, value) in values.sorted(by: { $0.key < $1.key }) {
                let name = String(key.drop(while: { $0 == ":" }))
                guard normalized[name] == nil else {
                    throw Diagnostic(
                        "SP-LOCK-SCHEMA", stage: "resolve", "Duplicate source option " + name, file: path.path)
                }
                normalized[name] = value
            }
            return normalized
        }
        func sourceMap(_ value: Any?) throws -> [String: [String: String]] {
            try (value as? [String: Any] ?? [:]).mapValues { try sourceKeys(strings($0)) }
        }
        func declaration(_ value: String) -> (String, [String]) {
            guard let open = value.range(of: " ("), value.hasSuffix(")") else { return (value, [">= 0"]) }
            let requirement = String(value[open.upperBound..<value.index(before: value.endIndex)])
            return (
                String(value[..<open.lowerBound]),
                requirement.hasPrefix("from ") ? [">= 0"] : requirement.components(separatedBy: ", ")
            )
        }
        var pins: [String: String] = [:]
        var edges: [String: Set<String>] = [:]
        var lockingEdges: [String: Set<String>] = [:]
        var lockingStrings = Set<String>()
        func pod(_ value: Any) throws {
            let name: String
            let children: [Any]
            if let value = value as? String {
                name = value
                children = []
            } else if let value = value as? [String: Any], value.count == 1, let entry = value.first,
                let values = entry.value as? [Any]
            {
                name = entry.key
                children = values
            } else {
                throw Diagnostic("SP-LOCK-SCHEMA", stage: "resolve", "Invalid PODS entry", file: path.path)
            }
            let (full, requirements) = declaration(name)
            let root = String(full.split(separator: "/").first ?? "")
            guard requirements.count == 1, let version = requirements.first, (try? PodVersion(version)) != nil else {
                throw Diagnostic("SP-LOCK-SCHEMA", stage: "resolve", "Invalid locked version", file: path.path)
            }
            if let previous = pins[root], try PodVersion(previous) != PodVersion(version) {
                throw Diagnostic(
                    "SP-LOCK-SCHEMA", stage: "resolve", "Multiple locked versions of " + root, file: path.path)
            }
            pins[root] = version
            lockingStrings.insert(name)
            for child in children {
                guard let text = child as? String else {
                    throw Diagnostic("SP-LOCK-SCHEMA", stage: "resolve", "Invalid locked dependency", file: path.path)
                }
                let childRoot = String(declaration(text).0.split(separator: "/").first ?? "")
                edges[root, default: []].insert(childRoot)
                // The selected baseline deduplicates dependency strings before
                // attaching lock-graph edges. Keep the full graph separately.
                if lockingStrings.insert(text).inserted { lockingEdges[root, default: []].insert(childRoot) }
            }
        }
        if let pods = data["PODS"], !(pods is NSNull) {
            guard let pods = pods as? [Any] else {
                throw Diagnostic("SP-LOCK-SCHEMA", stage: "resolve", "PODS must be a sequence", file: path.path)
            }
            for entry in pods { try pod(entry) }
        }
        var sources: [String: String] = [:]
        for (source, names) in data["SPEC REPOS"] as? [String: Any] ?? [:] {
            for name in nativeStrings(names) {
                if let previous = sources[name], previous != source {
                    throw Diagnostic(
                        "SP-LOCK-SOURCE", stage: "resolve", "Multiple locked spec repositories for " + name,
                        file: path.path)
                }
                sources[name] = source
            }
        }
        var direct: [String: [String]] = [:]
        for value in nativeStrings(data["DEPENDENCIES"]) {
            let (name, requirements) = declaration(value)
            direct[name, default: []] += requirements
        }
        versions = pins
        dependencies = edges
        lockingDependencies = lockingEdges
        repositories = sources
        declarations = direct
        checksum = data["PODFILE CHECKSUM"] as? String
        manifestChecksum = data["SWIFTPODS MANIFEST CHECKSUM"] as? String
        specChecksums = strings(data["SPEC CHECKSUMS"])
        checkoutOptions = try sourceMap(data["CHECKOUT OPTIONS"])
        externalSources = try (data["EXTERNAL SOURCES"] as? [String: [String: Any]] ?? [:]).mapValues {
            try sourceKeys($0)
        }
    }
    func verifyUnchanged() throws {
        guard try FileFingerprint.tree(path) == originalFingerprint else {
            throw Diagnostic(
                "SP-LOCK-CONFLICT", stage: "install",
                "Lockfile changed during installation; the external edit is preserved", file: path.path,
                state: "recovery_required")
        }
    }
    func changedRoots(_ direct: [NativeDependency]) throws -> Set<String> {
        guard !declarations.isEmpty else { return [] }
        let current = Dictionary(grouping: direct, by: \.name)
        var changed = Set<String>()
        // The baseline compares existing declarations against their installed
        // versions. Compatible edits and newly added declarations keep pins.
        for name in declarations.keys {
            let root = String(name.split(separator: "/").first ?? "")
            guard let requests = current[name], let version = versions[root] else {
                changed.insert(root)
                continue
            }
            let pinned = try PodVersion(version)
            if try !requests.allSatisfy({ try PodRequirement($0.requirements).accepts(pinned) }) {
                changed.insert(root)
            }
        }
        for request in direct where declarations[request.name] != nil {
            let source = request.options.filter {
                [
                    "path", "git", "podspec", "http", "svn", "hg", "branch", "tag", "commit", "revision", "folder",
                    "submodules", "flatten", "type", "sha256", "sha1", "headers",
                ].contains($0.key)
            }
            func normalize(_ value: Any) -> Any {
                if let dictionary = value as? [String: Any] { return dictionary.mapValues(normalize) }
                if let values = value as? [Any] { return values.map(normalize) }
                return String(describing: value)
            }
            if try jsonData(normalize(source)) != jsonData(normalize(externalSources[request.root] ?? [:])) {
                changed.insert(request.root)
            }
        }
        return changed.intersection(Set(versions.keys))
    }
    func unlocked(_ roots: Set<String>) -> Set<String> {
        var result = roots
        var queue = Array(roots)
        let explicit = Set(declarations.keys.map { String($0.split(separator: "/").first ?? "") })
        var parents: [String: Set<String>] = [:]
        for (parent, children) in lockingDependencies {
            for child in children where child != parent { parents[child, default: []].insert(parent) }
        }
        while let root = queue.popLast() {
            for child in lockingDependencies[root] ?? [] where !result.contains(child) && !explicit.contains(child) {
                if (parents[child] ?? []).isSubset(of: result), result.insert(child).inserted { queue.append(child) }
            }
        }
        return result
    }
    static func sha1(_ data: Data) -> String {
        Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "''") + "'" }
    static func make(
        _ resolution: NativeResolution, direct: [NativeDependency], checksum: String, referenceVersion: String,
        manifestChecksum: String, previous: [String: Any] = [:]
    ) throws -> String {
        var text = "PODS:\n"
        var names = Set<String>()
        for request in resolution.requests.sorted(by: { $0.name < $1.name }) where names.insert(request.name).inserted {
            let spec = resolution.specs[request.root]!
            let dependencies = try spec.dependencies(for: request)
            let value = quote(request.name + " (" + spec.version.description + ")")
            if dependencies.isEmpty {
                text += "  - " + value + "\n"
            } else {
                text += "  - " + value + ":\n"
                for dependency in dependencies.sorted(by: { $0.name < $1.name }) {
                    text +=
                        "    - " + quote(dependency.name + " (" + dependency.requirements.joined(separator: ", ") + ")")
                        + "\n"
                }
            }
        }
        text += "\nDEPENDENCIES:\n"
        var declarations = Set<String>()
        for request in direct.sorted(by: { $0.name < $1.name })
        where declarations.insert(request.name + request.requirements.joined(separator: ",")).inserted {
            let requirement =
                request.options["path"].map { "from `\($0)`" } ?? request.requirements.joined(separator: ", ")
            text += "  - " + quote(request.name + " (" + requirement + ")") + "\n"
        }
        let external = direct.filter { dependency in
            ["path", "git", "podspec", "http", "svn", "hg"].contains(where: { dependency.options[$0] != nil })
        }
        if !external.isEmpty {
            text += "\nEXTERNAL SOURCES:\n"
            var externalRoots = Set<String>()
            for request in external.sorted(by: { $0.root < $1.root }) where externalRoots.insert(request.root).inserted
            {
                text += "  " + quote(request.root) + ":\n"
                for (key, value) in request.options.sorted(by: { $0.key < $1.key })
                where [
                    "path", "git", "http", "svn", "hg", "tag", "branch", "commit", "revision", "folder", "submodules",
                    "sha256", "sha1", "flatten", "type", "podspec", "headers",
                ].contains(key) {
                    if value is [String: Any] || value is [Any] {
                        text += try NativeYAML.encode([":" + key: value], indent: 4)
                    } else {
                        text += "    " + quote(":" + key) + ": " + quote(String(describing: value)) + "\n"
                    }
                }
            }
        }
        let repositories = Dictionary(
            grouping: resolution.specs.values.filter { !$0.repository.isEmpty }, by: \.repository)
        if !repositories.isEmpty {
            text += "\nSPEC REPOS:\n"
            for (repository, specs) in repositories.sorted(by: { $0.key < $1.key }) {
                text += "  " + quote(repository) + ":\n"
                for spec in specs.sorted(by: { $0.name < $1.name }) { text += "    - " + quote(spec.name) + "\n" }
            }
        }
        let checkouts = resolution.specs.values.filter { !$0.checkout.isEmpty }
        if !checkouts.isEmpty {
            text += "\nCHECKOUT OPTIONS:\n"
            for spec in checkouts.sorted(by: { $0.name < $1.name }) {
                text += "  " + quote(spec.name) + ":\n"
                for (key, value) in spec.checkout.sorted(by: { $0.key < $1.key }) {
                    text += "    " + quote(":" + key) + ": " + quote(value) + "\n"
                }
            }
        }
        text += "\nSPEC CHECKSUMS:\n"
        for (name, spec) in resolution.specs.sorted(by: { $0.key < $1.key }) {
            text += "  " + quote(name) + ": " + quote(try spec.checksum ?? sha1(jsonData(spec.data))) + "\n"
        }
        text +=
            "\nPODFILE CHECKSUM: " + checksum + "\n\nCOCOAPODS: " + referenceVersion + "\n\nSWIFTPODS: " + CLI.version
            + "\n\nSWIFTPODS MANIFEST CHECKSUM: " + manifestChecksum + "\n"
        let owned: Set<String> = [
            "PODS", "DEPENDENCIES", "EXTERNAL SOURCES", "SPEC REPOS", "CHECKOUT OPTIONS", "SPEC CHECKSUMS",
            "PODFILE CHECKSUM", "COCOAPODS", "SWIFTPODS", "SWIFTPODS MANIFEST CHECKSUM",
        ]
        let extensions = previous.filter { !owned.contains($0.key) }
        if !extensions.isEmpty { text += "\n" + (try NativeYAML.encode(extensions)) }
        return text
    }
}
