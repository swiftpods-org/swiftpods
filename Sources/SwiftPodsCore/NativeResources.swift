import Foundation

enum NativeResources {
    static func expandedPaths(_ paths: [URL]) throws -> [URL] {
        var candidates = paths
        for path in paths where path.pathExtension == "lproj" && (try? path.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            candidates += try FileManager.default.contentsOfDirectory(at: path, includingPropertiesForKeys: [.isDirectoryKey])
        }
        return candidates
    }
    static func references(_ paths: [URL], owner: String, graph: NativePBX, prefix: String = "", allowMissing: Set<URL> = []) throws -> [String] {
        let candidates = try expandedPaths(paths)
        var refs: [String] = [], directories: [String] = [], variants: [String: [URL]] = [:]
        func file(_ path: URL, type: String? = nil) -> String {
            var value: [String: Any] = ["isa": "PBXFileReference", "path": path.path, "sourceTree": "<absolute>"]
            if let type { value["lastKnownFileType"] = type }
            return graph.add(prefix + "file:" + path.path, value)
        }
        for path in Set(candidates).sorted(by: { $0.path < $1.path }) {
            if directories.contains(where: { path.path.hasPrefix($0 + "/") }) { continue }
            let directory: Bool
            if allowMissing.contains(path) && !FileManager.default.fileExists(atPath: path.path) { directory = false }
            else { directory = (try path.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true }
            if path.pathExtension == "lproj", directory { continue }
            if path.deletingLastPathComponent().pathExtension == "lproj" { variants[path.lastPathComponent, default: []].append(path); continue }
            if directory { directories.append(path.path) }
            refs.append(file(path, type: directory && path.pathExtension.isEmpty ? "folder" : nil))
        }
        for (name, localized) in variants.sorted(by: { $0.key < $1.key }) {
            let children = localized.map { path -> String in
                let id = file(path); graph.objects[id]?["name"] = path.deletingLastPathComponent().deletingPathExtension().lastPathComponent; return id
            }
            refs.append(graph.add(prefix + "variant:" + owner + ":" + name, ["isa": "PBXVariantGroup", "name": name, "sourceTree": "<group>", "children": children]))
        }
        return refs
    }

    static func apply(_ paths: [URL], target: String, graph: NativePBX, allowMissing: Set<URL> = []) throws {
        let prefix = "swiftpods:resources:" + target + ":"
        var order = graph.objects[target]?["buildPhases"] as? [String] ?? []
        let phase = order.first { graph.objects[$0]?["isa"] as? String == "PBXResourcesBuildPhase" } ?? graph.add(prefix + "phase", ["isa": "PBXResourcesBuildPhase", "files": [], "buildActionMask": "2147483647", "runOnlyForDeploymentPostprocessing": "0"])
        var builds = graph.objects[phase]?["files"] as? [String] ?? []
        let oldBuilds = builds.filter { id in
            guard let ref = graph.objects[id]?["fileRef"] as? String else { return false }
            return id == NativePBX.identifier(prefix + "build:" + ref)
        }
        builds.removeAll { oldBuilds.contains($0) }
        var oldReferences = Set(oldBuilds.compactMap { graph.objects[$0]?["fileRef"] as? String })
        for ref in oldReferences { oldReferences.formUnion(graph.objects[ref]?["children"] as? [String] ?? []) }
        for id in oldBuilds { graph.objects.removeValue(forKey: id) }
        let refs = try references(paths, owner: target, graph: graph, prefix: prefix, allowMissing: allowMissing)
        for ref in refs { builds.append(graph.add(prefix + "build:" + ref, ["isa": "PBXBuildFile", "fileRef": ref])) }
        graph.objects[phase]?["files"] = builds
        if !order.contains(phase), !builds.isEmpty { order.append(phase) }
        if builds.isEmpty, phase == NativePBX.identifier(prefix + "phase") { order.removeAll { $0 == phase }; graph.objects.removeValue(forKey: phase) }
        graph.objects[target]?["buildPhases"] = order
        if let root = graph.root["rootObject"] as? String, let group = graph.objects[root]?["mainGroup"] as? String {
            var children = graph.objects[group]?["children"] as? [String] ?? []
            for ref in refs where !children.contains(ref) { children.append(ref) }
            graph.objects[group]?["children"] = children
        }
        var keptReferences = Set(refs)
        for ref in refs { keptReferences.formUnion(graph.objects[ref]?["children"] as? [String] ?? []) }
        for id in oldReferences.subtracting(keptReferences) {
            let used = graph.objects.values.contains { object in
                object["isa"] as? String != "PBXGroup" && object["isa"] as? String != "PBXVariantGroup" && object.values.contains { ($0 as? String) == id || ($0 as? [String])?.contains(id) == true }
            }
            if used { continue }
            graph.objects.removeValue(forKey: id)
            for group in Array(graph.objects.keys) {
                if let children = graph.objects[group]?["children"] as? [String] { graph.objects[group]?["children"] = children.filter { $0 != id } }
            }
        }
    }
}
