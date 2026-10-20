import Foundation

extension NativeXcode {
    func umbrellaHeader(_ contents: String, variant: NativePodVariant) -> String {
        guard inhibitWarnings(variant) else { return contents }
        // Keep the opt-in local to SDK headers. A [system] module would also
        // change how Swift imports NSUInteger, altering the SDK's API.
        return
            "#ifdef __clang__\n#pragma clang diagnostic push\n#pragma clang diagnostic ignored \"-Weverything\"\n#endif\n"
            + contents + "#ifdef __clang__\n#pragma clang diagnostic pop\n#endif\n"
    }

    enum HeaderVisibility: String {
        case publicHeaders = "Public"
        case privateHeaders = "Private"
    }

    func mapFrameworkHeaders(
        _ headers: Set<URL>, paths: [URL: String], target: String, label: String,
        visibility: HeaderVisibility
    )
        throws
    {
        let visibility = visibility.rawValue
        var groups: [String: [URL]] = [:]
        var destinations = Set<String>()
        for header in headers.sorted(by: { $0.path < $1.path }) {
            let path = paths[header] ?? header.lastPathComponent
            guard destinations.insert(path).inserted else {
                throw Diagnostic(
                    "SP-SPEC-HEADER-COLLISION", stage: "integrate", "Multiple framework headers map to " + path,
                    file: label)
            }
            if path.contains("/") { groups[(path as NSString).deletingLastPathComponent, default: []].append(header) }
        }
        var phases = graph.objects[target]?["buildPhases"] as? [String] ?? []
        let moved = Set(groups.values.flatMap { $0 }.map { file($0.path) })
        for phase in phases where graph.objects[phase]?["isa"] as? String == "PBXHeadersBuildPhase" {
            let retained = (graph.objects[phase]?["files"] as? [String] ?? []).filter { id in
                !moved.contains(graph.objects[id]?["fileRef"] as? String ?? "")
            }
            graph.objects[phase]?["files"] = retained
        }
        for (directory, paths) in groups.sorted(by: { $0.key < $1.key }) {
            let files = paths.map {
                buildFile(file($0.path), target: label + ":headers:" + visibility + ":" + directory)
            }
            let id = graph.add(
                "header-mapping:" + label + ":" + visibility + ":" + directory,
                [
                    "isa": "PBXCopyFilesBuildPhase", "name": "Copy " + visibility + " Headers " + directory,
                    "buildActionMask": "2147483647", "runOnlyForDeploymentPostprocessing": "0", "files": files,
                    "dstSubfolderSpec": "16",
                    "dstPath": "$(" + visibility.uppercased() + "_HEADERS_FOLDER_PATH)/" + directory,
                ])
            phases.insert(id, at: 0)
        }
        graph.objects[target]?["buildPhases"] = phases
    }

}
