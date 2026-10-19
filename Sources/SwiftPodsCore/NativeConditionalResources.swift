import Foundation

/// Xcode stores asset tags on build files, so distinct tag sets need distinct references.
struct NativeConditionalResources {
    private(set) var paths: [URL]
    private(set) var onDemand = NativeOnDemandResources()
    private(set) var exclusions: [String: Set<String>] = [:]

    init(directory: URL, normal: [String: [URL]], configurations: [String: NativeOnDemandResources]) throws {
        let names = Set(normal.keys).union(configurations.keys).sorted()
        for resources in configurations.values { onDemand.merge(resources) }
        var selected = Set(normal.values.flatMap { $0 }).union(onDemand.files.keys)
        for (file, _) in onDemand.files.sorted(by: { $0.key.path < $1.key.path }) {
            var variants: [[String]: Set<String>] = [:]
            for name in names {
                let tags = configurations[name]?.files[file] ?? []
                let resources = normal[name] ?? []
                // A directory declaration already copies this descendant at its
                // original relative location; it needs no flattened normal alias.
                let copiedByDirectory = resources.contains { NativePath.isDescendant(file, of: $0) }
                let required = !tags.isEmpty || (!copiedByDirectory && resources.contains(file))
                if required { variants[tags.sorted(), default: []].insert(name) }
            }
            // An exclusively conditional resource can keep its original reference;
            // the consumer's ordinary path exclusions already hide it when disabled.
            // A tagged descendant needs an independent reference as well, otherwise
            // NativeResources would absorb it into the ordinary directory copy.
            let insideDirectory = normal.values.flatMap { $0 }.contains { NativePath.isDescendant(file, of: $0) }
            guard variants.count > 1 || insideDirectory else { continue }
            selected.remove(file)
            onDemand.files.removeValue(forKey: file)
            for (tags, enabled) in variants.sorted(by: { $0.key.lexicographicallyPrecedes($1.key) }) {
                let identity = try digest(jsonData(["source": file.path, "tags": tags]))
                var parent = directory.appendingPathComponent("OnDemandResources/" + identity)
                if file.deletingLastPathComponent().pathExtension == "lproj" {
                    parent.appendPathComponent(file.deletingLastPathComponent().lastPathComponent)
                }
                let alias = parent.appendingPathComponent(file.lastPathComponent)
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
                if (try? FileManager.default.destinationOfSymbolicLink(atPath: alias.path)) != file.path {
                    if FileManager.default.fileExists(atPath: alias.path)
                        || (try? FileManager.default.destinationOfSymbolicLink(atPath: alias.path)) != nil
                    {
                        try FileManager.default.removeItem(at: alias)
                    }
                    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: file)
                }
                selected.insert(alias)
                if !tags.isEmpty { onDemand.files[alias] = Set(tags) }
                for name in names where !enabled.contains(name) {
                    exclusions[name, default: []].insert(alias.path)
                }
            }
        }
        paths = selected.sorted { $0.path < $1.path }
    }
}
