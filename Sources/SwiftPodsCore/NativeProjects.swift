import Foundation

extension NativeXcode {
    var multipleProjects: Bool {
        (manifest["options"] as? [String: Any])?["generate_multiple_pod_projects"] as? Bool == true
    }
    var podsProject: NativePBX { aggregateProject ?? graph }
    func projectNameForPod(_ root: String) -> String {
        NativePodProjectNames.name(for: root, manifest: manifest)
    }
    func projectForName(_ name: String) -> URL { project.appendingPathComponent("Pods/" + name + ".xcodeproj") }
    func projectForPod(_ root: String) -> URL { projectForName(projectNameForPod(root)) }

    func prepareMultipleProjects() throws {
        guard multipleProjects, aggregateProject == nil else { return }
        let owners = targetOwners.mapValues(projectNameForPod)
        let roots = Set(owners.values).sorted()
        try NativePodProjectNames.validate(Set(roots))
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

/// Validate aliases before source installation can change the managed sandbox.
enum NativePodProjectNames {
    static func name(for root: String, manifest: [String: Any]) -> String {
        for target in manifest["targets"] as? [[String: Any]] ?? [] {
            for dependency in target["dependencies"] as? [[String: Any]] ?? []
            where (dependency["name"] as? String).map(NativePodName.root) == root {
                if let name = (dependency["options"] as? [String: Any])?["project_name"] as? String { return name }
            }
        }
        return root
    }

    static func validate(_ names: Set<String>) throws {
        guard names.allSatisfy(NativeTargetNames.isFileComponent) else {
            throw Diagnostic("SP-XCODE-PROJECT", stage: "integrate", "Invalid pod project name")
        }
        let locale = Locale(identifier: "en_US_POSIX")
        let identities = names.map { $0.folding(options: .caseInsensitive, locale: locale) }
        guard !identities.contains("pods"), Set(identities).count == names.count else {
            throw Diagnostic(
                "SP-XCODE-PROJECT", stage: "integrate", "Pod project names conflict on a case-insensitive filesystem",
                file: names.sorted().joined(separator: ", "))
        }
    }

    static func validate(manifest: [String: Any], roots: Set<String>? = nil) throws {
        let options = manifest["options"] as? [String: Any] ?? [:]
        guard options["generate_multiple_pod_projects"] as? Bool == true,
            options["skip_pods_project_generation"] as? Bool != true
        else { return }
        let targets = manifest["targets"] as? [[String: Any]] ?? []
        let declarations = targets.flatMap {
            ($0["dependencies"] as? [[String: Any]] ?? []) + ($0["search_dependencies"] as? [[String: Any]] ?? [])
        }
        let selected = roots ?? Set(declarations.compactMap { ($0["name"] as? String).map(NativePodName.root) })
        try validate(Set(selected.map { name(for: $0, manifest: manifest) }))
    }
}
