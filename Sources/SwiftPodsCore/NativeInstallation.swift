import Foundation

extension NativeCommandSession {
    /// Evaluates, resolves and installs one command while preserving hook ordering.
    func install(_ request: NativeCommandRequest) throws -> HostResult? {
        let action = request.action
        let args = request.arguments
        let project = request.project
        func writeEvent(_ url: URL) { recordWrite(url) }
        let allowed = Set([
            "--deployment", "--repo-update", "--clean-install", "--verbose", "--silent", "--no-ansi", "--ansi",
            "--no-integrate",
        ])
        let options = args.filter { $0.hasPrefix("-") }
        guard options.allSatisfy(allowed.contains), action == "update" || args.allSatisfy({ $0.hasPrefix("-") })
        else {
            throw Diagnostic(
                "SP-CLI-ARGUMENT", stage: "cli",
                "Unsupported native engine option: \(args.joined(separator: " "))")
        }
        let hardened = environment["SWIFTPODS_HARDENED_MANIFEST"] != nil
        let dsl: NativeDSL? =
            hardened
            ? nil
            : try NativeDSL(bundle: bundle, environment: environment, directory: project, overrides: overrides)
        let manifestPath = project.appendingPathComponent(hardened ? "Podfile.json" : "Podfile")
        let projectAccess = NativeProjectAccess(root: project)
        dsl?.callback = { request in
            let result = try projectAccess.callback(request, writable: true)
            if request["callback"] as? String == "save_project",
                let path = (request["value"] as? [String: Any])?["path"] as? String
            {
                writeEvent(URL(fileURLWithPath: path).appendingPathComponent("project.pbxproj"))
            }
            return result
        }
        var manifest: [String: Any]
        if hardened {
            let input = try ExecutionPolicy.hardenedManifest(manifestPath)
            let platform = input["platform"] as! [String: String]
            manifest = input
            manifest["targets"] = (input["targets"] as! [[String: Any]]).map { target -> [String: Any] in
                var value = target
                value["platform"] = platform
                value["project"] = input["project"]
                value["frameworks"] = input["frameworks"]
                value["dependencies"] = (target["pods"] as! [[String: Any]]).map { pod -> [String: Any] in
                    [
                        "name": pod["name"]!, "requirements": pod["versions"] ?? [">= 0"],
                        "options": pod.filter { !["name", "versions"].contains($0.key) },
                    ]
                }
                return value
            }
        } else {
            _ = try dsl!.object("podfile", ["path": manifestPath.path])
            manifest = try dsl!.object("plugins_prepare")
        }
        let declaredOptions = manifest["options"] as? [String: Any] ?? [:]
        try NativeInstallationOptions.validate(declaredOptions)
        manifest = try NativeManifest.analyze(
            manifest, project: project,
            integrate: !options.contains("--no-integrate")
                && declaredOptions["integrate_targets"] as? Bool != false)
        if let dsl { manifest = try dsl.object("analyzed_podfile", ["targets": manifest["targets"] ?? []]) }
        guard let targets = manifest["targets"] as? [[String: Any]], !targets.isEmpty else {
            throw Diagnostic("SP-DSL-TARGET", stage: "resolve", "Podfile needs at least one concrete target")
        }
        for target in targets
        where !options.contains("--no-integrate") && declaredOptions["integrate_targets"] as? Bool != false {
            if let raw = target["project"] as? String {
                let path = URL(fileURLWithPath: raw, relativeTo: project).standardizedFileURL
                try ProjectState(directory: project).registerProject(
                    path.appendingPathComponent("project.pbxproj"))
            }
        }
        let direct = try targets.flatMap { target -> [NativeDependency] in
            let platform = target["platform"] as? [String: String] ?? [:]
            return try
                ((target["dependencies"] as? [[String: Any]] ?? [])
                + (target["search_dependencies"] as? [[String: Any]] ?? [])).flatMap {
                    try NativeDependency(
                        $0, platform: platform["name"] ?? "ios",
                        deployment: platform["deployment_target"] ?? "0"
                    ).expandedSelections()
                }
        }
        let lockURL = project.appendingPathComponent("Podfile.lock")
        let lock = try NativeLock(lockURL)
        let checksum = NativeLock.sha1(try Data(contentsOf: manifestPath))
        var contractManifest = manifest
        contractManifest["targets"] = (manifest["targets"] as? [[String: Any]] ?? []).map {
            $0.filter { $0.key != "_id" }
        }
        let manifestChecksum = digest(try jsonData(contractManifest))
        if options.contains("--deployment"), let previous = lock.manifestChecksum, previous != manifestChecksum {
            throw Diagnostic(
                "SP-DEPLOYMENT-LOCK", stage: "resolve",
                "Evaluated Podfile declarations differ from Podfile.lock")
        }
        if options.contains("--deployment"), lock.checksum != checksum {
            throw Diagnostic(
                "SP-DEPLOYMENT-LOCK", stage: "resolve",
                "Podfile differs from Podfile.lock or lockfile is missing")
        }
        let cache = URL(fileURLWithPath: bundle.environment(from: environment)["SWIFTPODS_CACHE_ROOT"]!)
        let declaredSources = nativeStrings(manifest["sources"])
        let defaults = try NativeRepositories(cache: cache).records().compactMap { $0["url"] as? String }
        let catalog = try NativeSources(
            project: project, cache: cache,
            sources: declaredSources.isEmpty ? defaults + ["https://cdn.cocoapods.org/"] : declaredSources,
            dsl: dsl, offline: environment["SWIFTPODS_OFFLINE"] == "1",
            refresh: options.contains("--repo-update"), hardened: hardened)
        let requestedUpdates = Set(
            args.filter { !$0.hasPrefix("-") }.map { String($0.split(separator: "/").first ?? "") })
        if action == "update",
            let unknown = requestedUpdates.subtracting(Set(lock.versions.keys).union(direct.map(\.root)))
                .sorted().first
        {
            throw Diagnostic(
                "SP-UPDATE-MISSING", stage: "resolve", "Requested pod is not declared or installed",
                file: unknown)
        }
        let changedRoots = try lock.changedRoots(direct)
        let updateRoots = lock.unlocked(requestedUpdates.union(changedRoots))
        catalog.pinnedCheckouts = lock.checkoutOptions.filter { !changedRoots.contains($0.key) }
        catalog.updating = action == "update" || !changedRoots.isEmpty
        catalog.updateRoots = action == "update" && requestedUpdates.isEmpty ? [] : updateRoots
        catalog.installationOptions = declaredOptions
        catalog.cleanInstall = options.contains("--clean-install")
        try catalog.register(direct)
        let update = updateRoots
        catalog.lockedRepositories =
            action == "outdated" || (action == "update" && requestedUpdates.isEmpty)
            ? [:] : lock.repositories.filter { !update.contains($0.key) }
        var unlockedLocal = Set<String>()
        for request in direct where request.options["path"] != nil && lock.versions[request.root] != nil {
            if let local = try catalog.candidates(request).first,
                local.checksum != lock.specChecksums[request.root]
            {
                unlockedLocal.insert(request.root)
            }
        }
        let pins =
            action == "outdated" || (action == "update" && requestedUpdates.isEmpty) ? [:] : lock.versions
        let resolver = NativeResolver(
            candidates: catalog.candidates, materialize: catalog.materialize, locked: pins,
            update: update.union(unlockedLocal))
        let resolved = try resolver.resolve(direct)
        for warning in catalog.sourceWarnings {
            events.append(warning.merging(["kind": "warning"]) { _, new in new })
        }
        if declaredOptions["warn_for_unused_master_specs_repo"] as? Bool != false,
            !declaredSources.contains("https://github.com/CocoaPods/Specs.git"),
            try NativeRepositories(cache: cache).records().contains(where: {
                $0["url"] as? String == "https://github.com/CocoaPods/Specs.git"
            })
        {
            events.append([
                "kind": "warning", "code": "SP-SOURCE-UNUSED",
                "message": "A registered master Git specs repository is not explicitly used by this Podfile",
            ])
        }
        if action == "outdated" {
            let changes = resolved.specs.values.filter { lock.versions[$0.name] != $0.version.description }
                .sorted { $0.name < $1.name }.map {
                    [
                        "name": $0.name, "installed": lock.versions[$0.name] ?? "absent",
                        "available": $0.version.description,
                    ]
                }
            events.append(["kind": "outdated", "pods": changes])
            if !machine && !silent {
                if changes.isEmpty { print("All dependencies are up to date.") }
                for change in changes {
                    print("\(change["name"]!): \(change["installed"]!) -> \(change["available"]!)")
                }
            }
            events.append(["kind": "completed", "status": 0])
            return HostResult(status: 0, events: events)
        }
        if options.contains("--deployment"),
            resolved.specs.contains(where: { lock.versions[$0.key] != $0.value.version.description })
        {
            throw Diagnostic(
                "SP-DEPLOYMENT-LOCK", stage: "resolve", "Resolved versions differ from Podfile.lock")
        }
        if options.contains("--deployment"),
            resolved.specs.contains(where: { entry in
                guard let checksum = entry.value.checksum else { return false }
                guard let locked = lock.specChecksums[entry.key] else { return true }
                return locked != checksum && !(catalog.checksumAliases[checksum] ?? []).contains(locked)
            })
        {
            throw Diagnostic(
                "SP-DEPLOYMENT-SPEC", stage: "resolve", "Podspec checksums differ from Podfile.lock")
        }
        if hardened {
            for spec in resolved.specs.values where spec.containsExecutableCommands {
                throw Diagnostic(
                    "SP-HARDENED-SCRIPT", stage: "policy", "Executable podspec commands are forbidden",
                    file: spec.name)
            }
        }
        // Validate build commands before installing sources or running
        // prepare hooks, so malformed phases leave no managed changes.
        for target in targets { _ = try NativeScriptPhase.parse(target["script_phases"]) }
        for request in resolved.requests {
            if let spec = resolved.specs[request.root] { _ = try spec.scriptPhases(for: request) }
        }
        try FileManager.default.createDirectory(
            at: project.appendingPathComponent("Pods"), withIntermediateDirectories: true)
        var installed: [String: NativeSpec] = [:]
        catalog.selectedRequests = resolved.requests
        try catalog.prefetch(resolved.specs)
        for (name, spec) in resolved.specs.sorted(by: { $0.key < $1.key }) {
            installed[name] = try catalog.install(spec)
            let path = project.appendingPathComponent("Pods/Local Podspecs/" + name + ".podspec.json")
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            let serialized =
                try spec.checksum.flatMap { catalog.serializedSpecifications[$0] } ?? jsonData(spec.data)
            try serialized.writeIfChanged(to: path, options: .atomic)
        }
        let resolution = NativeResolution(specs: installed, requests: resolved.requests)
        try catalog.finalize(installed, requests: resolved.requests)
        let installationOptions = manifest["options"] as? [String: Any] ?? [:]
        let skipGeneration = installationOptions["skip_pods_project_generation"] as? Bool == true
        let xcode: NativeXcode? = try NativeXcode(
            project: project, manifest: manifest, resolution: resolution,
            integrateUserProjects: !options.contains("--no-integrate")
                && installationOptions["integrate_targets"] as? Bool != false)
        let hookVariants =
            try xcode?.variantPlan ?? NativeVariantPlan(manifest: manifest, resolution: resolution)
        let hooks = NativeHookRunner(
            dsl: dsl, projectAccess: projectAccess, xcode: xcode, project: project,
            manifest: manifest, installed: installed, requests: resolved.requests,
            variants: hookVariants,
            integrateUserProjects: !options.contains("--no-integrate")
                && installationOptions["integrate_targets"] as? Bool != false,
            record: { self.events.append($0) })
        try hooks.run("pre_install")
        if !skipGeneration && !options.contains("--no-integrate") { try hooks.run("pre_integrate") }
        if !skipGeneration, let xcode { try xcode.generate() }
        if !skipGeneration, let xcode, xcode.multipleProjects { try xcode.prepareMultipleProjects() }
        try hooks.run("post_install")
        if !skipGeneration, let xcode {
            writeEvent(try xcode.savePods())
            if !options.contains("--no-integrate") && installationOptions["integrate_targets"] as? Bool != false {
                for path in try xcode.integrate() { writeEvent(path) }
            }
        }
        if let xcode { events += xcode.configurationWarnings }
        if !skipGeneration && !options.contains("--no-integrate")
            && installationOptions["integrate_targets"] as? Bool != false
        {
            try hooks.run("post_integrate")
        }
        if !skipGeneration, let xcode { writeEvent(try xcode.savePods()) }
        let referenceVersion =
            ((bundle.manifest["behavior_reference"] as? [String: [String: String]])?["cocoapods"])?["version"]
            ?? "unknown"
        try lock.verifyUnchanged()
        let text =
            try options.contains("--deployment")
            ? String(contentsOf: lockURL, encoding: .utf8)
            : NativeLock.make(
                resolution, direct: direct, checksum: checksum, referenceVersion: referenceVersion,
                manifestChecksum: manifestChecksum, previous: lock.raw)
        try Data(text.utf8).writeIfChanged(to: lockURL, options: .atomic)
        try Data(text.utf8).writeIfChanged(
            to: project.appendingPathComponent("Pods/Manifest.lock"), options: .atomic)
        try hooks.run("post_install", plugin: true)
        if !skipGeneration, let xcode { writeEvent(try xcode.savePods()) }
        let specs = resolution.requests.map { request -> [String: Any] in
            let spec = installed[request.root]!
            return [
                "name": request.name, "version": spec.version.description, "module_name": spec.moduleName,
                "dependencies": ((try? spec.dependencies(for: request)) ?? []).map {
                    ["name": $0.name, "requirement": $0.requirements.joined(separator: ", ")]
                },
                "source": spec.checkout.isEmpty ? (spec.data["source"] ?? [:]) : spec.checkout,
                "spec_repository": spec.repository, "local": spec.local, "root": spec.directory!.path,
            ]
        }
        var inputs =
            try dsl?.object("inputs") ?? [
                "files": [manifestPath.path: digest(try Data(contentsOf: manifestPath))]
            ]
        if var environmentInputs = inputs["environment"] as? [String: Any] {
            for key in environmentInputs.keys
            where key.hasPrefix("SWIFTPODS_") || key.hasPrefix("GEM_") || key.hasPrefix("BUNDLE_")
                || key == "PWD" || key == "SHLVL" || key == "_"
            { environmentInputs.removeValue(forKey: key) }
            inputs["environment"] = environmentInputs
        }
        events.append([
            "kind": "installation", "engine": "swift", "input_manifest": manifestPath.path, "specs": specs,
            "targets": targets.map { target -> [String: Any] in
                [
                    "name": target["name"] ?? "", "platform": target["platform"] ?? [:],
                    "dependencies": (target["dependencies"] as? [[String: Any]] ?? []).map {
                        [
                            "name": $0["name"] ?? "",
                            "requirement": nativeStrings($0["requirements"]).joined(separator: ", "),
                        ]
                    },
                ]
            }, "inputs": inputs, "plugins": manifest["plugins"] ?? [:],
        ])
        if !machine && !silent { print("Installed \(installed.count) dependencies with SwiftPods.") }
        return nil
    }
}
