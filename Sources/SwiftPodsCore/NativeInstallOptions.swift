import Foundation

enum NativeInstallationOptions {
    static func validate(_ values: [String: Any]) throws {
        let booleans: Set<String> = [
            "clean", "deduplicate_targets", "deterministic_uuids", "integrate_targets", "lock_pod_sources",
            "warn_for_multiple_pod_sources", "warn_for_unused_master_specs_repo", "disable_input_output_paths",
            "preserve_pod_file_structure", "generate_multiple_pod_projects", "incremental_installation",
            "skip_pods_project_generation", "parallel_pod_downloads",
        ]
        for (key, value) in values {
            if booleans.contains(key) || key == "share_schemes_for_development_pods" {
                if key == "share_schemes_for_development_pods", value is [String] { continue }
                guard CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID() else {
                    throw Diagnostic("SP-INSTALL-OPTION", stage: "analyze", key + " must be boolean")
                }
            } else if key == "parallel_pod_download_thread_pool_size" {
                guard CFGetTypeID(value as CFTypeRef) != CFBooleanGetTypeID(), let size = value as? Int, size >= 0
                else { throw Diagnostic("SP-INSTALL-OPTION", stage: "analyze", key + " must be a nonnegative integer") }
            } else {
                throw Diagnostic("SP-INSTALL-OPTION", stage: "analyze", "Unknown installation option: " + key)
            }
        }
    }
}

extension NativeXcode {
    var installationOptions: [String: Any] { manifest["options"] as? [String: Any] ?? [:] }
    func inhibitWarnings(_ variant: NativePodVariant) -> Bool {
        let consumers = (manifest["targets"] as? [[String: Any]] ?? []).filter {
            variant.consumerKeys.contains(nativeConsumerKey($0))
        }
        let values = consumers.map { target -> Bool in
            let declarations = (target["dependencies"] as? [[String: Any]] ?? []).filter {
                ($0["name"] as? String).map(NativePodName.root) == variant.root
            }
            return declarations.compactMap { ($0["options"] as? [String: Any])?["inhibit_warnings"] as? Bool }.first
                ?? (target["inhibit_warnings"] as? Bool ?? false)
        }
        if Set(values).count == 1 { return values.first ?? false }
        return manifest["inhibit_warnings"] as? Bool ?? false
    }
    func applyInputOutputOptions(_ target: String, graph: NativePBX) {
        guard installationOptions["disable_input_output_paths"] as? Bool == true else { return }
        for id in graph.objects[target]?["buildPhases"] as? [String] ?? [] {
            guard graph.objects[id]?["isa"] as? String == "PBXShellScriptBuildPhase",
                (graph.objects[id]?["name"] as? String)?.hasPrefix("[SwiftPods]") == true
            else { continue }
            for key in ["inputPaths", "outputPaths", "inputFileListPaths", "outputFileListPaths"] {
                graph.objects[id]?[key] = [] as [String]
            }
            graph.objects[id]?["alwaysOutOfDate"] = "1"
        }
    }
    func developmentSchemes() throws {
        let value = installationOptions["share_schemes_for_development_pods"]
        guard value as? Bool == true || value is [String] else { return }
        for variant in variantPlan?.variants.values.sorted(by: { $0.label < $1.label }) ?? [] {
            guard resolution.specs[variant.root]?.local == true,
                value as? Bool == true || nativeStrings(value).contains(variant.root),
                let id = libraryTargets[variant.key]
            else { continue }
            let spec = resolution.specs[variant.root]!
            let attributes = try spec.attributes(spec.name, platform: variant.platform)
            try writeScheme(
                id: id, label: variant.label, kind: .library, host: nil,
                options: attributes["scheme"] as? [String: Any] ?? [:])
        }
    }
}
