import Foundation

extension NativeXcode {
    func installationResult(_ variant: NativePodVariant) throws -> [String: Any] {
        let selected = supplementaryTargets[variant.key] ?? [:]
        var tests: [String: String] = [:]
        var apps: [String: String] = [:]
        for (name, id) in selected {
            if try resolution.specs[variant.root]?.kind(name) == .test { tests[name] = id } else { apps[name] = id }
        }
        let bundles = supplementaryBundleTargets[variant.key] ?? [:]
        return [
            "native_target": libraryTargets[variant.key] as Any? ?? NSNull(),
            "resource_bundle_targets": resourceBundleTargets[variant.key] ?? [],
            "test_targets": tests, "app_targets": apps,
            "test_resource_bundle_targets": bundles.filter { tests[$0.key] != nil },
            "app_resource_bundle_targets": bundles.filter { apps[$0.key] != nil },
            "test_app_host_targets": Array(Set(tests.values.compactMap { testTargetHosts[$0] })).sorted(),
        ]
    }
}
