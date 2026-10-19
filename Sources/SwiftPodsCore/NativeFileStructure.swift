import Foundation

extension NativeXcode {
    func organizeSourceGroups() {
        guard let root = graph.root["rootObject"] as? String, let main = graph.objects[root]?["mainGroup"] as? String
        else { return }
        var children = graph.objects[main]?["children"] as? [String] ?? []
        for spec in resolution.specs.values.sorted(by: { $0.name < $1.name })
        where spec.local || installationOptions["preserve_pod_file_structure"] as? Bool == true {
            guard let directory = spec.directory else { continue }
            let refs = children.filter { id in
                guard let path = graph.objects[id]?["path"] as? String else { return false }
                return NativePath.isDescendant(
                    URL(fileURLWithPath: NativeBuildSetting.decodedLiteral(path)), of: directory)
            }
            guard !refs.isEmpty else { continue }
            children.removeAll { refs.contains($0) }
            let pod = graph.add(
                "source-group:" + spec.name,
                [
                    "isa": "PBXGroup", "name": spec.name, "path": NativeBuildSetting.literal(directory.path),
                    "sourceTree": "<absolute>",
                    "children": [],
                ])
            children.append(pod)
            var groups: [String: String] = ["": pod]
            for ref in refs.sorted() {
                guard let path = graph.objects[ref]?["path"] as? String else { continue }
                guard
                    let relative = NativePath.relativeComponents(
                        of: URL(fileURLWithPath: NativeBuildSetting.decodedLiteral(path)), to: directory)
                else { continue }
                let components = relative.dropLast()
                var parent = pod
                var prefix = ""
                for component in components {
                    prefix += "/" + component
                    if let existing = groups[prefix] {
                        parent = existing
                        continue
                    }
                    let child = graph.add(
                        "source-group:" + spec.name + ":" + prefix,
                        [
                            "isa": "PBXGroup", "name": String(component),
                            "path": NativeBuildSetting.literal(String(component)),
                            "sourceTree": "<group>", "children": [],
                        ])
                    var values = graph.objects[parent]?["children"] as? [String] ?? []
                    values.append(child)
                    graph.objects[parent]?["children"] = values
                    groups[prefix] = child
                    parent = child
                }
                var values = graph.objects[parent]?["children"] as? [String] ?? []
                values.append(ref)
                graph.objects[parent]?["children"] = values
            }
        }
        graph.objects[main]?["children"] = children
    }
}
