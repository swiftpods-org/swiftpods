import Foundation

extension NativeCommandSession {
    /// Evaluates, resolves and installs one command while preserving hook ordering.
    func install(_ request: NativeCommandRequest) throws -> HostResult? {
        let action = request.action
        let args = request.arguments
        let project = request.project
        func writeEvent(_ url: URL) { recordWrite(url) }
        var allowed = Set([
            "--deployment", "--repo-update", "--no-repo-update", "--clean-install", "--verbose", "--silent",
            "--no-ansi", "--ansi",
            "--no-integrate",
        ])
        if action == "outdated" { allowed.insert("--ignore-prerelease") }
        let options = args.filter { CommandOptions.hasOptionPrefix($0) }
        guard options.allSatisfy(allowed.contains),
            action == "update" || args.allSatisfy({ CommandOptions.hasOptionPrefix($0) })
        else {
            throw Diagnostic(
                "SP-CLI-ARGUMENT", stage: "cli",
                "Unsupported native engine option: \(args.joined(separator: " "))")
        }
        guard !(options.contains("--repo-update") && options.contains("--no-repo-update")) else {
            throw Diagnostic("SP-CLI-ARGUMENT", stage: "cli", "Choose --repo-update or --no-repo-update")
        }
        let hardened = environment["SWIFTPODS_HARDENED_MANIFEST"] != nil
        let dsl: NativeDSL? =
            hardened
            ? nil
            : try NativeDSL(
                bundle: bundle, environment: environment, directory: project, overrides: overrides,
                sdkContext: sdkContext)
        let manifestPath =
            hardened
            ? project.appendingPathComponent("Podfile.json")
            : NativePodfilePath.find(in: project) ?? project.appendingPathComponent("Podfile")
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
        let projectDeclarations = manifest
        manifest = try NativeManifest.analyze(
            manifest, project: project,
            integrate: !options.contains("--no-integrate")
                && declaredOptions["integrate_targets"] as? Bool != false, sdkContext: sdkContext)
        let projectBindings = NativeIntegrationLocation.projectBindings(
            projectDeclarations, analyzed: manifest, root: project)
        if let dsl { manifest = try dsl.object("analyzed_podfile", ["targets": manifest["targets"] ?? []]) }
        // Generated labels belong to the build graph, not the user's locked declarations.
        let declarations = manifest
        manifest = try NativeConsumerLabels.normalized(manifest, project: project)
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
        let contractManifest = NativeIntegrationLocation.contractManifest(
            declarations, bindings: projectBindings, root: project)
        let manifestChecksum = digest(try jsonData(contractManifest))
        var acceptedLegacyChecksum: String?
        if options.contains("--deployment"), let previous = lock.manifestChecksum, previous != manifestChecksum {
            let receipt = project.appendingPathComponent("Pods/Target Support Files/SwiftPods-Integration.json")
            let ownership = FileManager.default.fileExists(atPath: receipt.path) ? try readObject(receipt) : [:]
            let recorded = (ownership["_manifest_checksum_aliases"] as? [String: String])?[previous] == manifestChecksum
            guard
                try recorded
                    || NativeManifest.legacyProjectChecksums(
                        contractManifest, project: project, ownership: ownership
                    ).contains(previous)
            else {
                throw Diagnostic(
                    "SP-DEPLOYMENT-LOCK", stage: "resolve",
                    "Evaluated Podfile declarations differ from Podfile.lock")
            }
            acceptedLegacyChecksum = previous
        }
        if options.contains("--deployment"), lock.checksum != checksum {
            throw Diagnostic(
                "SP-DEPLOYMENT-LOCK", stage: "resolve",
                "Podfile differs from Podfile.lock or lockfile is missing")
        }
        let cache = URL(fileURLWithPath: bundle.cacheRootPath(from: environment))
        let declaredSources = nativeStrings(manifest["sources"])
        let defaults = try NativeRepositories(cache: cache).records().compactMap { $0["url"] as? String }
        func makeCatalog(refresh: Bool) throws -> NativeSources {
            try NativeSources(
                project: project, cache: cache,
                sources: declaredSources.isEmpty ? defaults + ["https://cdn.cocoapods.org/"] : declaredSources,
                dsl: dsl, offline: environment["SWIFTPODS_OFFLINE"] == "1",
                refreshRepositories: refresh, hardened: hardened)
        }
        let catalog = try makeCatalog(
            refresh: options.contains("--repo-update") || (action != "install" && !options.contains("--no-repo-update")))
        let requestedUpdates = Set(
            args.filter { !CommandOptions.hasOptionPrefix($0) }.map { NativePodName.root($0) })
        if action == "update",
            let unknown = requestedUpdates.subtracting(Set(lock.versions.keys).union(direct.map(\.root)))
                .sorted().first
        {
            throw Diagnostic(
                "SP-UPDATE-MISSING", stage: "resolve", "Requested pod is not declared or installed",
                file: unknown)
        }
        let changedRoots = try lock.changedRoots(direct)
        let selectedUpdates = requestedUpdates.union(changedRoots)
        var dependencyGraph = lock.dependencies
        if !selectedUpdates.isEmpty && !lock.versions.isEmpty {
            let pinned = try makeCatalog(refresh: false)
            pinned.pinnedCheckouts = lock.checkoutOptions
            pinned.lockedRepositories = lock.repositories
            pinned.installationOptions = declaredOptions
            let external = try lock.externalSources.sorted(by: { $0.key < $1.key }).map { name, options in
                var dependency = try NativeDependency(["name": name])
                dependency.options = options
                for key in ["submodules", "flatten"] {
                    if let value = options[key] as? String, ["true", "false"].contains(value) {
                        dependency.options[key] = value == "true"
                    }
                }
                return dependency
            }
            try pinned.register(external)
            dependencyGraph = try lock.recoveredDependencies(direct) { request, version in
                do {
                    var previous = request
                    previous.options = [:]
                    let version = try PodVersion(version)
                    guard let candidate = try pinned.candidates(previous).first(where: { $0.version == version })
                    else { return nil }
                    return try pinned.materialize(candidate)
                } catch {
                    // An old source may have disappeared. The update still resolves
                    // against its current sources and enforces their own integrity.
                    try NativeCancellation.check()
                    return nil
                }
            }
        }
        let updateRoots = lock.unlocked(selectedUpdates, dependencies: dependencyGraph)
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
            let changes = try NativeOutdated.pods(
                lock: lock, resolution: resolved, catalog: catalog,
                ignorePrerelease: options.contains("--ignore-prerelease"))
            events.append(["kind": "outdated", "pods": changes])
            if !machine && !silent {
                if changes.isEmpty { print("All dependencies are up to date.") }
                for change in changes {
                    let latest = change["latest"] == change["available"] ? "" : " (latest version \(change["latest"]!))"
                    print("\(change["name"]!): \(change["installed"]!) -> \(change["available"]!)" + latest)
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
                && installationOptions["integrate_targets"] as? Bool != false,
            projectBindings: projectBindings, packageEnvironment: environment.merging(overrides) { _, new in new },
            updateSwiftPackages: action == "update" && args.allSatisfy { CommandOptions.hasOptionPrefix($0) },
            cleanSwiftPackages: options.contains("--clean-install"), recordPackageWrite: writeEvent)
        if let previous = acceptedLegacyChecksum, let xcode {
            var aliases = xcode.integrationSettings["_manifest_checksum_aliases"] as? [String: String] ?? [:]
            aliases[previous] = manifestChecksum
            xcode.integrationSettings["_manifest_checksum_aliases"] = aliases
        }
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
            : lock.preservingFormatting(
                NativeLock.make(
                    resolution, direct: direct, checksum: checksum, referenceVersion: referenceVersion,
                    manifestChecksum: manifestChecksum, previous: lock.raw))
        try Data(text.utf8).writeIfChanged(to: lockURL, options: .atomic)
        try Data(text.utf8).writeIfChanged(
            to: project.appendingPathComponent("Pods/Manifest.lock"), options: .atomic)
        try hooks.run("post_install", plugin: true)
        if !skipGeneration, let xcode { writeEvent(try xcode.savePods()) }
        let specs = resolution.requests.map { request -> [String: Any] in
            let spec = installed[request.root]!
            return [
                "name": request.name, "version": spec.version.description, "module_name": spec.moduleName,
                "platform": ["name": request.platform, "deployment_target": request.deployment],
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
            "targets": try targets.map { target -> [String: Any] in
                [
                    "name": target["name"] ?? "", "platform": target["platform"] ?? [:],
                    "dependencies": try
                        ((target["dependencies"] as? [[String: Any]] ?? [])
                        + (target["search_dependencies"] as? [[String: Any]] ?? [])).flatMap {
                            try NativeDependency($0).expandedSelections()
                        }.map {
                            [
                                "name": $0.name,
                                "requirement": $0.requirements.joined(separator: ", "),
                            ]
                        },
                ]
            }, "inputs": inputs, "plugins": manifest["plugins"] ?? [:],
        ])
        if !machine && !silent { print("Installed \(installed.count) dependencies with SwiftPods.") }
        return nil
    }
}
