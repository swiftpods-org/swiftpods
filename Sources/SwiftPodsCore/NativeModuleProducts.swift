import Foundation

extension NativeXcode {
    /// Frameworks sharing a module may belong to separate consumers or configurations.
    func validateFrameworkModules() throws {
        let previous = activeVariants
        defer { activeVariants = previous }
        for target in manifest["targets"] as? [[String: Any]] ?? [] {
            selectConsumer(target)
            let platform = target["platform"] as? [String: String] ?? [:]
            let requests = try nativeDependencies(target).flatMap {
                try NativeDependency(
                    $0, platform: platform["name"] ?? "ios", deployment: platform["deployment_target"] ?? "0"
                )
                .expandedSelections()
            }
            for configuration in configurationNames {
                let roots = try dependencyRoots(requests.filter { dependencyEnabled($0, configuration: configuration) })
                var modules: [String: String] = [:]
                for root in roots.sorted() {
                    guard let spec = resolution.specs[root],
                        let variant = variantPlan?.variants[variantKey(root, platform["name"] ?? "ios")],
                        variant.mode != "library"
                    else { continue }
                    let module = spec.moduleName.lowercased()
                    if let other = modules[module], other != root {
                        throw Diagnostic(
                            "SP-XCODE-MODULE-CONFLICT", stage: "integrate",
                            "Pods \(other) and \(root) provide the same framework module \(spec.moduleName) in \(configuration)",
                            file: target["name"] as? String)
                    }
                    modules[module] = root
                }
            }
        }
    }
}
