import Foundation
import CryptoKit
import ProcessSupport

public struct HostResult {
    public let status: Int32
    public let events: [[String: Any]]
}

struct NativeLock {
    let path: URL
    let originalFingerprint: String
    let raw: [String: Any]
    let versions: [String: String]
    let checksum: String?
    let specChecksums: [String: String]
    let manifestChecksum: String?
    let checkoutOptions: [String: [String: String]]
    let externalSources: [String: [String: Any]]
    let repositories: [String: String]
    let declarations: [String: [String]]
    let dependencies: [String: Set<String>]
    let lockingDependencies: [String: Set<String>]
    init(_ path: URL) throws {
        self.path = path
        originalFingerprint = try FileFingerprint.tree(path)
        let data = FileManager.default.fileExists(atPath: path.path) ? try NativeYAML.object(String(contentsOf: path, encoding: .utf8), file: path.path) : [:]
        guard try FileFingerprint.tree(path) == originalFingerprint else { throw Diagnostic("SP-LOCK-CONFLICT", stage: "resolve", "Lockfile changed while reading", file: path.path) }
        raw = data
        func strings(_ value: Any?) -> [String: String] {
            (value as? [String: Any] ?? [:]).reduce(into: [:]) { result, entry in
                if let value = entry.value as? String { result[entry.key] = value }
                else if let value = entry.value as? NSNumber { result[entry.key] = CFGetTypeID(value) == CFBooleanGetTypeID() ? (value.boolValue ? "true" : "false") : value.stringValue }
            }
        }
        func sourceMap(_ value: Any?) -> [String: [String: String]] {
            (value as? [String: Any] ?? [:]).mapValues { value in Dictionary(uniqueKeysWithValues: strings(value).map { (String($0.key.drop(while: { $0 == ":" })), $0.value) }) }
        }
        func declaration(_ value: String) -> (String, [String]) {
            guard let open = value.range(of: " ("), value.hasSuffix(")") else { return (value, [">= 0"]) }
            let requirement = String(value[open.upperBound..<value.index(before: value.endIndex)])
            return (String(value[..<open.lowerBound]), requirement.hasPrefix("from ") ? [">= 0"] : requirement.components(separatedBy: ", "))
        }
        var pins: [String: String] = [:], edges: [String: Set<String>] = [:], lockingEdges: [String: Set<String>] = [:]
        var lockingStrings = Set<String>()
        func pod(_ value: Any) throws {
            let name: String, children: [Any]
            if let value = value as? String { name = value; children = [] }
            else if let value = value as? [String: Any], value.count == 1, let entry = value.first, let values = entry.value as? [Any] { name = entry.key; children = values }
            else { throw Diagnostic("SP-LOCK-SCHEMA", stage: "resolve", "Invalid PODS entry", file: path.path) }
            let (full, requirements) = declaration(name), root = String(full.split(separator: "/").first ?? "")
            guard requirements.count == 1, let version = requirements.first, (try? PodVersion(version)) != nil else { throw Diagnostic("SP-LOCK-SCHEMA", stage: "resolve", "Invalid locked version", file: path.path) }
            if let previous = pins[root], try PodVersion(previous) != PodVersion(version) { throw Diagnostic("SP-LOCK-SCHEMA", stage: "resolve", "Multiple locked versions of " + root, file: path.path) }
            pins[root] = version
            lockingStrings.insert(name)
            for child in children {
                guard let text = child as? String else { throw Diagnostic("SP-LOCK-SCHEMA", stage: "resolve", "Invalid locked dependency", file: path.path) }
                let childRoot = String(declaration(text).0.split(separator: "/").first ?? "")
                edges[root, default: []].insert(childRoot)
                // The selected baseline deduplicates dependency strings before
                // attaching lock-graph edges. Keep the full graph separately.
                if lockingStrings.insert(text).inserted { lockingEdges[root, default: []].insert(childRoot) }
            }
        }
        if let pods = data["PODS"], !(pods is NSNull) {
            guard let pods = pods as? [Any] else { throw Diagnostic("SP-LOCK-SCHEMA", stage: "resolve", "PODS must be a sequence", file: path.path) }
            for entry in pods { try pod(entry) }
        }
        var sources: [String: String] = [:]
        for (source, names) in data["SPEC REPOS"] as? [String: Any] ?? [:] {
            for name in nativeStrings(names) {
                if let previous = sources[name], previous != source { throw Diagnostic("SP-LOCK-SOURCE", stage: "resolve", "Multiple locked spec repositories for " + name, file: path.path) }
                sources[name] = source
            }
        }
        var direct: [String: [String]] = [:]
        for value in nativeStrings(data["DEPENDENCIES"]) { let (name, requirements) = declaration(value); direct[name, default: []] += requirements }
        versions = pins; dependencies = edges; lockingDependencies = lockingEdges; repositories = sources; declarations = direct
        checksum = data["PODFILE CHECKSUM"] as? String; manifestChecksum = data["SWIFTPODS MANIFEST CHECKSUM"] as? String
        specChecksums = strings(data["SPEC CHECKSUMS"]); checkoutOptions = sourceMap(data["CHECKOUT OPTIONS"]); externalSources = (data["EXTERNAL SOURCES"] as? [String: [String: Any]] ?? [:]).mapValues { Dictionary(uniqueKeysWithValues: $0.map { (String($0.key.drop(while: { $0 == ":" })), $0.value) }) }
    }
    func verifyUnchanged() throws {
        guard try FileFingerprint.tree(path) == originalFingerprint else { throw Diagnostic("SP-LOCK-CONFLICT", stage: "install", "Lockfile changed during installation; the external edit is preserved", file: path.path, state: "recovery_required") }
    }
    func changedRoots(_ direct: [NativeDependency]) throws -> Set<String> {
        guard !declarations.isEmpty else { return [] }
        let current = Dictionary(grouping: direct, by: \.name)
        var changed = Set<String>()
        // The baseline compares existing declarations against their installed
        // versions. Compatible edits and newly added declarations keep pins.
        for name in declarations.keys {
            let root = String(name.split(separator: "/").first ?? "")
            guard let request = current[name]?.first, let version = versions[root] else { changed.insert(root); continue }
            if !(try PodRequirement(request.requirements).accepts(PodVersion(version))) { changed.insert(root) }
        }
        for request in direct where declarations[request.name] != nil {
            let source = request.options.filter { ["path", "git", "podspec", "http", "svn", "hg", "branch", "tag", "commit", "revision", "folder", "submodules", "flatten", "type", "sha256", "sha1", "headers"].contains($0.key) }
            func normalize(_ value: Any) -> Any {
                if let dictionary = value as? [String: Any] { return dictionary.mapValues(normalize) }
                if let values = value as? [Any] { return values.map(normalize) }
                return String(describing: value)
            }
            if try jsonData(normalize(source)) != jsonData(normalize(externalSources[request.root] ?? [:])) { changed.insert(request.root) }
        }
        return changed.intersection(Set(versions.keys))
    }
    func unlocked(_ roots: Set<String>) -> Set<String> {
        var result = roots, queue = Array(roots)
        let explicit = Set(declarations.keys.map { String($0.split(separator: "/").first ?? "") })
        var parents: [String: Set<String>] = [:]
        for (parent, children) in lockingDependencies {
            for child in children where child != parent { parents[child, default: []].insert(parent) }
        }
        while let root = queue.popLast() {
            for child in lockingDependencies[root] ?? [] where !result.contains(child) && !explicit.contains(child) {
                if (parents[child] ?? []).isSubset(of: result), result.insert(child).inserted { queue.append(child) }
            }
        }
        return result
    }
    static func sha1(_ data: Data) -> String { Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "''") + "'" }
    static func make(_ resolution: NativeResolution, direct: [NativeDependency], checksum: String, referenceVersion: String, manifestChecksum: String, previous: [String: Any] = [:]) throws -> String {
        var text = "PODS:\n"
        var names = Set<String>()
        for request in resolution.requests.sorted(by: { $0.name < $1.name }) where names.insert(request.name).inserted {
            let spec = resolution.specs[request.root]!
            let dependencies = try spec.dependencies(for: request)
            let value = quote(request.name + " (" + spec.version.description + ")")
            if dependencies.isEmpty { text += "  - " + value + "\n" }
            else {
                text += "  - " + value + ":\n"
                for dependency in dependencies.sorted(by: { $0.name < $1.name }) { text += "    - " + quote(dependency.name + " (" + dependency.requirements.joined(separator: ", ") + ")") + "\n" }
            }
        }
        text += "\nDEPENDENCIES:\n"
        var declarations = Set<String>()
        for request in direct.sorted(by: { $0.name < $1.name }) where declarations.insert(request.name + request.requirements.joined(separator: ",")).inserted {
            let requirement = request.options["path"].map { "from `\($0)`" } ?? request.requirements.joined(separator: ", ")
            text += "  - " + quote(request.name + " (" + requirement + ")") + "\n"
        }
        let external = direct.filter { dependency in ["path", "git", "podspec", "http", "svn", "hg"].contains(where: { dependency.options[$0] != nil }) }
        if !external.isEmpty {
            text += "\nEXTERNAL SOURCES:\n"
            var externalRoots = Set<String>()
            for request in external.sorted(by: { $0.root < $1.root }) where externalRoots.insert(request.root).inserted {
                text += "  " + quote(request.root) + ":\n"
                for (key, value) in request.options.sorted(by: { $0.key < $1.key }) where ["path", "git", "http", "svn", "hg", "tag", "branch", "commit", "revision", "folder", "submodules", "sha256", "sha1", "flatten", "type", "podspec", "headers"].contains(key) {
                    if value is [String: Any] || value is [Any] { text += try NativeYAML.encode([":" + key: value], indent: 4) }
                    else { text += "    " + quote(":" + key) + ": " + quote(String(describing: value)) + "\n" }
                }
            }
        }
        let repositories = Dictionary(grouping: resolution.specs.values.filter { !$0.repository.isEmpty }, by: \.repository)
        if !repositories.isEmpty {
            text += "\nSPEC REPOS:\n"
            for (repository, specs) in repositories.sorted(by: { $0.key < $1.key }) {
                text += "  " + quote(repository) + ":\n"
                for spec in specs.sorted(by: { $0.name < $1.name }) { text += "    - " + quote(spec.name) + "\n" }
            }
        }
        let checkouts = resolution.specs.values.filter { !$0.checkout.isEmpty }
        if !checkouts.isEmpty {
            text += "\nCHECKOUT OPTIONS:\n"
            for spec in checkouts.sorted(by: { $0.name < $1.name }) {
                text += "  " + quote(spec.name) + ":\n"
                for (key, value) in spec.checkout.sorted(by: { $0.key < $1.key }) { text += "    " + quote(":" + key) + ": " + quote(value) + "\n" }
            }
        }
        text += "\nSPEC CHECKSUMS:\n"
        for (name, spec) in resolution.specs.sorted(by: { $0.key < $1.key }) { text += "  " + quote(name) + ": " + quote(try spec.checksum ?? sha1(jsonData(spec.data))) + "\n" }
        text += "\nPODFILE CHECKSUM: " + checksum + "\n\nCOCOAPODS: " + referenceVersion + "\n\nSWIFTPODS: " + CLI.version + "\n\nSWIFTPODS MANIFEST CHECKSUM: " + manifestChecksum + "\n"
        let owned: Set<String> = ["PODS", "DEPENDENCIES", "EXTERNAL SOURCES", "SPEC REPOS", "CHECKOUT OPTIONS", "SPEC CHECKSUMS", "PODFILE CHECKSUM", "COCOAPODS", "SWIFTPODS", "SWIFTPODS MANIFEST CHECKSUM"]
        let extensions = previous.filter { !owned.contains($0.key) }
        if !extensions.isEmpty { text += "\n" + (try NativeYAML.encode(extensions)) }
        return text
    }
}

struct NativeEngine {
    let bundle: RuntimeBundle
    func run(arguments: [String], environment: [String: String], machine: Bool, overrides: [String: String] = [:]) -> HostResult {
        let silent = arguments.contains("--silent"), verbose = arguments.contains("--verbose")
        var events: [[String: Any]] = [["kind": "started", "producer": "SwiftPods", "engine": "swift", "command": arguments.first ?? "install"]]
        func writeEvent(_ url: URL) { events.append(["kind": "managed_write", "path": url.path]) }
        do {
            var args = arguments
            let action = args.removeFirst()
            let path = try CommandOptions.take("--project-directory", from: &args)
            let project = URL(fileURLWithPath: path ?? FileManager.default.currentDirectoryPath).standardizedFileURL.resolvingSymlinksInPath()
            if ["lib", "spec"].contains(action), args.first == "lint" {
                let value = try NativeValidation(bundle: bundle, environment: environment, overrides: overrides).run(action: action, arguments: Array(args.dropFirst()), project: project)
                events.append(["kind": "validation", "data": value])
                if value["status"] as? String != "passed" {
                    let errors = value["errors"] as? [[String: Any]] ?? []
                    throw Diagnostic(errors.first?["code"] as? String ?? "SP-LINT-FAILED", stage: "lint", errors.compactMap { $0["message"] as? String }.joined(separator: "\n"), file: errors.first?["file"] as? String)
                }
                if !machine && !silent { print("Validation passed.") }
            } else if action == "repo", args.first == "push" {
                let value = try NativePublication.push(arguments: Array(args.dropFirst()), project: project, bundle: bundle, environment: environment, overrides: overrides)
                events.append(["kind": "publication", "data": value])
                if !machine && !silent { print("Published \(value["name"] ?? "") \(value["version"] ?? "").") }
            } else if ["ipc", "spec"].contains(action) {
                let value = try NativeInspection.run(action: action, arguments: args, project: project, bundle: bundle, environment: environment, overrides: overrides)
                events.append(["kind": "inspection", "data": value])
                if !machine {
                    if let paths = value as? [String] { for path in paths { print(path) } }
                    else { print(String(decoding: try jsonData(value), as: UTF8.self)) }
                }
            } else if action == "deintegrate" {
                guard args.isEmpty else { throw Diagnostic("SP-CLI-ARGUMENT", stage: "cli", "Unknown deintegrate option") }
                for path in try NativeDeintegrator.run(project) { writeEvent(path) }
                events.append(["kind": "deintegrated"])
            } else if action == "init" {
                guard args.isEmpty else { throw Diagnostic("SP-CLI-ARGUMENT", stage: "cli", "Unknown init option") }
                let podfile = project.appendingPathComponent("Podfile")
                guard !FileManager.default.fileExists(atPath: podfile.path) else { throw Diagnostic("SP-INIT-EXISTS", stage: "init", "Podfile already exists") }
                let projects = try FileManager.default.contentsOfDirectory(at: project, includingPropertiesForKeys: nil).filter { $0.pathExtension == "xcodeproj" }
                guard projects.count == 1 else { throw Diagnostic("SP-XCODE-AMBIGUOUS", stage: "init", "Exactly one Xcode project is required") }
                let pbx = try NativePBX(projects[0].appendingPathComponent("project.pbxproj"), existing: true)
                let targets = pbx.objects.values.filter { $0["isa"] as? String == "PBXNativeTarget" }.compactMap { $0["name"] as? String }.sorted()
                let analyzed = try NativeManifest.analyze(["targets": targets.map { ["name": $0, "project": projects[0].lastPathComponent] }], project: project, integrate: true)
                let content = "project " + NativeLock.quote(projects[0].lastPathComponent) + "\n\n" + (analyzed["targets"] as? [[String: Any]] ?? []).map { target in
                    let platform = target["platform"] as! [String: String]
                    return "target " + NativeLock.quote(target["name"] as! String) + " do\n  platform :" + platform["name"]! + ", " + NativeLock.quote(platform["deployment_target"]!) + "\nend\n"
                }.joined(separator: "\n")
                try Data(content.utf8).writeIfChanged(to: podfile, options: .atomic); writeEvent(podfile)
            } else if ["install", "update", "outdated"].contains(action) {
                let allowed = Set(["--deployment", "--repo-update", "--clean-install", "--verbose", "--silent", "--no-ansi", "--ansi", "--no-integrate"])
                let options = args.filter { $0.hasPrefix("-") }
                guard options.allSatisfy(allowed.contains), action == "update" || args.allSatisfy({ $0.hasPrefix("-") }) else { throw Diagnostic("SP-CLI-ARGUMENT", stage: "cli", "Unsupported native engine option: \(args.joined(separator: " "))") }
                let hardened = environment["SWIFTPODS_HARDENED_MANIFEST"] != nil
                let dsl: NativeDSL? = hardened ? nil : try NativeDSL(bundle: bundle, environment: environment, directory: project, overrides: overrides)
                let manifestPath = project.appendingPathComponent(hardened ? "Podfile.json" : "Podfile")
                let projectAccess = NativeProjectAccess(root: project)
                dsl?.callback = { request in
                    let result = try projectAccess.callback(request, writable: true)
                    if request["callback"] as? String == "save_project", let path = (request["value"] as? [String: Any])?["path"] as? String { writeEvent(URL(fileURLWithPath: path).appendingPathComponent("project.pbxproj")) }
                    return result
                }
                var manifest: [String: Any]
                if hardened {
                    let input = try ExecutionPolicy.hardenedManifest(manifestPath)
                    let platform = input["platform"] as! [String: String]
                    manifest = input
                    manifest["targets"] = (input["targets"] as! [[String: Any]]).map { target -> [String: Any] in
                        var value = target; value["platform"] = platform; value["project"] = input["project"]; value["frameworks"] = input["frameworks"]
                        value["dependencies"] = (target["pods"] as! [[String: Any]]).map { pod -> [String: Any] in
                            ["name": pod["name"]!, "requirements": pod["versions"] ?? [">= 0"], "options": pod.filter { !["name", "versions"].contains($0.key) }]
                        }
                        return value
                    }
                } else {
                    _ = try dsl!.object("podfile", ["path": manifestPath.path])
                    manifest = try dsl!.object("plugins_prepare")
                }
                let declaredOptions = manifest["options"] as? [String: Any] ?? [:]
                try NativeInstallationOptions.validate(declaredOptions)
                manifest = try NativeManifest.analyze(manifest, project: project, integrate: !options.contains("--no-integrate") && declaredOptions["integrate_targets"] as? Bool != false)
                if let dsl { manifest = try dsl.object("analyzed_podfile", ["targets": manifest["targets"] ?? []]) }
                guard let targets = manifest["targets"] as? [[String: Any]], !targets.isEmpty else { throw Diagnostic("SP-DSL-TARGET", stage: "resolve", "Podfile needs at least one concrete target") }
                for target in targets where !options.contains("--no-integrate") && declaredOptions["integrate_targets"] as? Bool != false {
                    if let raw = target["project"] as? String {
                        let path = URL(fileURLWithPath: raw, relativeTo: project).standardizedFileURL
                        try ProjectState(directory: project).registerProject(path.appendingPathComponent("project.pbxproj"))
                    }
                }
                let direct = try targets.flatMap { target -> [NativeDependency] in
                    let platform = target["platform"] as? [String: String] ?? [:]
                    return try ((target["dependencies"] as? [[String: Any]] ?? []) + (target["search_dependencies"] as? [[String: Any]] ?? [])).flatMap { try NativeDependency($0, platform: platform["name"] ?? "ios", deployment: platform["deployment_target"] ?? "0").expandedSelections() }
                }
                let lockURL = project.appendingPathComponent("Podfile.lock")
                let lock = try NativeLock(lockURL), checksum = NativeLock.sha1(try Data(contentsOf: manifestPath))
                var contractManifest = manifest
                contractManifest["targets"] = (manifest["targets"] as? [[String: Any]] ?? []).map { $0.filter { $0.key != "_id" } }
                let manifestChecksum = digest(try jsonData(contractManifest))
                if options.contains("--deployment"), let previous = lock.manifestChecksum, previous != manifestChecksum { throw Diagnostic("SP-DEPLOYMENT-LOCK", stage: "resolve", "Evaluated Podfile declarations differ from Podfile.lock") }
                if options.contains("--deployment"), lock.checksum != checksum { throw Diagnostic("SP-DEPLOYMENT-LOCK", stage: "resolve", "Podfile differs from Podfile.lock or lockfile is missing") }
                let cache = URL(fileURLWithPath: bundle.environment(from: environment)["SWIFTPODS_CACHE_ROOT"]!)
                let declaredSources = nativeStrings(manifest["sources"])
                let defaults = try NativeRepositories(cache: cache).records().compactMap { $0["url"] as? String }
                let catalog = try NativeSources(project: project, cache: cache, sources: declaredSources.isEmpty ? defaults + ["https://cdn.cocoapods.org/"] : declaredSources, dsl: dsl, offline: environment["SWIFTPODS_OFFLINE"] == "1", refresh: options.contains("--repo-update"), hardened: hardened)
                let requestedUpdates = Set(args.filter { !$0.hasPrefix("-") }.map { String($0.split(separator: "/").first ?? "") })
                if action == "update", let unknown = requestedUpdates.subtracting(Set(lock.versions.keys).union(direct.map(\.root))).sorted().first { throw Diagnostic("SP-UPDATE-MISSING", stage: "resolve", "Requested pod is not declared or installed", file: unknown) }
                let changedRoots = try lock.changedRoots(direct)
                let updateRoots = lock.unlocked(requestedUpdates.union(changedRoots))
                catalog.pinnedCheckouts = lock.checkoutOptions.filter { !changedRoots.contains($0.key) }
                catalog.updating = action == "update" || !changedRoots.isEmpty
                catalog.updateRoots = action == "update" && requestedUpdates.isEmpty ? [] : updateRoots
                catalog.installationOptions = declaredOptions
                catalog.cleanInstall = options.contains("--clean-install")
                try catalog.register(direct)
                let update = updateRoots
                catalog.lockedRepositories = action == "outdated" || (action == "update" && requestedUpdates.isEmpty) ? [:] : lock.repositories.filter { !update.contains($0.key) }
                var unlockedLocal = Set<String>()
                for request in direct where request.options["path"] != nil && lock.versions[request.root] != nil {
                    if let local = try catalog.candidates(request).first, local.checksum != lock.specChecksums[request.root] { unlockedLocal.insert(request.root) }
                }
                let pins = action == "outdated" || (action == "update" && requestedUpdates.isEmpty) ? [:] : lock.versions
                let resolver = NativeResolver(candidates: catalog.candidates, materialize: catalog.materialize, locked: pins, update: update.union(unlockedLocal))
                let resolved = try resolver.resolve(direct)
                for warning in catalog.sourceWarnings { events.append(warning.merging(["kind": "warning"]) { _, new in new }) }
                if declaredOptions["warn_for_unused_master_specs_repo"] as? Bool != false, !declaredSources.contains("https://github.com/CocoaPods/Specs.git"), try NativeRepositories(cache: cache).records().contains(where: { $0["url"] as? String == "https://github.com/CocoaPods/Specs.git" }) {
                    events.append(["kind": "warning", "code": "SP-SOURCE-UNUSED", "message": "A registered master Git specs repository is not explicitly used by this Podfile"])
                }
                if action == "outdated" {
                    let changes = resolved.specs.values.filter { lock.versions[$0.name] != $0.version.description }.sorted { $0.name < $1.name }.map { ["name": $0.name, "installed": lock.versions[$0.name] ?? "absent", "available": $0.version.description] }
                    events.append(["kind": "outdated", "pods": changes])
                    if !machine && !silent {
                        if changes.isEmpty { print("All dependencies are up to date.") }
                        for change in changes { print("\(change["name"]!): \(change["installed"]!) -> \(change["available"]!)") }
                    }
                    events.append(["kind": "completed", "status": 0]); return HostResult(status: 0, events: events)
                }
                if options.contains("--deployment"), resolved.specs.contains(where: { lock.versions[$0.key] != $0.value.version.description }) { throw Diagnostic("SP-DEPLOYMENT-LOCK", stage: "resolve", "Resolved versions differ from Podfile.lock") }
                if options.contains("--deployment"), resolved.specs.contains(where: { entry in
                    guard let checksum = entry.value.checksum else { return false }
                    guard let locked = lock.specChecksums[entry.key] else { return true }
                    return locked != checksum && !(catalog.checksumAliases[checksum] ?? []).contains(locked)
                }) { throw Diagnostic("SP-DEPLOYMENT-SPEC", stage: "resolve", "Podspec checksums differ from Podfile.lock") }
                if hardened {
                    for spec in resolved.specs.values where spec.containsExecutableCommands { throw Diagnostic("SP-HARDENED-SCRIPT", stage: "policy", "Executable podspec commands are forbidden", file: spec.name) }
                }
                // Validate build commands before installing sources or running
                // prepare hooks, so malformed phases leave no managed changes.
                for target in targets { _ = try NativeScriptPhase.parse(target["script_phases"]) }
                for request in resolved.requests {
                    if let spec = resolved.specs[request.root] { _ = try spec.scriptPhases(for: request) }
                }
                try FileManager.default.createDirectory(at: project.appendingPathComponent("Pods"), withIntermediateDirectories: true)
                var installed: [String: NativeSpec] = [:]
                catalog.selectedRequests = resolved.requests
                try catalog.prefetch(resolved.specs)
                for (name, spec) in resolved.specs.sorted(by: { $0.key < $1.key }) {
                    installed[name] = try catalog.install(spec)
                    let path = project.appendingPathComponent("Pods/Local Podspecs/" + name + ".podspec.json")
                    try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let serialized = try spec.checksum.flatMap { catalog.serializedSpecifications[$0] } ?? jsonData(spec.data)
                    try serialized.writeIfChanged(to: path, options: .atomic)
                }
                let resolution = NativeResolution(specs: installed, requests: resolved.requests)
                try catalog.finalize(installed, requests: resolved.requests)
                let installationOptions = manifest["options"] as? [String: Any] ?? [:]
                let skipGeneration = installationOptions["skip_pods_project_generation"] as? Bool == true
                let xcode: NativeXcode? = try NativeXcode(project: project, manifest: manifest, resolution: resolution, integrateUserProjects: !options.contains("--no-integrate") && installationOptions["integrate_targets"] as? Bool != false)
                let hookVariants = try xcode?.variantPlan ?? NativeVariantPlan(manifest: manifest, resolution: resolution)
                func hook(_ name: String, plugin: Bool = false) throws {
                    guard let dsl else { return }
                    let fallback: [String: Any] = ["path": project.appendingPathComponent("Pods/Pods.xcodeproj").path, "targets": []]
                    dsl.callback = { request in
                        guard let xcode else { throw Diagnostic("SP-HOOK-PROJECT", stage: "hook", "Project generation is disabled") }
                        let raw = (request["value"] as? [String: Any])?["path"] as? String ?? ""
                        let path = URL(fileURLWithPath: raw).standardizedFileURL.appendingPathComponent("project.pbxproj")
                        let selected = path == xcode.podsProject.url || xcode.generatedProjects[path.deletingLastPathComponent().path] != nil || xcode.userProjects[path.path] != nil
                        let result = try selected && request["callback"] as? String != "create_project" ? xcode.hookCallback(request) : projectAccess.callback(request, writable: true)
                        if request["callback"] as? String == "save_project", let value = request["value"] as? [String: Any], let path = value["path"] as? String { writeEvent(URL(fileURLWithPath: path).appendingPathComponent("project.pbxproj")) }
                        return result
                    }
                    defer { dsl.callback = nil }
                    let variants = hookVariants.variants.values.sorted { $0.label < $1.label }
                    let pods: [[String: Any]]
                    if variants.isEmpty {
                        pods = installed.values.sorted { $0.name < $1.name }.map { spec in ["name": spec.name, "pod_name": spec.name, "root": spec.directory?.path ?? "", "local": spec.local, "specification": spec.data] }
                    } else {
                        pods = try variants.compactMap { variant in
                            guard let spec = installed[variant.root] else { return nil }
                            return ["name": variant.label, "pod_name": spec.name, "root": spec.directory?.path ?? "", "local": spec.local, "specification": spec.data, "spec_names": variant.names + variant.supplementary.map(\.name), "build_type": xcode?.variantPlan?.variants[variant.key]?.mode ?? variant.mode, "platform_name": variant.platform, "deployment_target": variant.consumerDeployment, "swift_version": variant.swiftVersion ?? NSNull(), "consumer_targets": variant.consumerTargets, "consumer_keys": variant.consumerKeys, "installation_result": try xcode?.installationResult(variant) ?? [:]]
                        }
                    }
                    let result = try dsl.object(plugin ? "plugin_hook" : "hook", ["name": name, "manifest": manifest, "integrate_user_projects": !options.contains("--no-integrate") && installationOptions["integrate_targets"] as? Bool != false, "project": xcode?.hookProject ?? fallback.merging(["generated": false]) { _, new in new }, "projects": xcode?.hookGeneratedProjects ?? [], "pod_targets": pods])
                    if name == "pre_install", let xcode {
                        var changed = installed
                        for entry in result["pod_targets"] as? [[String: Any]] ?? [] {
                            guard let label = entry["name"] as? String, let variant = xcode.variantPlan?.variants.values.first(where: { $0.label == label }),
                                  let mode = entry["build_type"] as? String, ["library", "static", "dynamic"].contains(mode) else { throw Diagnostic("SP-HOOK-TARGET", stage: "hook", "Hook returned an invalid pod build type") }
                            xcode.variantPlan?.variants[variant.key]?.mode = mode
                            if let data = entry["specification"] as? [String: Any], let original = installed[variant.root] {
                                var spec = try NativeSpec(data: data, repository: original.repository, directory: original.directory, local: original.local, checksum: original.checksum)
                                guard spec.name == original.name, spec.version == original.version else { throw Diagnostic("SP-HOOK-SPEC", stage: "hook", "Hooks cannot change a resolved specification's identity") }
                                spec.checkout = original.checkout; changed[variant.root] = spec
                            }
                        }
                        xcode.resolution = NativeResolution(specs: changed, requests: resolved.requests)
                    }
                    if let xcode {
                        try xcode.applyHook(result)
                        for value in result["user_projects"] as? [[String: Any]] ?? [] {
                            guard let path = value["path"] as? String, let user = xcode.userProjects[URL(fileURLWithPath: path).appendingPathComponent("project.pbxproj").path] else { throw Diagnostic("SP-HOOK-PROJECT", stage: "hook", "Hook returned an unknown consumer project") }
                            var before = user.root; before["objects"] = user.objects
                            try xcode.applyHookGraph(value, to: user)
                            var after = user.root; after["objects"] = user.objects
                            if try jsonData(before) != jsonData(after) { try user.save(); writeEvent(user.url) }
                        }
                    }
                    if !plugin { events.append(["kind": "phase", "name": name]) }
                }
                try hook("pre_install")
                if !skipGeneration && !options.contains("--no-integrate") { try hook("pre_integrate") }
                if !skipGeneration, let xcode { try xcode.generate() }
                if !skipGeneration, let xcode, xcode.multipleProjects { try xcode.prepareMultipleProjects() }
                try hook("post_install")
                if !skipGeneration, let xcode {
                    writeEvent(try xcode.savePods())
                    if !options.contains("--no-integrate") && installationOptions["integrate_targets"] as? Bool != false { for path in try xcode.integrate() { writeEvent(path) } }
                }
                if let xcode { events += xcode.configurationWarnings }
                if !skipGeneration && !options.contains("--no-integrate") && installationOptions["integrate_targets"] as? Bool != false { try hook("post_integrate") }
                if !skipGeneration, let xcode { writeEvent(try xcode.savePods()) }
                let referenceVersion = ((bundle.manifest["behavior_reference"] as? [String: [String: String]])?["cocoapods"])?["version"] ?? "unknown"
                try lock.verifyUnchanged()
                let text = try options.contains("--deployment") ? String(contentsOf: lockURL, encoding: .utf8) : NativeLock.make(resolution, direct: direct, checksum: checksum, referenceVersion: referenceVersion, manifestChecksum: manifestChecksum, previous: lock.raw)
                try Data(text.utf8).writeIfChanged(to: lockURL, options: .atomic)
                try Data(text.utf8).writeIfChanged(to: project.appendingPathComponent("Pods/Manifest.lock"), options: .atomic)
                try hook("post_install", plugin: true)
                if !skipGeneration, let xcode { writeEvent(try xcode.savePods()) }
                let specs = resolution.requests.map { request -> [String: Any] in
                    let spec = installed[request.root]!
                    return ["name": request.name, "version": spec.version.description, "module_name": spec.moduleName,
                            "dependencies": ((try? spec.dependencies(for: request)) ?? []).map { ["name": $0.name, "requirement": $0.requirements.joined(separator: ", ")] },
                            "source": spec.checkout.isEmpty ? (spec.data["source"] ?? [:]) : spec.checkout, "spec_repository": spec.repository, "local": spec.local, "root": spec.directory!.path]
                }
                var inputs = try dsl?.object("inputs") ?? ["files": [manifestPath.path: digest(try Data(contentsOf: manifestPath))]]
                if var environmentInputs = inputs["environment"] as? [String: Any] {
                    for key in environmentInputs.keys where key.hasPrefix("SWIFTPODS_") || key.hasPrefix("GEM_") || key.hasPrefix("BUNDLE_") || key == "PWD" || key == "SHLVL" || key == "_" { environmentInputs.removeValue(forKey: key) }
                    inputs["environment"] = environmentInputs
                }
                events.append(["kind": "installation", "engine": "swift", "input_manifest": manifestPath.path, "specs": specs,
                               "targets": targets.map { target -> [String: Any] in
                                   ["name": target["name"] ?? "", "platform": target["platform"] ?? [:], "dependencies": (target["dependencies"] as? [[String: Any]] ?? []).map { ["name": $0["name"] ?? "", "requirement": nativeStrings($0["requirements"]).joined(separator: ", ")] }]
                               }, "inputs": inputs, "plugins": manifest["plugins"] ?? [:]])
                if !machine && !silent { print("Installed \(installed.count) dependencies with SwiftPods.") }
            } else { throw Diagnostic("SP-COMMAND-UNSUPPORTED", stage: "cli", "Command \(action) is not implemented by the native Swift engine yet") }
            events.append(["kind": "completed", "status": 0])
            if !machine && !silent {
                let redactor = Redactor(environment: environment)
                for event in events where verbose || event["kind"] as? String == "warning" {
                    if let data = try? jsonData(event) { print(redactor.scrub(String(decoding: data, as: UTF8.self))) }
                }
            }
            return HostResult(status: 0, events: events)
        } catch {
            let signal = sp_cancellation_number()
            let diagnostic = signal == 0 ? (error as? Diagnostic ?? Diagnostic("SP-NATIVE-ERROR", stage: "install", String(describing: error))) : Diagnostic("SP-CANCELLED", stage: "execute", "Command cancelled by signal \(signal)")
            let status: Int32 = signal == 0 ? 1 : 128 + Int32(signal)
            var event: [String: Any] = ["kind": "diagnostic", "code": diagnostic.code, "stage": diagnostic.stage, "message": diagnostic.message, "file": diagnostic.file ?? ""]
            if let line = diagnostic.line { event["line"] = line }
            event["backtrace"] = diagnostic.backtrace; event["dependency_chain"] = diagnostic.dependencyChain
            if let state = diagnostic.state { event["project_state"] = state }
            if ["SP-LOCK-CONFLICT", "SP-XCODE-CONFLICT", "SP-WORKSPACE-CONFLICT"].contains(diagnostic.code), let file = diagnostic.file { events.append(["kind": "external_conflict", "path": file]) }
            events.append(event)
            events.append(["kind": "completed", "status": status])
            FileHandle.standardError.write(Data(Redactor(environment: environment).scrub("[\(diagnostic.code)] \(diagnostic.message)\n").utf8))
            for frame in diagnostic.backtrace { FileHandle.standardError.write(Data(Redactor(environment: environment).scrub("  " + frame + "\n").utf8)) }
            return HostResult(status: status, events: events)
        }
    }
}
