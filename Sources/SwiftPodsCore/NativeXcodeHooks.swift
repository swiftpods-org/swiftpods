import Foundation

extension NativeXcode {
    func validatePackageOwnership() throws {
        let records = integrationSettings["_swift_packages"] as? [String: [String: Any]] ?? [:]
        for (path, user) in userProjects {
            if let record = records[path] { try NativeSwiftPackageIntegrator.validate(user, record: record) }
        }
    }

    /// Called after a successful hook, whose input ownership was validated before
    /// handing control to Ruby. Include explicit project.save callbacks as well.
    func recordPackageHookChanges() throws -> URL? {
        guard var records = integrationSettings["_swift_packages"] as? [String: [String: Any]] else { return nil }
        let before = try jsonData(records)
        for (path, user) in userProjects {
            guard let owned = records[path]?["objects"] as? [String: [String: Any]] else { continue }
            // Refresh only objects already owned; hook-created user objects stay user-owned.
            records[path]?["objects"] = Dictionary(
                uniqueKeysWithValues: owned.keys.compactMap { id in
                    user.objects[id].map { (id, $0) }
                })
        }
        guard try jsonData(records) != before else { return nil }
        integrationSettings["_swift_packages"] = records
        try jsonData(integrationSettings).writeIfChanged(to: integrationSettingsURL, options: .atomic)
        return integrationSettingsURL
    }

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
