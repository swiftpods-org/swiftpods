import Foundation

extension NativeXcode {
    /// Recognize the standard aggregate products and generated phases left by
    /// an existing compatible installation. Preserve other user project objects.
    func removePreviousAggregateIntegration(_ user: NativePBX) {
        let labels = (manifest["targets"] as? [[String: Any]] ?? []).map { $0["label"] as? String ?? "Pods-" + ($0["name"] as? String ?? "") }
        let names = Set(labels.flatMap { label in [label.replacingOccurrences(of: "-", with: "_") + ".framework", "lib" + label + ".a"] })
        var remove = Set(user.objects.compactMap { id, value -> String? in
            guard value["isa"] as? String == "PBXFileReference", value["sourceTree"] as? String == "BUILT_PRODUCTS_DIR", names.contains(value["path"] as? String ?? "") else { return nil }
            return id
        })
        let builds = user.objects.compactMap { id, value in (value["fileRef"] as? String).map { remove.contains($0) } == true ? id : nil }
        remove.formUnion(builds)
        for (id, value) in user.objects where value["isa"] as? String == "PBXNativeTarget" {
            for phase in value["buildPhases"] as? [String] ?? [] {
                guard let name = user.objects[phase]?["name"] as? String else { continue }
                if ["[CP] Copy Pods Resources", "[CP] Embed Pods Frameworks", "[CP] Check Pods Manifest.lock"].contains(name) {
                    if phase != NativePBX.identifier("swiftpods:manifest:" + id) { remove.insert(phase) }
                } else if name.hasPrefix(NativeScriptPhase.prefix) {
                    let raw = String(name.dropFirst(NativeScriptPhase.prefix.count))
                    if phase != NativePBX.identifier("script:" + id + ":" + raw) { remove.insert(phase) }
                }
            }
        }
        for id in remove { user.objects.removeValue(forKey: id) }
        for id in Array(user.objects.keys) {
            for key in ["files", "children", "buildPhases"] {
                if let values = user.objects[id]?[key] as? [String] { user.objects[id]?[key] = values.filter { !remove.contains($0) } }
            }
        }
    }
}
