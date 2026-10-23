import Foundation

enum NativeConsumerLabels {
    static func normalized(_ manifest: [String: Any], project: URL) throws -> [String: Any] {
        guard var targets = manifest["targets"] as? [[String: Any]] else { return manifest }
        var preferred: [String: String] = [:]
        var identities: [String] = []
        for target in targets {
            let name = target["name"] as? String ?? ""
            let label = target["label"] as? String ?? "Pods-" + name
            guard NativeTargetNames.isFileComponent(label) else {
                throw Diagnostic(
                    "SP-XCODE-TARGET", stage: "analyze", "Consumer target label must be a filename component",
                    file: name)
            }
            let location: String
            if let raw = target["project"] as? String ?? manifest["project"] as? String {
                let supplied = URL(fileURLWithPath: raw, relativeTo: project).standardizedFileURL
                let selected =
                    supplied.pathExtension == "xcodeproj" ? supplied : supplied.appendingPathExtension("xcodeproj")
                location = NativePath.relativePath(
                    of: selected.resolvingSymlinksInPath(), to: project.resolvingSymlinksInPath())
            } else {
                location = "."
            }
            let key = try digest(jsonData(["project": location, "name": name]))
            guard preferred[key] == nil else {
                throw Diagnostic(
                    "SP-XCODE-TARGET", stage: "analyze", "Consumer target is declared more than once", file: name)
            }
            identities.append(key)
            preferred[key] = label
        }
        // A consumer owns both its aggregate and its resource target namespace.
        let labels = NativeTargetNames.assign(
            preferred, reserved: ["Pods"], relatedNames: { [$0, $0 + "-Resources"] })
        for index in targets.indices {
            let key = identities[index]
            if labels[key] != preferred[key] { targets[index]["label"] = labels[key] }
        }
        var result = manifest
        result["targets"] = targets
        return result
    }
}
