import Foundation

extension NativeXcode {
    /// Recognize the standard aggregate products and generated phases left by
    /// an existing compatible installation. Preserve other user project objects.
    func removePreviousAggregateIntegration(_ user: NativePBX) throws {
        let selected = try (manifest["targets"] as? [[String: Any]] ?? []).filter {
            try projectPath($0).standardizedFileURL.resolvingSymlinksInPath().path
                == user.url.standardizedFileURL.resolvingSymlinksInPath().path
        }
        let namesOfTargets = Set(selected.compactMap { $0["name"] as? String })
        let selectedTargets = Set(
            user.objects.compactMap { id, object -> String? in
                object["isa"] as? String == "PBXNativeTarget"
                    && namesOfTargets.contains(object["name"] as? String ?? "")
                    ? id : nil
            })
        let selectedPhases = Set(selectedTargets.flatMap { user.objects[$0]?["buildPhases"] as? [String] ?? [] })
        let otherPhases = Set(
            user.objects.compactMap { id, object -> [String]? in
                guard object["isa"] as? String == "PBXNativeTarget", !selectedTargets.contains(id) else { return nil }
                return object["buildPhases"] as? [String] ?? []
            }.flatMap { $0 })
        let selectedBuilds = Set(selectedPhases.flatMap { user.objects[$0]?["files"] as? [String] ?? [] })
        let labels = selected.map {
            $0["label"] as? String ?? "Pods-" + ($0["name"] as? String ?? "")
        }
        let names = Set(
            labels.flatMap { label in
                [label.replacingOccurrences(of: "-", with: "_") + ".framework", "lib" + label + ".a"]
            })
        var remove = Set(
            user.objects.compactMap { id, value -> String? in
                guard value["isa"] as? String == "PBXFileReference",
                    value["sourceTree"] as? String == "BUILT_PRODUCTS_DIR",
                    names.contains(value["path"] as? String ?? "")
                else { return nil }
                return id
            })
        let builds = user.objects.compactMap { id, value in
            selectedBuilds.contains(id) && (value["fileRef"] as? String).map { remove.contains($0) } == true ? id : nil
        }
        remove.formUnion(builds)
        for (id, value) in user.objects where selectedTargets.contains(id) {
            for phase in value["buildPhases"] as? [String] ?? [] {
                guard let name = user.objects[phase]?["name"] as? String else { continue }
                if ["[CP] Copy Pods Resources", "[CP] Embed Pods Frameworks", "[CP] Check Pods Manifest.lock"].contains(
                    name)
                {
                    if phase != NativePBX.identifier("swiftpods:manifest:" + id) { remove.insert(phase) }
                } else if name.hasPrefix(NativeScriptPhase.prefix) {
                    let raw = String(name.dropFirst(NativeScriptPhase.prefix.count))
                    if phase != NativePBX.identifier("script:" + id + ":" + raw) { remove.insert(phase) }
                }
            }
        }
        // Detach only selected consumers. Shared objects used by another target
        // stay alive, even when their names resemble a previous integration.
        for id in selectedTargets.union(selectedPhases.subtracting(otherPhases)) {
            for key in ["files", "buildPhases"] {
                if let values = user.objects[id]?[key] as? [String] {
                    user.objects[id]?[key] = values.filter { !remove.contains($0) }
                }
            }
        }
        for _ in 0..<3 {
            for id in remove where user.objects[id] != nil {
                let used = user.objects.values.contains { object in
                    object["isa"] as? String != "PBXGroup" && object["isa"] as? String != "PBXVariantGroup"
                        && object.values.contains { ($0 as? String) == id || ($0 as? [String])?.contains(id) == true }
                }
                guard !used else { continue }
                user.objects.removeValue(forKey: id)
                for group in Array(user.objects.keys) {
                    if let children = user.objects[group]?["children"] as? [String] {
                        user.objects[group]?["children"] = children.filter { $0 != id }
                    }
                }
            }
        }
    }
}
