import Foundation

struct ArtifactIntegrity {
    let project: URL
    var path: URL { project.appendingPathComponent(".swiftpods/Integrity.lock") }

    private func artifactPath(_ relative: String) throws -> URL {
        let components = (relative as NSString).pathComponents
        let root = project.appendingPathComponent("Pods").resolvingSymlinksInPath()
        let file = project.appendingPathComponent(relative).resolvingSymlinksInPath()
        guard components.first == "Pods", components.count > 1, !components.contains(".."),
            NativePath.isDescendant(file, of: root)
        else {
            throw Diagnostic("SP-INTEGRITY-PATH", stage: "integrity", "Invalid artifact path", file: relative)
        }
        return file
    }

    func verify(allowMissing: Bool = false) throws -> [String: Any] {
        let lock = try readObject(path)
        guard lock["schema_version"] as? Int == 1,
            lock["lock_sha256"] as? String
                == (try FileFingerprint.file(project.appendingPathComponent("Podfile.lock"))),
            let artifacts = lock["artifacts"] as? [[String: Any]]
        else {
            throw Diagnostic(
                "SP-INTEGRITY-LOCK", stage: "integrity",
                "Integrity.lock does not match Podfile.lock; install the intended graph and explicitly run integrity record",
                file: path.path)
        }
        var missing: [String] = []
        for artifact in artifacts {
            guard let relative = artifact["path"] as? String
            else {
                throw Diagnostic("SP-INTEGRITY-PATH", stage: "integrity", "Invalid artifact path", file: path.path)
            }
            let file = try artifactPath(relative)
            let actual = try FileFingerprint.tree(file, requireContainedLinks: true)
            if actual == "absent" && allowMissing {
                missing.append(relative)
                continue
            }
            guard actual == artifact["sha256"] as? String else {
                throw Diagnostic(
                    "SP-INTEGRITY-CONTENT", stage: "integrity",
                    "Installed SDK content differs from its recorded fingerprint", file: relative,
                    state: "recovery_required")
            }
        }
        return [
            "schema_version": 1, "status": missing.isEmpty ? "passed" : "requires_restore",
            "missing_artifacts": missing,
            "verified_artifacts": artifacts.count - missing.count,
            "scope":
                "Recorded nonlocal pod source trees; local development pods, build outputs and external Ruby inputs are not sealed",
        ]
    }

    func record(report: [String: Any]) throws -> [String: Any] {
        let lockDigest = try FileFingerprint.file(project.appendingPathComponent("Podfile.lock"))
        guard report["lock_digest"] as? String == lockDigest else {
            throw Diagnostic(
                "SP-INTEGRITY-REPORT", stage: "integrity",
                "Last installation report does not match Podfile.lock; run install first")
        }
        var artifacts: [[String: Any]] = []
        var roots = Set<String>()
        for spec in report["specs"] as? [[String: Any]] ?? [] where spec["local"] as? Bool != true {
            guard let name = (spec["name"] as? String).map(NativePodName.root),
                roots.insert(name).inserted
            else { continue }
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
                throw Diagnostic("SP-INTEGRITY-PATH", stage: "integrity", "Invalid root pod name")
            }
            let relative = "Pods/" + name
            let value = try FileFingerprint.tree(artifactPath(relative), requireContainedLinks: true)
            guard value != "absent" else {
                throw Diagnostic("SP-INTEGRITY-MISSING", stage: "integrity", "SDK is not installed", file: relative)
            }
            artifacts.append([
                "name": name, "version": spec["version"] ?? "unknown", "source": spec["source"] ?? [:],
                "spec_repository": spec["spec_repository"] ?? NSNull(), "checkout": spec["checkout"] ?? [:],
                "path": relative, "sha256": value,
            ])
        }
        let value: [String: Any] = [
            "schema_version": 1, "producer": "SwiftPods", "lock_sha256": lockDigest,
            "artifacts": artifacts.sorted { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") },
            "scope": "Nonlocal pod source trees; mutable local pods and external scripts are not sealed",
        ]
        try jsonData(value).write(to: path, options: .atomic)
        return ["schema_version": 1, "status": "recorded", "artifacts": artifacts.count, "path": path.path]
    }
}
