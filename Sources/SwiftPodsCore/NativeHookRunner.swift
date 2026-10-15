import Foundation

/// Runs public hooks against the live installation and project adapters.
final class NativeHookRunner {
    let dsl: NativeDSL?
    let projectAccess: NativeProjectAccess
    let xcode: NativeXcode?
    let project: URL
    let manifest: [String: Any]
    let installed: [String: NativeSpec]
    let requests: [NativeDependency]
    let variants: NativeVariantPlan
    let integrateUserProjects: Bool
    let record: ([String: Any]) -> Void

    init(
        dsl: NativeDSL?, projectAccess: NativeProjectAccess, xcode: NativeXcode?, project: URL, manifest: [String: Any],
        installed: [String: NativeSpec], requests: [NativeDependency], variants: NativeVariantPlan,
        integrateUserProjects: Bool, record: @escaping ([String: Any]) -> Void
    ) {
        self.dsl = dsl
        self.projectAccess = projectAccess
        self.xcode = xcode
        self.project = project
        self.manifest = manifest
        self.installed = installed
        self.requests = requests
        self.variants = variants
        self.integrateUserProjects = integrateUserProjects
        self.record = record
    }

    func run(_ name: String, plugin: Bool = false) throws {
        let projectAccess = self.projectAccess
        let xcode = self.xcode
        let project = self.project
        let manifest = self.manifest
        let installed = self.installed
        let requests = self.requests
        let plan = self.variants
        let integrateUserProjects = self.integrateUserProjects
        let record = self.record
        func writeEvent(_ url: URL) { record(["kind": "managed_write", "path": url.path]) }
        guard let dsl else { return }
        let fallback: [String: Any] = [
            "path": project.appendingPathComponent("Pods/Pods.xcodeproj").path, "targets": [],
        ]
        dsl.callback = { request in
            guard let xcode else {
                throw Diagnostic("SP-HOOK-PROJECT", stage: "hook", "Project generation is disabled")
            }
            let raw = (request["value"] as? [String: Any])?["path"] as? String ?? ""
            let path = URL(fileURLWithPath: raw).standardizedFileURL.appendingPathComponent(
                "project.pbxproj")
            let selected =
                path == xcode.podsProject.url
                || xcode.generatedProjects[path.deletingLastPathComponent().path] != nil
                || xcode.userProjects[path.path] != nil
            let result =
                try selected && request["callback"] as? String != "create_project"
                ? xcode.hookCallback(request) : projectAccess.callback(request, writable: true)
            if request["callback"] as? String == "save_project",
                let value = request["value"] as? [String: Any], let path = value["path"] as? String
            {
                writeEvent(URL(fileURLWithPath: path).appendingPathComponent("project.pbxproj"))
            }
            return result
        }
        defer { dsl.callback = nil }
        let variants = plan.variants.values.sorted { $0.label < $1.label }
        let pods: [[String: Any]]
        if variants.isEmpty {
            pods = installed.values.sorted { $0.name < $1.name }.map { spec in
                [
                    "name": spec.name, "pod_name": spec.name, "root": spec.directory?.path ?? "",
                    "local": spec.local, "specification": spec.data,
                ]
            }
        } else {
            pods = try variants.compactMap { variant in
                guard let spec = installed[variant.root] else { return nil }
                return [
                    "name": variant.label, "pod_name": spec.name, "root": spec.directory?.path ?? "",
                    "local": spec.local, "specification": spec.data,
                    "spec_names": variant.names + variant.supplementary.map(\.name),
                    "build_type": xcode?.variantPlan?.variants[variant.key]?.mode ?? variant.mode,
                    "platform_name": variant.platform, "deployment_target": variant.consumerDeployment,
                    "swift_version": variant.swiftVersion ?? NSNull(),
                    "consumer_targets": variant.consumerTargets, "consumer_keys": variant.consumerKeys,
                    "installation_result": try xcode?.installationResult(variant) ?? [:],
                ]
            }
        }
        let result = try dsl.object(
            plugin ? "plugin_hook" : "hook",
            [
                "name": name, "manifest": manifest,
                "integrate_user_projects": integrateUserProjects,
                "project": xcode?.hookProject ?? fallback.merging(["generated": false]) { _, new in new },
                "projects": xcode?.hookGeneratedProjects ?? [], "pod_targets": pods,
            ])
        if name == "pre_install", let xcode {
            var changed = installed
            for entry in result["pod_targets"] as? [[String: Any]] ?? [] {
                guard let label = entry["name"] as? String,
                    let variant = xcode.variantPlan?.variants.values.first(where: { $0.label == label }),
                    let mode = entry["build_type"] as? String,
                    ["library", "static", "dynamic"].contains(mode)
                else {
                    throw Diagnostic(
                        "SP-HOOK-TARGET", stage: "hook", "Hook returned an invalid pod build type")
                }
                xcode.variantPlan?.variants[variant.key]?.mode = mode
                if let data = entry["specification"] as? [String: Any],
                    let original = installed[variant.root]
                {
                    var spec = try NativeSpec(
                        data: data, repository: original.repository, directory: original.directory,
                        local: original.local, checksum: original.checksum)
                    guard spec.name == original.name, spec.version == original.version else {
                        throw Diagnostic(
                            "SP-HOOK-SPEC", stage: "hook",
                            "Hooks cannot change a resolved specification's identity")
                    }
                    spec.checkout = original.checkout
                    changed[variant.root] = spec
                }
            }
            xcode.resolution = NativeResolution(specs: changed, requests: requests)
        }
        if let xcode {
            try xcode.applyHook(result)
            for value in result["user_projects"] as? [[String: Any]] ?? [] {
                guard let path = value["path"] as? String,
                    let user = xcode.userProjects[
                        URL(fileURLWithPath: path).appendingPathComponent("project.pbxproj").path]
                else {
                    throw Diagnostic(
                        "SP-HOOK-PROJECT", stage: "hook", "Hook returned an unknown consumer project")
                }
                var before = user.root
                before["objects"] = user.objects
                try xcode.applyHookGraph(value, to: user)
                var after = user.root
                after["objects"] = user.objects
                if try jsonData(before) != jsonData(after) {
                    try user.save()
                    writeEvent(user.url)
                }
            }
        }
        if !plugin { record(["kind": "phase", "name": name]) }
    }
}
