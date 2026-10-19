import Foundation

struct NativeSpec {
    let data: [String: Any]
    let name: String
    let version: PodVersion
    let repository: String
    let checksum: String?
    var directory: URL?
    var local: Bool
    var checkout: [String: String] = [:]
    var catalogFile: URL?
    var moduleName: String {
        if let explicit = data["module_name"] as? String { return explicit }
        return NativeModuleIdentifier.normalize(data["header_dir"] as? String ?? name)
    }
    init(
        data: [String: Any], repository: String = "", directory: URL? = nil, local: Bool = false,
        checksum: String? = nil
    ) throws {
        try NativeSpecSchema.validate(data)
        guard let name = data["name"] as? String, NativePodName.isValid(name),
            let version = data["version"] as? String
        else {
            throw Diagnostic("SP-SPEC-SCHEMA", stage: "resolve", "Podspec requires a valid root name and version")
        }
        self.data = data
        self.name = name
        self.version = try PodVersion(version)
        if let module = data["module_name"] as? String,
            module.range(of: #"\A[A-Za-z_][A-Za-z0-9_]*\z"#, options: .regularExpression) == nil
        {
            throw Diagnostic("SP-SPEC-MODULE", stage: "resolve", "module_name must be a C99 identifier", file: name)
        }
        self.repository = repository
        self.directory = directory
        self.local = local
        self.checksum = checksum
    }
    func attributes(_ fullname: String, platform: String) throws -> [String: Any] {
        try supplementaryAttributes(fullname, platform: platform)
    }

    /// Catalog entries are data; compatibility applies to the selected graph.
    func validateProfile() throws {
        if let required = data["cocoapods_version"] as? String,
            try !PodRequirement([required]).accepts(PodVersion("1.17.0"))
        {
            throw Diagnostic(
                "SP-SPEC-PROFILE", stage: "resolve", "Specification requires a newer compatibility profile", file: name)
        }
    }

    static func merge(_ parent: [String: Any], _ child: [String: Any]) -> [String: Any] {
        mergeValues(NativeSpecValues.attributes(parent), NativeSpecValues.attributes(child))
    }

    private static func mergeValues(_ parent: [String: Any], _ child: [String: Any]) -> [String: Any] {
        var merged = parent
        for (key, value) in child {
            if ["platforms", "info_plist"].contains(key), let a = parent[key] as? [String: Any],
                let b = value as? [String: Any]
            {
                merged[key] = key == "platforms" ? b : a.merging(b) { _, new in new }
            } else if ["xcconfig", "pod_target_xcconfig", "user_target_xcconfig", "resource_bundles"].contains(key),
                let a = parent[key] as? [String: Any], let b = value as? [String: Any]
            {
                merged[key] = a.merging(b) { old, new in
                    if key == "resource_bundles" || old is [Any] || new is [Any] {
                        return nativeStrings(old) + nativeStrings(new)
                    }
                    return String(describing: old) + " " + String(describing: new)
                }
            } else if key == "dependencies", let a = parent[key] as? [String: Any], let b = value as? [String: Any] {
                var dependencies = a
                for (name, requirements) in b {
                    dependencies[name] = nativeStrings(a[name]) + nativeStrings(requirements)
                }
                merged[key] = dependencies
            } else if let a = parent[key] as? [String: Any], let b = value as? [String: Any] {
                merged[key] = mergeValues(a, b)
            } else if NativeAttributeContract.arrays.contains(key), let before = parent[key] {
                merged[key] = nativeStrings(before) + nativeStrings(value)
            } else {
                merged[key] = value
            }
        }
        return merged
    }
    func dependencies(for request: NativeDependency) throws -> [NativeDependency] {
        let attributes = try attributes(request.name, platform: request.platform)
        if let platforms = attributes["platforms"] as? [String: Any], !platforms.isEmpty,
            platforms[request.platform] == nil
        {
            throw Diagnostic(
                "SP-PLATFORM-CONFLICT", stage: "resolve", "\(request.name) does not support \(request.platform)")
        }
        let minimum =
            (attributes["platforms"] as? [String: Any])?[request.platform] as? String ?? attributes["deployment_target"]
            as? String ?? (attributes[request.platform] as? [String: Any])?["deployment_target"] as? String
        if try kind(request.name) == .library, let minimum, let requested = try? PodVersion(request.deployment),
            try PodVersion(minimum) > requested
        {
            throw Diagnostic(
                "SP-PLATFORM-CONFLICT", stage: "resolve",
                "\(request.name) requires \(request.platform) \(minimum), target uses \(request.deployment)")
        }
        var dependencies = try (attributes["dependencies"] as? [String: Any] ?? [:]).sorted(by: { $0.key < $1.key }).map
        { name, constraints in
            try NativeDependency(
                ["name": name, "requirements": nativeStrings(constraints)], platform: request.platform,
                deployment: request.deployment)
        }
        let node = try nodes(request.name).last!.data
        let defaults = nativeStrings(node["default_subspecs"] ?? node["default_subspec"])
        let children =
            defaults.isEmpty
            ? (node["subspecs"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
            : defaults.filter { $0 != "none" }
        dependencies += try children.map {
            try NativeDependency(
                ["name": request.name + "/" + $0, "requirements": ["= " + version.description]],
                platform: request.platform, deployment: request.deployment)
        }

        return dependencies
    }
}
