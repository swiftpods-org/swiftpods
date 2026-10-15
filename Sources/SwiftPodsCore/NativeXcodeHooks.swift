import Foundation

extension NativeXcode {
    var hookProject: [String: Any] { hookDescription() }
    func applyHook(_ value: [String: Any]) throws {
        if value["generated"] as? Bool == false { return }
        if value["graph"] != nil {
            try applyHookGraph(value, to: podsProject)
            for child in value["projects"] as? [[String: Any]] ?? [] {
                guard let path = child["path"] as? String, let destination = generatedProjects[path] else {
                    throw Diagnostic("SP-HOOK-PROJECT", stage: "hook", "Unknown generated project")
                }
                try applyHookGraph(child, to: destination)
            }
            return
        }
        guard let targets = value["targets"] as? [[String: Any]], targets.count == hookTargets.count else {
            throw Diagnostic(
                "SP-HOOK-UNSUPPORTED", stage: "hook", "Changing target membership through hooks is not implemented")
        }
        for target in targets {
            guard let name = target["name"] as? String, let mapping = configurations[name] else {
                throw Diagnostic("SP-HOOK-UNSUPPORTED", stage: "hook", "Hook returned an unknown target")
            }
            for configuration in target["build_configurations"] as? [[String: Any]] ?? [] {
                guard let name = configuration["name"] as? String, let id = mapping[name],
                    let settings = configuration["build_settings"] as? [String: Any]
                else { throw Diagnostic("SP-HOOK-UNSUPPORTED", stage: "hook", "Invalid hook configuration") }
                graph.objects[id]?["buildSettings"] = settings
            }
        }
        hookTargets = targets
    }
    func savePods() throws -> URL {
        if multipleProjects { try saveMultipleProjects() }
        try podsProject.save()
        try saveProjectInventory()
        return podsProject.url
    }
}
