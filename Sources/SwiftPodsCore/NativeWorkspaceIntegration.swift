import Foundation

extension NativeXcode {
    func prepareWorkspaces() throws -> [NativeWorkspace.Update] {
        guard let workspace = workspacePath() else {
            throw Diagnostic("SP-WORKSPACE", stage: "integrate", "No selected consumer workspace")
        }
        let userPaths = userProjects.values.map { $0.url.deletingLastPathComponent() }
        let podPaths =
            [project.appendingPathComponent("Pods/Pods.xcodeproj")]
            + (multipleProjects ? Set(targetOwners.values.map { projectForPod($0) }).sorted { $0.path < $1.path } : [])
        let root = workspace.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL
        func reference(_ path: URL) -> String {
            let value = path.standardizedFileURL
            guard let components = NativePath.relativeComponents(of: value, to: root), !components.isEmpty else {
                return "absolute:" + value.path
            }
            let relative = components.joined(separator: "/")
            let location = "group:" + relative
            // Xcode loses the reference if a leading combining mark joins the
            // prefix's colon. A dot component preserves the relative identity.
            return location.hasPrefix("group:") ? location : "group:./" + relative
        }
        let previous = integrationSettings["_workspaces"] as? [String: [String]] ?? [:]
        var updates: [NativeWorkspace.Update] = []
        for (raw, owned) in previous.sorted(by: { $0.key < $1.key }) where raw != workspace.path {
            let path = URL(fileURLWithPath: raw)
            if FileManager.default.fileExists(atPath: path.path) {
                updates.append(
                    try NativeWorkspace.prepare(
                        path, references: [], previous: owned, expected: workspaceFingerprints[raw]))
            }
        }
        let selected = try NativeWorkspace.prepare(
            workspace, references: (userPaths + podPaths).map(reference), previous: previous[workspace.path] ?? [],
            expected: workspaceFingerprints[workspace.path])
        updates.append(selected)
        integrationSettings["_workspaces"] = [
            workspace.path: selected.owned.filter(Set(podPaths.map(reference)).contains)
        ]
        let supplied = manifest["workspace"] as? String ?? workspace.deletingLastPathComponent().lastPathComponent
        let name = supplied.hasSuffix(".xcworkspace") ? supplied : supplied + ".xcworkspace"
        let location =
            NativePath.relativeComponents(of: workspace, to: project)?.joined(separator: "/")
            ?? (name as NSString).appendingPathComponent("contents.xcworkspacedata")
        integrationSettings["_workspace_paths"] = [workspace.path: location]
        return updates
    }
}
