import Foundation
import ProcessSupport

enum ExecutionPolicy {
    static func validateArchive(_ path: String) throws {
        var message = [CChar](repeating: 0, count: 4096)
        guard sp_validate_archive(path, &message, message.count) == 0 else {
            throw Diagnostic("SP-ARCHIVE-UNSAFE", stage: "extract", String(cString: message), file: path)
        }
    }

    static func hardenedManifest(_ path: URL) throws -> [String: Any] {
        let manifest = try readObject(path)
        func keys(_ value: [String: Any], _ allowed: Set<String>) throws {
            guard Set(value.keys).isSubset(of: allowed) else {
                throw Diagnostic(
                    "SP-HARDENED-FIELD", stage: "policy", "Unknown hardened manifest field", file: path.path)
            }
        }
        try keys(
            manifest,
            ["schema_version", "platform", "project", "workspace", "sources", "targets", "frameworks", "options"])
        if let options = manifest["options"] {
            guard let values = options as? [String: Any] else {
                throw Diagnostic(
                    "SP-HARDENED-SCHEMA", stage: "policy", "Installation options must be an object", file: path.path)
            }
            try keys(
                values,
                [
                    "deterministic_uuids", "integrate_targets", "skip_pods_project_generation",
                    "generate_multiple_pod_projects",
                ])
            guard values.values.allSatisfy({ CFGetTypeID($0 as CFTypeRef) == CFBooleanGetTypeID() }) else {
                throw Diagnostic(
                    "SP-HARDENED-SCHEMA", stage: "policy", "Installation options must be boolean", file: path.path)
            }
        }
        guard manifest["schema_version"] as? Int == 1,
            let platform = manifest["platform"] as? [String: String],
            Set(platform.keys) == ["name", "deployment_target"],
            ["ios", "osx", "tvos", "watchos", "visionos"].contains(platform["name"] ?? ""),
            let targets = manifest["targets"] as? [[String: Any]], !targets.isEmpty,
            manifest["project"] is String,
            manifest["frameworks"] == nil || ["static", "dynamic"].contains(manifest["frameworks"] as? String ?? ""),
            manifest["sources"] == nil || manifest["sources"] is [String],
            manifest["workspace"] == nil || manifest["workspace"] is String
        else {
            throw Diagnostic(
                "SP-HARDENED-SCHEMA", stage: "policy", "Invalid schema_version 1 declarative manifest", file: path.path)
        }
        for target in targets {
            try keys(target, ["name", "pods"])
            guard target["name"] is String, let pods = target["pods"] as? [[String: Any]] else {
                throw Diagnostic(
                    "SP-HARDENED-TARGET", stage: "policy", "Each target needs a name and pods array", file: path.path)
            }
            for pod in pods {
                try keys(
                    pod,
                    [
                        "name", "versions", "path", "podspec", "git", "tag", "commit", "branch", "source", "subspecs",
                        "testspecs", "appspecs", "configurations",
                    ])
                guard pod["name"] is String,
                    pod["versions"] == nil || pod["versions"] is [String],
                    ["subspecs", "testspecs", "appspecs", "configurations"].allSatisfy({
                        pod[$0] == nil || pod[$0] is [String]
                    }),
                    pod.filter({
                        !["versions", "subspecs", "testspecs", "appspecs", "configurations"].contains($0.key)
                    }).values.allSatisfy({ $0 is String }),
                    ["path", "podspec", "git"].filter({ pod[$0] != nil }).count <= 1
                else {
                    throw Diagnostic(
                        "SP-HARDENED-POD", stage: "policy", "Invalid dependency declaration", file: path.path)
                }
            }
        }
        return manifest
    }
}
