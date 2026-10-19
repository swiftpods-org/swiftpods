import Foundation

/// File declarations belong to a spec consumer, even when consumers share a target.
struct NativeLibraryFiles {
    struct Owner {
        let name: String
        let attributes: [String: Any]
        let files: Set<URL>
        let rules: NativeFileRules
    }
    let root: URL
    let owners: [Owner]
    let files: [URL]
    let headers: Set<URL>
    let publicHeaders: Set<URL>
    let privateHeaders: Set<URL>
    let compilerFlags: [String]

    init(spec: NativeSpec, names: [String], platform: String, root: URL) throws {
        self.root = root
        owners = try Set(names).sorted {
            (NativePodName.components($0).count, $0) < (NativePodName.components($1).count, $1)
        }.map { name in
            let attributes = try spec.attributes(name, platform: platform)
            let files = try NativeFileSelection.sourceFiles(attributes, root: root)
            return Owner(
                name: name, attributes: attributes, files: Set(files),
                rules: try NativeFileRules(attributes, root: root, files: files))
        }
        files = Set(owners.flatMap(\.files)).sorted { $0.path < $1.path }
        headers = Set(owners.flatMap { $0.rules.headers })
        publicHeaders = Set(owners.flatMap { $0.rules.publicHeaders })
        privateHeaders = Set(owners.flatMap { $0.rules.privateHeaders }).subtracting(publicHeaders)
        let compiled = owners.filter {
            $0.files.contains { NativeFileSelection.compilableSources.contains($0.pathExtension) }
        }
        let flags = (compiled.isEmpty ? owners : compiled).map { nativeStrings($0.attributes["compiler_flags"]) }
        compilerFlags = (flags.first ?? []).filter { flag in flags.allSatisfy { $0.contains(flag) } }
    }

    private func owner(_ file: URL) -> Owner? { owners.last { $0.files.contains(file) } }

    func sourceSettings(_ file: URL) -> [String: Any] {
        guard let owner = owner(file) else { return [:] }
        var flags = nativeStrings(owner.attributes["compiler_flags"]).filter { !compilerFlags.contains($0) }
        if ["m", "mm", "M"].contains(file.pathExtension) {
            if let selected = owner.rules.arcFiles {
                flags.append(selected.contains(file) ? "-fobjc-arc" : "-fno-objc-arc")
            } else {
                flags.append(owner.attributes["requires_arc"] as? Bool == false ? "-fno-objc-arc" : "-fobjc-arc")
            }
        }
        return flags.isEmpty ? [:] : ["COMPILER_FLAGS": flags.joined(separator: " ")]
    }

    func headerSettings(_ file: URL) -> [String: Any] {
        if publicHeaders.contains(file) { return ["ATTRIBUTES": ["Public"]] }
        if privateHeaders.contains(file) { return ["ATTRIBUTES": ["Private"]] }
        return [:]
    }

    func headerPath(_ file: URL) throws -> String {
        try NativeFileRules.headerPath(file, attributes: owner(file)?.attributes ?? [:], root: root)
    }
    func headerDirectory(_ file: URL, module: String) throws -> String {
        try NativeFileRules.headerDirectory(owner(file)?.attributes ?? [:], module: module)
    }

    func paths(_ key: String) throws -> [URL] {
        try Set(
            owners.flatMap { owner in
                if key == "resources" {
                    return try NativeFileSelection.resourcePaths(
                        owner.attributes[key], attributes: owner.attributes, root: root)
                }
                return try NativeFileSelection.paths(owner.attributes[key], attributes: owner.attributes, root: root)
            }
        ).sorted { $0.path < $1.path }
    }
    func resourceBundles() throws -> [String: [URL]] {
        var bundles: [String: Set<URL>] = [:]
        for owner in owners {
            for (name, patterns) in owner.attributes["resource_bundles"] as? [String: Any] ?? [:] {
                bundles[name, default: []].formUnion(
                    try NativeFileSelection.resourcePaths(patterns, attributes: owner.attributes, root: root))
            }
        }
        return bundles.mapValues { $0.sorted { $0.path < $1.path } }
    }
}
