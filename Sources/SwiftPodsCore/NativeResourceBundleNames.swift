import Foundation

enum NativeResourceBundleNames {
    /// Display names are compatible when unambiguous; identities never depend
    /// on concatenating user-controlled names with a separator.
    static func assign(_ preferred: [String: String], reserved: Set<String>) -> [String: String] {
        NativeTargetNames.assign(preferred, reserved: reserved, suffix: { String($0.prefix(16)) })
    }
}

extension NativeXcode {
    func resourceBundleIdentity(_ bundle: String, variant: String, owner: String) throws -> String {
        try digest(jsonData(["variant": variant, "owner": owner, "bundle": bundle]))
    }

    func prepareResourceBundleLabels() throws {
        var preferred: [String: String] = [:]
        var scoped: [String: String] = [:]
        let consumerLabels = (manifest["targets"] as? [[String: Any]] ?? []).map {
            $0["label"] as? String ?? "Pods-" + ($0["name"] as? String ?? "")
        }
        var reserved = Set(consumerLabels + consumerLabels.map { $0 + "-Resources" })
        let active = activeVariants
        let current = currentVariant
        defer {
            activeVariants = active
            currentVariant = current
        }
        for variant in variantPlan?.variants.values.sorted(by: { $0.key < $1.key }) ?? [] {
            guard let spec = resolution.specs[variant.root] else { continue }
            selectVariant(variant)
            reserved.insert(variant.label)
            let library = try NativeVariantPlan.attributes(spec, names: variant.names, platform: variant.platform)
            var owners: [(name: String, label: String, attributes: [String: Any])] = [
                (variant.root, variant.label, library)
            ]
            for request in variant.supplementary {
                let kind = try spec.kind(request.name)
                let label = try supplementaryLabel(spec, request: request, kind: kind)
                let attributes = try spec.supplementaryAttributes(request.name, platform: request.platform)
                reserved.insert(label)
                if kind == .test, attributes["requires_app_host"] as? Bool == true,
                    attributes["app_host_name"] == nil
                {
                    reserved.insert(try defaultAppHostLabel(spec, request: request))
                }
                owners.append((request.name, label, attributes))
            }
            for owner in owners {
                for bundle in (owner.attributes["resource_bundles"] as? [String: Any] ?? [:]).keys {
                    let key = try resourceBundleIdentity(bundle, variant: variant.key, owner: owner.name)
                    preferred[key] = variant.label + "-" + bundle
                    scoped[key] = owner.label + "-" + bundle
                }
            }
        }
        let counts = Dictionary(grouping: preferred.keys, by: { preferred[$0]! }).mapValues(\.count)
        for key in preferred.keys.sorted() {
            if counts[preferred[key]!]! > 1 || reserved.contains(preferred[key]!) {
                preferred[key] = scoped[key]
            }
        }
        resourceBundleLabels = NativeResourceBundleNames.assign(preferred, reserved: reserved)
    }
}
