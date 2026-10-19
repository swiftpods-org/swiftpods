import Foundation

extension NativeXcode {
    /// Reconcile consumers that disappeared from the manifest, including projects
    /// that are no longer selected by any current target.
    func removeOmittedConsumers() throws -> [URL] {
        var selected: [String: Set<String>] = [:]
        for target in manifest["targets"] as? [[String: Any]] ?? [] {
            selected[try projectPath(target).path, default: []].insert(target["name"] as? String ?? "")
        }
        let paths = NativeIntegrationSettings.projectPaths(integrationSettings)
        var written: [URL] = []
        for path in paths.sorted() {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard url.lastPathComponent == "project.pbxproj",
                url.deletingLastPathComponent().pathExtension == "xcodeproj"
            else {
                throw Diagnostic("SP-DEINTEGRATE-PATH", stage: "integrate", "Invalid owned project", file: path)
            }
            guard FileManager.default.fileExists(atPath: path) else {
                integrationSettings = NativeIntegrationSettings.removingProject(path, from: integrationSettings)
                continue
            }
            try ProjectState(directory: project).registerProject(url)
            let user = try userProjects[path] ?? NativePBX(url, existing: true)
            removeMissingConfigurationRecords(path, user: user)
            let omitted = Set(
                user.objects.compactMap { id, object -> String? in
                    guard object["isa"] as? String == "PBXNativeTarget",
                        !selected[path, default: []].contains(object["name"] as? String ?? "")
                    else { return nil }
                    let list = object["buildConfigurationList"] as? String ?? ""
                    let configs = user.objects[list]?["buildConfigurations"] as? [String] ?? []
                    return configs.contains { integrationSettings[path + ":" + $0] != nil } ? id : nil
                })
            let unselectedProject = userProjects[path] == nil
            guard unselectedProject || !omitted.isEmpty else { continue }
            try NativeDeintegrator.restore(
                user, settings: integrationSettings, products: previousProducts,
                targets: unselectedProject ? nil : omitted)
            for target in omitted {
                let list = user.objects[target]?["buildConfigurationList"] as? String ?? ""
                for config in user.objects[list]?["buildConfigurations"] as? [String] ?? [] {
                    let key = path + ":" + config
                    integrationSettings.removeValue(forKey: key)
                    for field in ["_base_configurations", "_support_configurations"] {
                        var references = integrationSettings[field] as? [String: String] ?? [:]
                        references.removeValue(forKey: key)
                        integrationSettings[field] = references
                    }
                }
            }
            if unselectedProject {
                var records = integrationSettings["_swift_packages"] as? [String: [String: Any]] ?? [:]
                let packages = NativeSwiftPackageIntegrator()
                try packages.prepare(user, record: records[path])
                let remaining = packages.finish(user)
                // Keep ownership of objects still used by user-owned targets.
                let retained = remaining["objects"] as? [String: Any] ?? [:]
                integrationSettings = NativeIntegrationSettings.removingProject(path, from: integrationSettings)
                records = integrationSettings["_swift_packages"] as? [String: [String: Any]] ?? [:]
                if !retained.isEmpty { records[path] = remaining }
                integrationSettings["_swift_packages"] = records
                try user.save()
                written.append(user.url)
            }
        }
        return written
    }

    private func removeMissingConfigurationRecords(_ path: String, user: NativePBX) {
        let prefix = path + ":"
        let fields = ["_base_configurations", "_support_configurations"]
        let keys = Set(integrationSettings.keys)
            .union(fields.flatMap { (integrationSettings[$0] as? [String: String] ?? [:]).keys })
        for key in keys where key.hasPrefix(prefix) && user.objects[String(key.dropFirst(prefix.count))] == nil {
            integrationSettings.removeValue(forKey: key)
            for field in fields {
                var references = integrationSettings[field] as? [String: String] ?? [:]
                references.removeValue(forKey: key)
                integrationSettings[field] = references
            }
        }
    }
}
