import Foundation

/// Snapshot content and checkout provenance are immutable; pod ownership is not.
enum NativeSnapshotCache {
    static func write(_ directory: URL, metadata: [String: Any]) throws {
        var metadata = metadata
        let fingerprint = try FileFingerprint.tree(directory, requireContainedLinks: true)
        metadata["fingerprint"] = fingerprint
        let receipt: [String: Any] = [
            "schema_version": 1, "cache_key": directory.lastPathComponent,
            "fingerprint": fingerprint, "provenance_sha256": try provenance(metadata),
        ]
        try jsonData(metadata).write(to: directory.appendingPathExtension("origin.json"), options: .atomic)
        try jsonData(receipt).write(to: directory.appendingPathExtension("sha256"), options: .atomic)
    }

    static func verify(_ directory: URL) throws -> [String: Any] {
        guard let metadata = try? readObject(directory.appendingPathExtension("origin.json")),
            let receipt = try? readObject(directory.appendingPathExtension("sha256")),
            receipt["schema_version"] as? Int == 1,
            receipt["cache_key"] as? String == directory.lastPathComponent,
            receipt["provenance_sha256"] as? String == (try provenance(metadata)),
            receipt["fingerprint"] as? String == metadata["fingerprint"] as? String,
            receipt["fingerprint"] as? String == (try FileFingerprint.tree(directory, requireContainedLinks: true))
        else {
            throw Diagnostic(
                "SP-CACHE-INTEGRITY", stage: "cache",
                "Source snapshot or provenance changed; refresh the source with update POD", file: directory.path)
        }
        return metadata
    }

    static func checkout(_ metadata: [String: Any], matching source: [String: Any]) throws -> [String: String] {
        let checkout = metadata["checkout"] as? [String: String] ?? [:]
        let keys =
            source["http"] != nil
            ? ["http", "sha1", "sha256"]
            : source["svn"] != nil ? ["svn", "tag", "branch", "folder"] : ["hg", "tag", "branch"]
        for key in keys {
            guard checkout[key] == source[key] as? String else {
                throw Diagnostic("SP-CACHE-INTEGRITY", stage: "download", "Snapshot provenance differs from its source")
            }
        }
        return checkout
    }

    /// Old receipts can be listed or removed, but cannot prove a checkout revision.
    static func maintenanceMetadata(_ directory: URL) throws -> [String: Any] {
        if FileManager.default.fileExists(atPath: directory.appendingPathExtension("sha256").path) {
            return try verify(directory)
        }
        var metadata = try readObject(directory.appendingPathExtension("origin.json"))
        guard metadata["fingerprint"] as? String == (try FileFingerprint.tree(directory, requireContainedLinks: true))
        else {
            throw Diagnostic(
                "SP-CACHE-INTEGRITY", stage: "cache", "Legacy source snapshot changed", file: directory.path)
        }
        metadata.removeValue(forKey: "checkout")
        return metadata
    }

    private static func provenance(_ metadata: [String: Any]) throws -> String {
        guard let checkout = metadata["checkout"] as? [String: String],
            ["http", "svn", "hg"].filter({ checkout[$0] != nil }).count == 1,
            checkout["http"] != nil || !(checkout["revision"] ?? "").isEmpty
        else { throw Diagnostic("SP-CACHE-INTEGRITY", stage: "cache", "Invalid snapshot provenance") }
        return try digest(jsonData(checkout))
    }
}
