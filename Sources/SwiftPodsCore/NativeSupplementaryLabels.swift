import Foundation

extension NativeXcode {
    func supplementaryLabelIdentity(_ request: NativeDependency) throws -> String {
        try digest(jsonData([
            "variant": variantKey(request.root, request.platform), "kind": "spec", "name": request.name,
        ]))
    }

    private func appHostLabelIdentity(_ spec: NativeSpec, request: NativeDependency) throws -> String {
        try digest(jsonData([
            "variant": variantKey(request.root, request.platform), "kind": "host",
            "type": spec.testType(request.name, platform: request.platform).label,
        ]))
    }

    func defaultAppHostLabel(_ spec: NativeSpec, request: NativeDependency) throws -> String {
        if let label = supplementaryLabels[try appHostLabelIdentity(spec, request: request)] { return label }
        return "AppHost-" + libraryLabel(request.root, request.platform) + "-"
            + (try spec.testType(request.name, platform: request.platform)).label + "-Tests"
    }

    func prepareSupplementaryLabels() throws {
        supplementaryLabels = [:]
        let consumers = (manifest["targets"] as? [[String: Any]] ?? []).map {
            $0["label"] as? String ?? "Pods-" + ($0["name"] as? String ?? "")
        }
        var reserved = Set(["Pods"] + consumers + consumers.map { $0 + "-Resources" })
        var preferred: [String: String] = [:]
        let active = activeVariants
        let current = currentVariant
        defer {
            activeVariants = active
            currentVariant = current
        }
        for variant in variantPlan?.variants.values.sorted(by: { $0.key < $1.key }) ?? [] {
            reserved.insert(variant.label)
            guard let spec = resolution.specs[variant.root] else { continue }
            selectVariant(variant)
            for request in variant.supplementary {
                let kind = try spec.kind(request.name)
                guard kind != .library else { continue }
                let key = try supplementaryLabelIdentity(request)
                preferred[key] = try supplementaryLabel(spec, request: request, kind: kind)
                let attributes = try spec.supplementaryAttributes(request.name, platform: request.platform)
                if kind == .test, attributes["requires_app_host"] as? Bool == true, attributes["app_host_name"] == nil {
                    let host = try appHostLabelIdentity(spec, request: request)
                    preferred[host] = try defaultAppHostLabel(spec, request: request)
                }
            }
        }
        supplementaryLabels = NativeTargetNames.assign(preferred, reserved: reserved)
    }
}
