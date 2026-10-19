import CryptoKit
import Darwin
import Foundation

enum FileFingerprint {
    static func linkIsContained(_ link: URL, in root: URL) throws -> Bool {
        func canonical(_ path: String) -> String? {
            guard let value = realpath(path, nil) else { return nil }
            defer { free(value) }
            return String(cString: value)
        }
        guard let boundary = canonical(root.path), let parent = canonical(link.deletingLastPathComponent().path) else {
            return false
        }
        let manager = FileManager.default
        let target = try manager.destinationOfSymbolicLink(atPath: link.path)
        func components(_ path: String) -> [String] {
            (path as NSString).pathComponents.filter { $0 != "/" }
        }
        var pending = components(target.utf8.first == 47 ? target : parent + "/" + target)
        var resolved: [String] = []
        var hops = 0
        while !pending.isEmpty {
            let component = pending.removeFirst()
            if component == "." { continue }
            if component == ".." {
                if !resolved.isEmpty { resolved.removeLast() }
                continue
            }
            resolved.append(component)
            let path = "/" + resolved.joined(separator: "/")
            if (try? manager.attributesOfItem(atPath: path)[.type]) as? FileAttributeType == .typeSymbolicLink {
                hops += 1
                guard hops <= 64 else { return false }
                let next = try manager.destinationOfSymbolicLink(atPath: path)
                resolved.removeLast()
                if next.utf8.first == 47 { resolved.removeAll() }
                pending = components(next) + pending
            }
        }
        // Both sides already use physical paths. Foundation URL standardization
        // treats /private/var aliases differently for existing and dangling paths.
        return resolved.starts(with: components(boundary))
    }

    static func file(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try NativeCancellation.check()
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func tree(_ root: URL, requireContainedLinks: Bool = false) throws -> String {
        let manager = FileManager.default
        guard let attributes = try? manager.attributesOfItem(atPath: root.path) else { return "absent" }
        var records: [[String: Any]] = []
        func record(_ path: URL, name: String) throws {
            try NativeCancellation.check()
            let info = try manager.attributesOfItem(atPath: path.path)
            var row: [String: Any] = ["path": name, "mode": (info[.posixPermissions] as? NSNumber)?.intValue ?? 0]
            if info[.type] as? FileAttributeType == .typeSymbolicLink {
                if try requireContainedLinks && !linkIsContained(path, in: root) {
                    throw Diagnostic(
                        "SP-INTEGRITY-SYMLINK", stage: "integrity", "Artifact contains a symlink outside its root",
                        file: path.path)
                }
                row["type"] = "symlink"
                row["target"] = try manager.destinationOfSymbolicLink(atPath: path.path)
            } else if info[.type] as? FileAttributeType == .typeDirectory {
                row["type"] = "directory"
            } else if info[.type] as? FileAttributeType == .typeRegular {
                row["type"] = "file"
                row["sha256"] = try file(path)
            } else {
                throw Diagnostic(
                    "SP-INTEGRITY-TYPE", stage: "integrity", "Unsupported filesystem object", file: path.path)
            }
            records.append(row)
        }
        try record(root, name: "")
        if attributes[.type] as? FileAttributeType == .typeDirectory,
            let enumerator = manager.enumerator(atPath: root.path)
        {
            while let relative = enumerator.nextObject() as? String {
                let path = root.appendingPathComponent(relative)
                if try manager.attributesOfItem(atPath: path.path)[.type] as? FileAttributeType == .typeSymbolicLink {
                    enumerator.skipDescendants()
                }
                try record(path, name: relative)
            }
        }
        return digest(try jsonData(records.sorted { ($0["path"] as? String ?? "") < ($1["path"] as? String ?? "") }))
    }
}
