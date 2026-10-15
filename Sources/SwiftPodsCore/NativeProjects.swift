import Foundation

extension NativeXcode {
    var multipleProjects: Bool {
        (manifest["options"] as? [String: Any])?["generate_multiple_pod_projects"] as? Bool == true
    }
    var podsProject: NativePBX { aggregateProject ?? graph }
    func projectNameForPod(_ root: String) -> String {
        for target in manifest["targets"] as? [[String: Any]] ?? [] {
            for dependency in target["dependencies"] as? [[String: Any]] ?? []
            where (dependency["name"] as? String)?.split(separator: "/").first.map(String.init) == root {
                if let name = (dependency["options"] as? [String: Any])?["project_name"] as? String { return name }
            }
        }
        return root
    }
    func projectForName(_ name: String) -> URL { project.appendingPathComponent("Pods/" + name + ".xcodeproj") }
    func projectForPod(_ root: String) -> URL { projectForName(projectNameForPod(root)) }

    func prepareMultipleProjects() throws {
        guard multipleProjects, aggregateProject == nil else { return }
        let owners = targetOwners.mapValues(projectNameForPod)
        let roots = Set(owners.values).sorted()
        guard roots.allSatisfy({ !$0.isEmpty && !$0.contains("/") && $0 != "." && $0 != ".." }) else {
            throw Diagnostic("SP-XCODE-PROJECT", stage: "integrate", "Invalid pod project name")
        }
        guard !roots.contains("Pods") else {
            throw Diagnostic(
                "SP-XCODE-PROJECT", stage: "integrate", "Pod project name conflicts with the aggregate project",
                file: "Pods")
        }
        for pod in roots {
            let path = projectForName(pod)
            generatedProjects[path.path] = try NativeProjectProjection.make(
                source: graph, url: path.appendingPathComponent("project.pbxproj"),
                targets: targetIDs.filter { owners[$0] == pod }, owner: pod, owners: owners,
                projectForPod: projectForName, allPods: roots)
        }
        aggregateProject = try NativeProjectProjection.make(
            source: graph, url: graph.url, targets: targetIDs.filter { owners[$0] == nil }, owner: nil, owners: owners,
            projectForPod: projectForName, allPods: roots)
    }

    func saveMultipleProjects() throws {
        try prepareMultipleProjects()
        for path in generatedProjects.keys.sorted() { try generatedProjects[path]!.save() }
    }

    var hookGeneratedProjects: [[String: Any]] {
        generatedProjects.keys.sorted().compactMap { path in
            guard let child = generatedProjects[path] else { return nil }
            var root = child.root
            root["objects"] = child.objects
            return ["path": path, "generated": true, "graph": root]
        }
    }
}
