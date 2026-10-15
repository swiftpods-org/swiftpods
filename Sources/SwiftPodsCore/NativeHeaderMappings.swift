import Foundation

extension NativeXcode {
    func mapFrameworkHeaders(_ headers: Set<URL>, attributes: [String: Any], root: URL, target: String, label: String) throws {
        var groups: [String: [URL]] = [:]
        var destinations = Set<String>()
        for header in headers.sorted(by: { $0.path < $1.path }) {
            let path = try NativeFileRules.headerPath(header, attributes: attributes, root: root)
            guard destinations.insert(path).inserted else { throw Diagnostic("SP-SPEC-HEADER-COLLISION", stage: "integrate", "Multiple framework headers map to " + path, file: label) }
            if path.contains("/") { groups[(path as NSString).deletingLastPathComponent, default: []].append(header) }
        }
        var phases = graph.objects[target]?["buildPhases"] as? [String] ?? []
        let moved = Set(groups.values.flatMap { $0 }.map { file($0.path) })
        for phase in phases where graph.objects[phase]?["isa"] as? String == "PBXHeadersBuildPhase" {
            let retained = (graph.objects[phase]?["files"] as? [String] ?? []).filter { id in !moved.contains(graph.objects[id]?["fileRef"] as? String ?? "") }
            graph.objects[phase]?["files"] = retained
        }
        for (directory, paths) in groups.sorted(by: { $0.key < $1.key }) {
            let files = paths.map { buildFile(file($0.path), target: label + ":headers:" + directory) }
            let id = graph.add("header-mapping:" + label + ":" + directory, ["isa": "PBXCopyFilesBuildPhase", "name": "Copy Headers " + directory, "buildActionMask": "2147483647", "runOnlyForDeploymentPostprocessing": "0", "files": files, "dstSubfolderSpec": "16", "dstPath": "$(PUBLIC_HEADERS_FOLDER_PATH)/" + directory])
            phases.insert(id, at: 0)
        }
        graph.objects[target]?["buildPhases"] = phases
    }
}
