import Foundation

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
            !name.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
        else {
            throw Diagnostic("SP-SPEC-NAME", stage: "resolve", "Invalid dependency name")
        }
        guard value["requirements"] == nil || value["requirements"] is [String] else {
            throw Diagnostic(
                "SP-SPEC-REQUIREMENT", stage: "resolve", "Version requirements must be strings", file: name)
        }
        self.name = name
        requirements = value["requirements"] as? [String] ?? [">= 0"]
        guard value["options"] == nil || value["options"] is NSNull || value["options"] is [String: Any] else {
            throw Diagnostic("SP-DSL-POD-OPTION", stage: "resolve", "Pod options must be an object", file: name)
        }
        options = value["options"] as? [String: Any] ?? [:]
        let known: Set<String> = [
            "path", "git", "podspec", "http", "svn", "hg", "tag", "branch", "commit", "revision", "folder",
            "submodules", "flatten", "type", "sha256", "sha1", "headers", "source", "subspecs", "testspecs", "appspecs",
            "configurations", "configuration", "inhibit_warnings", "modular_headers", "project_name",
        ]
        if let unknown = Set(options.keys).subtracting(known).sorted().first {
            throw Diagnostic("SP-DSL-POD-OPTION", stage: "resolve", "Unknown pod option: " + unknown, file: name)
        }
        for key in [
            "path", "git", "podspec", "http", "svn", "hg", "tag", "branch", "commit", "folder", "source",
            "project_name",
        ] where options[key] != nil && !(options[key] is String) {
            throw Diagnostic("SP-DSL-POD-OPTION", stage: "resolve", key + " must be a string", file: name)
        }
        for key in ["submodules", "flatten", "inhibit_warnings", "modular_headers"] {
            if let value = options[key], CFGetTypeID(value as CFTypeRef) != CFBooleanGetTypeID() {
                throw Diagnostic("SP-DSL-POD-OPTION", stage: "resolve", key + " must be boolean", file: name)
            }
        }
        for key in ["subspecs", "testspecs", "appspecs", "configurations", "configuration"]
        where options[key] != nil && !(options[key] is String) && !(options[key] is [String]) {
            throw Diagnostic("SP-DSL-POD-OPTION", stage: "resolve", key + " must contain names", file: name)
        }
        if let headers = options["headers"], !(headers is [String: String]) {
            throw Diagnostic(
                "SP-DSL-POD-OPTION", stage: "resolve", "HTTP headers must map names to strings", file: name)
        }
        try NativeSourceOptions.validate(options, file: name)
        options["revision"] = try NativeSourceOptions.revision(options["revision"], file: name)
        self.platform = platform
        self.deployment = deployment
        _ = try PodRequirement(requirements)
    }
}
