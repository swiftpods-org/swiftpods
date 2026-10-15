import Foundation
import Darwin

final class ContentStore {
    let root: URL
    private var descriptor: Int32 = -1
    init(cacheRoot: URL) throws {
        root = cacheRoot.appendingPathComponent("content")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        descriptor = open(root.appendingPathComponent("lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw Diagnostic("SP-CACHE-LOCK", stage: "cache", "Cannot open content store lock") }
        do { try NativeCacheLease.lock(descriptor, LOCK_EX) }
        catch { close(descriptor); descriptor = -1; throw error }
    }
    deinit { if descriptor >= 0 { flock(descriptor, LOCK_UN); close(descriptor) } }

    private func identity(_ origin: [String: Any]) throws -> String { digest(try jsonData(origin)) }
    private func object(_ hash: String) throws -> URL {
        guard hash.range(of: #"\A[0-9a-f]{64}\z"#, options: .regularExpression) != nil else { throw Diagnostic("SP-CACHE-INTEGRITY", stage: "cache", "Invalid content address") }
        return root.appendingPathComponent("objects/" + hash)
    }

    func get(origin: [String: Any]) throws -> [String: Any] {
        let index = root.appendingPathComponent("origins/" + (try identity(origin)) + ".json")
        guard FileManager.default.fileExists(atPath: index.path) else { return ["schema_version": 1, "status": "miss"] }
        let entry: [String: Any]
        do { entry = try readObject(index) }
        catch { throw Diagnostic("SP-CACHE-INTEGRITY", stage: "cache", "Origin index is corrupt", file: index.path) }
        guard let hash = entry["sha256"] as? String, let recorded = entry["origin"] as? [String: Any], try jsonData(recorded) == jsonData(origin) else {
            throw Diagnostic("SP-CACHE-INTEGRITY", stage: "cache", "Origin index is invalid", file: index.path)
        }
        let path = try object(hash)
        guard FileManager.default.fileExists(atPath: path.path) else { return ["schema_version": 1, "status": "miss", "missing": hash] }
        let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular, try FileFingerprint.file(path) == hash else {
            throw Diagnostic("SP-CACHE-INTEGRITY", stage: "cache", "Immutable archive content changed", file: path.path)
        }
        return ["schema_version": 1, "status": "hit", "path": path.path, "sha256": hash]
    }

    func put(file: URL, origin: [String: Any]) throws -> [String: Any] {
        let hash = try FileFingerprint.file(file)
        let destination = try object(hash)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            let type = try FileManager.default.attributesOfItem(atPath: destination.path)[.type] as? FileAttributeType
            guard type == .typeRegular, try FileFingerprint.file(destination) == hash else { throw Diagnostic("SP-CACHE-INTEGRITY", stage: "cache", "Existing content-addressed object is corrupt", file: destination.path) }
        } else {
            let pending = destination.deletingLastPathComponent().appendingPathComponent(".pending-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: pending) }
            try FileManager.default.copyItem(at: file, to: pending)
            guard try FileFingerprint.file(pending) == hash else { throw Diagnostic("SP-CACHE-CHANGED", stage: "cache", "Download changed while being published") }
            try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: pending.path)
            try FileManager.default.moveItem(at: pending, to: destination)
        }
        let index = root.appendingPathComponent("origins/" + (try identity(origin)) + ".json")
        try FileManager.default.createDirectory(at: index.deletingLastPathComponent(), withIntermediateDirectories: true)
        try jsonData(["schema_version": 1, "sha256": hash, "origin": origin]).write(to: index, options: .atomic)
        return ["schema_version": 1, "status": "stored", "sha256": hash]
    }

    func verify() throws -> [String: Any] {
        let objects = (try? FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("objects"), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for path in objects {
            _ = try object(path.lastPathComponent)
            let type = try FileManager.default.attributesOfItem(atPath: path.path)[.type] as? FileAttributeType
            guard type == .typeRegular, try FileFingerprint.file(path) == path.lastPathComponent else { throw Diagnostic("SP-CACHE-INTEGRITY", stage: "cache", "Content-addressed object changed", file: path.path) }
        }
        let origins = (try? FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("origins"), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for index in origins {
            let entry: [String: Any]
            do { entry = try readObject(index) }
            catch { throw Diagnostic("SP-CACHE-INTEGRITY", stage: "cache", "Origin index is corrupt", file: index.path) }
            guard let origin = entry["origin"] as? [String: Any],
                  index.lastPathComponent == (try identity(origin)) + ".json",
                  try get(origin: origin)["status"] as? String == "hit" else {
                throw Diagnostic("SP-CACHE-INTEGRITY", stage: "cache", "Origin references a missing object", file: index.path)
            }
        }
        return ["schema_version": 1, "status": "passed", "objects": objects.count, "origins": origins.count]
    }
    func list() throws -> [[String: Any]] {
        _ = try verify()
        let entries = (try? FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("origins"), includingPropertiesForKeys: nil)) ?? []
        return try entries.sorted { $0.path < $1.path }.map { path in
            var value = try readObject(path); value["id"] = path.deletingPathExtension().lastPathComponent; return value
        }
    }
    func clean(_ name: String?) throws -> Int {
        let entries = try list()
        let selected = entries.filter { name == nil || String(describing: $0["origin"] ?? "").localizedCaseInsensitiveContains(name!) }
        for entry in selected { try FileManager.default.removeItem(at: root.appendingPathComponent("origins/" + (entry["id"] as! String) + ".json")) }
        let remaining = Set(entries.filter { entry in !selected.contains { $0["id"] as? String == entry["id"] as? String } }.compactMap { $0["sha256"] as? String })
        for hash in Set(selected.compactMap { $0["sha256"] as? String }).subtracting(remaining) { try FileManager.default.removeItem(at: object(hash)) }
        return selected.count
    }
}
