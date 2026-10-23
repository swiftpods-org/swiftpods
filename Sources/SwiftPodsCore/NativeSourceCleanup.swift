import Foundation

/// Source declarations also retain the internal targets needed by their links.
enum NativeSourceCleanup {
    static func run(root: URL, used: Set<URL>) throws {
        guard let physical = FileFingerprint.physicalPath(root.path) else { return }
        let boundary = URL(fileURLWithPath: physical, isDirectory: true)
        let aliases = Set([
            root.path, root.standardizedFileURL.path, root.resolvingSymlinksInPath().path, physical,
        ]).map { ($0 as NSString).pathComponents }.sorted { $0.count > $1.count }
        func components(_ path: URL) -> [String] { path.pathComponents.map { $0.lowercased() } }
        var retained = Set(
            used.compactMap { path -> [String]? in
                let parts = path.pathComponents
                guard let base = aliases.first(where: { parts.starts(with: $0) }) else { return nil }
                return (boundary.pathComponents + parts.dropFirst(base.count)).map { $0.lowercased() }
            })
        func needed(_ path: URL) -> Bool {
            let value = components(path)
            return retained.contains { $0.starts(with: value) || value.starts(with: $0) }
        }

        var links: [URL] = []
        if let entries = FileManager.default.enumerator(atPath: physical) {
            while let relative = entries.nextObject() as? String {
                try NativeCancellation.check()
                let path = boundary.appendingPathComponent(relative)
                if try FileManager.default.attributesOfItem(atPath: path.path)[.type] as? FileAttributeType
                    == .typeSymbolicLink
                {
                    entries.skipDescendants()
                    links.append(path)
                }
            }
        }
        // A retained directory can contain further links to other payloads.
        // Resolve the complete dependency set before removing the first file.
        var visited = Set<URL>()
        while let link = links.first(where: { !visited.contains($0) && needed($0) }) {
            try NativeCancellation.check()
            visited.insert(link)
            guard let destinations = try FileFingerprint.linkDestinations(link, in: boundary) else {
                throw Diagnostic(
                    "SP-INTEGRITY-SYMLINK", stage: "integrity", "Selected source link escapes its pod or is cyclic",
                    file: link.path)
            }
            retained.formUnion(destinations.map(components))
        }
        if let entries = FileManager.default.enumerator(atPath: physical) {
            while let relative = entries.nextObject() as? String {
                try NativeCancellation.check()
                let path = boundary.appendingPathComponent(relative)
                if !needed(path) {
                    entries.skipDescendants()
                    try FileManager.default.removeItem(at: path)
                }
            }
        }
    }
}
