import Foundation

extension CLIContext {
    func verifyRuntime() throws -> Int32 {
        guard arguments == ["runtime", "verify"] else {
            throw Diagnostic("SP-CLI-ARGUMENT", stage: "cli", "Use runtime verify")
        }
        let managed = try managedBundle()
        try managed.verify()
        let ruby = try ExternalRuby.locate(
            manifest: managed.manifest, environment: environment, bundleRoot: managed.root)
        try output(
            [
                "schema_version": 1, "status": "passed", "profile": managed.manifest["id"] ?? "unknown",
                "ruby": ruby.metadata, "runtime_mode": "external", "executed_project_code": false,
            ])
        return 0
    }

    func runVersion() throws -> Int32 {
        guard arguments.count == 1 else {
            throw Diagnostic("SP-CLI-ARGUMENT", stage: "cli", "Unknown version argument")
        }
        if machine {
            var report = bundle?.manifest ?? ["runtime_status": "missing"]
            report.removeValue(forKey: "files")
            report["producer"] = "SwiftPods"
            report["swiftpods_version"] = CLI.version
            if let environmentName, let bundle {
                var profile = try EnvironmentProfile.load(
                    name: environmentName, project: directory, bundle: bundle, environment: environment
                ).metadata
                profile.removeValue(forKey: "files")
                report["environment_profile"] = profile
            }
            try output(report)
        } else {
            print("SwiftPods \(CLI.version) (\(bundle?.manifest["id"] as? String ?? "runtime missing"))")
        }
        return 0
    }

    func runDoctor() throws -> Int32 {
        var options = Array(arguments.dropFirst())
        let platform = try CommandOptions.take("--platform", from: &options)
        let variant = try CommandOptions.take("--variant", from: &options)
        let architecture = try CommandOptions.take("--arch", from: &options)
        let application = try CommandOptions.take("--app", from: &options)
        let deploymentTarget = try CommandOptions.take("--deployment-target", from: &options)
        guard command != "migrate" || options.contains("--check") else {
            throw Diagnostic("SP-CLI-ARGUMENT", stage: "cli", "Use migrate --check")
        }
        let platforms = ["osx", "ios", "tvos", "watchos", "visionos"]
        let variants = ["device", "simulator", "maccatalyst"]
        let architectures = [
            "arm64", "arm64e", "arm64_32", "armv7k", "armv7", "armv7s", "x86_64", "x86_64h", "i386", "arm",
        ]
        guard options.allSatisfy({ ["--check", "--static"].contains($0) }),
            platform.map(platforms.contains) ?? true,
            variant.map(variants.contains) ?? true,
            architecture.map(architectures.contains) ?? true
        else {
            throw Diagnostic(
                "SP-CLI-ARGUMENT", stage: "cli", "Unknown doctor option or platform/variant/architecture")
        }
        var report = Doctor(
            directory: directory, platform: platform, variant: variant, architecture: architecture,
            application: application.map {
                URL(fileURLWithPath: $0, relativeTo: directory).standardizedFileURL
            }, deploymentTarget: deploymentTarget
        ).report(bundle: bundle)
        if let environmentName {
            let managed = try managedBundle()
            let profile = try EnvironmentProfile.load(
                name: environmentName, project: directory, bundle: managed, environment: environment)
            var metadata = profile.metadata
            metadata.removeValue(forKey: "files")
            report["environment_profile"] = metadata
        }
        if machine {
            try output(report)
        } else {
            print("Static inspection: full compatibility is unverified")
            for check in report["checks"] as? [[String: Any]] ?? [] {
                print(
                    redactor.scrub(
                        "[\(check["status"] ?? "unknown")] \(check["name"] ?? "check"): \(check["message"] ?? "")"
                    ))
            }
        }
        return report["status"] as? String == "failed" ? 1 : 0
    }

    func readGraph() throws -> Int32 {
        let options = Array(arguments.dropFirst(command == "why" ? 2 : 1))
        guard options.isEmpty else {
            throw Diagnostic("SP-CLI-ARGUMENT", stage: "cli", "Unknown graph/why option")
        }
        var effective = bundle?.environment(from: environment) ?? environment
        if let environmentName {
            let managed = try managedBundle()
            effective.merge(
                try EnvironmentProfile.load(
                    name: environmentName, project: directory, bundle: managed, environment: environment
                ).overrides
            ) { _, new in new }
        }
        var report = try ProjectState(directory: directory).graph(environment: effective)
        if command == "why" {
            guard arguments.count >= 2, !CommandOptions.hasOptionPrefix(arguments[1]) else {
                throw Diagnostic("SP-CLI-ARGUMENT", stage: "cli", "why requires a pod name")
            }
            report = try DependencyGraph.why(arguments[1], report: report)
        }
        try output(report)
        return 0
    }
}
