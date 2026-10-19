import Foundation

/// Binds a cached tree to the immutable checkout provenance. Pod ownership may
/// change as consumers share the checkout, but its revision must not change.
enum NativeGitCache {
    /// The caller holds this checkout's lock while merging mutable ownership.
    static func addOwners(_ names: [String], directory: URL, metadata: [String: Any]) throws {
        let previous = metadata["pod_names"] as? [String] ?? []
        let owners = Set(previous + names).sorted()
        guard owners != previous else { return }
        var updated = metadata
        updated["pod_names"] = owners
        try jsonData(updated).write(to: directory.appendingPathExtension("origin.json"), options: .atomic)
    }

    /// Only verified revision receipts can associate selector and commit copies.
    static func ownershipIdentity(_ metadata: [String: Any]) throws -> String? {
        guard metadata["commit"] != nil else { return nil }
        return try provenance(metadata)
    }

    private static func provenance(_ metadata: [String: Any]) throws -> String {
        guard let commit = metadata["commit"] as? String,
            commit.range(of: #"\A[0-9a-fA-F]{40}(?:[0-9a-fA-F]{24})?\z"#, options: .regularExpression) != nil,
            let origin = metadata["origin_identity"] as? String,
            origin.range(of: #"\A[0-9a-f]{64}\z"#, options: .regularExpression) != nil
        else { throw Diagnostic("SP-CACHE-INTEGRITY", stage: "cache", "Invalid Git checkout provenance") }
        return try digest(
            jsonData([
                "commit": commit, "origin_identity": origin, "submodules": metadata["submodules"] as? Bool ?? false,
            ]))
    }

    static func write(_ directory: URL, metadata: [String: Any]) throws {
        let receipt: [String: Any] = [
            "schema_version": 1, "cache_key": directory.lastPathComponent,
            "fingerprint": try FileFingerprint.tree(directory, requireContainedLinks: true),
            "provenance_sha256": try provenance(metadata),
        ]
        try jsonData(metadata).write(to: directory.appendingPathExtension("origin.json"), options: .atomic)
        try jsonData(receipt).write(to: directory.appendingPathExtension("sha256"), options: .atomic)
    }

    static func verify(_ directory: URL) throws -> [String: Any] {
        guard let receipt = try? readObject(directory.appendingPathExtension("sha256")),
            let metadata = try? readObject(directory.appendingPathExtension("origin.json")),
            receipt["schema_version"] as? Int == 1,
            receipt["cache_key"] as? String == directory.lastPathComponent,
            receipt["provenance_sha256"] as? String == (try provenance(metadata)),
            receipt["fingerprint"] as? String == (try FileFingerprint.tree(directory, requireContainedLinks: true))
        else {
            throw Diagnostic(
                "SP-CACHE-INTEGRITY", stage: "cache",
                "Git checkout or provenance changed; refresh the source with update POD", file: directory.path)
        }
        return metadata
    }

    /// Legacy receipts prove tree integrity only. Permit their inspection and
    /// removal, without trusting a revision or promoting them to installable data.
    static func maintenanceMetadata(_ directory: URL) throws -> [String: Any] {
        let receipt = directory.appendingPathExtension("sha256")
        guard
            let fingerprint = try? String(contentsOf: receipt, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            fingerprint.range(of: #"\A[0-9a-f]{64}\z"#, options: .regularExpression) != nil
        else { return try verify(directory) }
        guard fingerprint == (try FileFingerprint.tree(directory, requireContainedLinks: true)) else {
            throw Diagnostic("SP-CACHE-INTEGRITY", stage: "cache", "Legacy Git checkout changed", file: directory.path)
        }
        var metadata = try readObject(directory.appendingPathExtension("origin.json"))
        metadata.removeValue(forKey: "commit")
        return metadata
    }
}
