import Foundation

/// Typed, immutable projections let format-sensitive DSL consumers read a JSON
/// podspec without relying on the extension of the shared download object.
struct NativePodspecCache {
    let cache: URL
    private var root: URL { cache.appendingPathComponent("podspecs") }

    func project(_ content: Data) throws -> URL {
        let decoded = try? JSONSerialization.jsonObject(with: content)
        if let decoded { try NativeDictionaryKeys.validate(decoded) }
        guard let object = decoded as? [String: Any],
            object["name"] is String
        else {
            throw Diagnostic("SP-SPEC-SCHEMA", stage: "resolve", "JSON podspec requires an object with a name")
        }
        let identity = digest(content)
        let lock = try NativeCacheLock(cache: cache, key: "podspec-" + identity)
        defer { lock.release() }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent(identity + ".podspec.json")
        if FileManager.default.fileExists(atPath: file.path) {
            try verify(file, identity: identity)
        } else {
            try content.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path)
        }
        return file
    }

    func entries() throws -> [[String: Any]] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        return try files.sorted { $0.path < $1.path }.map { file in
            guard
                file.lastPathComponent.range(of: #"\A[0-9a-f]{64}\.podspec\.json\z"#, options: .regularExpression)
                    != nil
            else {
                throw Diagnostic(
                    "SP-CACHE-INTEGRITY", stage: "cache", "Invalid cached podspec address", file: file.path)
            }
            let identity = String(file.lastPathComponent.prefix(64))
            try verify(file, identity: identity)
            guard let name = try readObject(file)["name"] as? String else {
                throw Diagnostic(
                    "SP-CACHE-INTEGRITY", stage: "cache", "Cached podspec is missing its name", file: file.path)
            }
            return ["id": identity, "kind": "podspec", "name": name, "pods": [name]]
        }
    }

    func remove(_ entry: [String: Any]) throws {
        guard let identity = entry["id"] as? String,
            identity.range(of: #"\A[0-9a-f]{64}\z"#, options: .regularExpression) != nil
        else {
            throw Diagnostic("SP-CACHE-INTEGRITY", stage: "cache", "Invalid cached podspec address")
        }
        try FileManager.default.removeItem(at: root.appendingPathComponent(identity + ".podspec.json"))
    }

    private func verify(_ file: URL, identity: String) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
            try FileFingerprint.file(file) == identity
        else {
            throw Diagnostic("SP-CACHE-INTEGRITY", stage: "cache", "Cached JSON podspec changed", file: file.path)
        }
    }
}
