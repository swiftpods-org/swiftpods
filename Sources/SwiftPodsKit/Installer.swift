import CryptoKit
import Darwin
import Foundation
import SwiftPodsManifest
import SwiftPodsXcode

public struct InstallOptions: Sendable {
    /// Require a committed `Package.resolved` that satisfies every requirement.
    public var deployment = false
    /// Let Xcode resolve packages after integration.
    public var resolve = false
    /// Take over package references added without SwiftPods.
    public var adopt = false
    /// Use cached binaries and catalogs only.
    public var offline = false
    /// Fetch the latest version of catalogs that are not pinned to a revision.
    public var updateSources = false

    public init() {}
}

public struct InstallReport: Sendable, Codable {
    public struct ProjectReport: Sendable, Codable {
        public let project: String
        public let changes: [ProjectChange]
    }

    public var projects: [ProjectReport] = []
    public var binaries: [String] = []
    /// Things SwiftPods adjusted that a reader should know about, such as repaired SDK frameworks.
    public var notes: [String] = []
}

/// Installs a directory's Podfile into its Xcode projects.
public struct Installer: Sendable {
    public let directory: URL
    /// The project of targets that do not name one; nil means the only project next to the Podfile.
    public let project: URL?
    private let runner: CommandRunner
    private let cache: URL
    private let sourcesCache: URL

    public static let generatedDirectory = "SwiftPods"

    public init(
        directory: URL, project: URL? = nil, runner: CommandRunner = ProcessRunner(), cache: URL? = nil, sourcesCache: URL? = nil
    ) {
        self.directory = directory.standardizedFileURL
        self.project = project?.standardizedFileURL
        self.runner = runner
        self.cache = cache ?? BinaryStore.defaultCache
        self.sourcesCache = sourcesCache ?? GitCatalog.defaultCache
    }

    private func catalog(update: Bool, offline: Bool) -> GitCatalog {
        GitCatalog(cache: sourcesCache, runner: runner, update: update, offline: offline)
    }

    private var generated: URL { directory.appendingPathComponent(Self.generatedDirectory, isDirectory: true) }

    public func manifest(updateSources: Bool = false, offline: Bool = false) throws -> Manifest {
        let podfile = directory.appendingPathComponent("Podfile")
        guard FileManager.default.fileExists(atPath: podfile.path) else {
            throw SwiftPodsError("No Podfile in \(directory.path)")
        }
        let reader = ManifestReader(catalog: catalog(update: updateSources, offline: offline))
        do { return try reader.load(podfile.path) } catch { throw SwiftPodsError.wrap(error) }
    }

    public func install(_ options: InstallOptions) throws -> InstallReport {
        do { return try performInstall(options) } catch { throw SwiftPodsError.wrap(error) }
    }

    private func defaultProject() throws -> String {
        if let project {
            guard FileManager.default.fileExists(atPath: project.appendingPathComponent("project.pbxproj").path) else {
                throw SwiftPodsError("No Xcode project at \(project.path)")
            }
            return Paths.relative(from: directory, to: project)
        }
        let projects = (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?
            .filter { $0.hasSuffix(".xcodeproj") }.sorted() ?? []
        guard projects.count == 1 else {
            throw SwiftPodsError(
                projects.isEmpty ? "No Xcode project next to the Podfile" : "Several Xcode projects next to the Podfile: " + projects.joined(separator: ", "),
                file: directory.appendingPathComponent("Podfile").path,
                hint: "Declare `project 'Path/To.xcodeproj'` or pass --project")
        }
        return projects[0]
    }

    private func performInstall(_ options: InstallOptions) throws -> InstallReport {
        let manifest = try manifest(updateSources: options.updateSources, offline: options.offline)
        var projectPaths: [String] = []
        var targetsByProject: [String: [Target]] = [:]
        for target in manifest.targets {
            let path = try target.project ?? defaultProject()
            if targetsByProject[path] == nil { projectPaths.append(path) }
            targetsByProject[path, default: []].append(target)
        }
        var projects: [String: XcodeProject] = [:]
        for path in projectPaths {
            projects[path] = try XcodeProject(path: directory.appendingPathComponent(path))
        }

        if options.deployment {
            for path in projectPaths {
                // A catalog that moved a name since Package.resolved was committed leaves that package without a pin.
                let used = Set(targetsByProject[path]!.flatMap { $0.products.map(\.package) })
                let packages = manifest.packages.filter { used.contains($0.identity) && $0.requirement != nil }
                guard !packages.isEmpty else { continue }
                let file = PackageResolved.location(project: projects[path]!.path)
                let problems = try PackageResolved(contentsOf: file).problems(for: packages)
                if !problems.isEmpty {
                    throw SwiftPodsError(
                        "Package.resolved does not satisfy the Podfile:\n  " + problems.joined(separator: "\n  "), file: file.path,
                        hint: "Run `swiftpods install --resolve` and commit Package.resolved")
                }
            }
        }

        let fileManager = FileManager.default
        let staging = generated.appendingPathComponent(".staging-" + UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: staging) }
        var staged: [(URL, URL)] = []
        var obsolete: [URL] = []

        func stage(_ name: String, _ files: [String: String]) throws {
            let destination = generated.appendingPathComponent(name, isDirectory: true)
            guard Self.files(in: destination) != files else { return }
            let target = staging.appendingPathComponent(name, isDirectory: true)
            for (relative, text) in files {
                let file = target.appendingPathComponent(relative)
                try fileManager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(text.utf8).write(to: file)
            }
            staged.append((target, destination))
        }
        func stem(_ path: String) -> String { ((path as NSString).lastPathComponent as NSString).deletingPathExtension }
        func folder(_ name: String) -> String { name.replacingOccurrences(of: "/", with: "_") }

        // Both generated packages support the lowest deployment target any target has.
        var platforms: [Platform] = []
        for path in projectPaths {
            for target in targetsByProject[path]! {
                guard let platform = Self.platform(of: target, in: projects[path]!) else { continue }
                if let index = platforms.firstIndex(where: { $0.name == platform.name }) {
                    let current = platforms[index].deploymentTarget.flatMap(Version.init)
                    if let new = platform.deploymentTarget.flatMap(Version.init), current.map({ new < $0 }) ?? true {
                        platforms[index] = platform
                    }
                } else {
                    platforms.append(platform)
                }
            }
        }

        // Binaries become one generated local package.
        let binaryDirectory = generated.appendingPathComponent(BinaryPackage.directoryName, isDirectory: true)
        let usesBinaries = manifest.targets.contains { !$0.binaries.isEmpty }
        var binaryEntries: [BinaryPackage.Entry] = []
        var notes: [String] = []
        if usesBinaries {
            let store = BinaryStore(cache: cache, runner: runner, offline: options.offline)
            for binary in manifest.binaries {
                let contents = try store.contents(binary, podfileDirectory: directory)
                binaryEntries.append(BinaryPackage.Entry(binary: binary, xcframeworks: contents.xcframeworks, resources: contents.resources))
            }
            let package = BinaryPackage(entries: binaryEntries, platforms: platforms)
            try package.validate()
            let current = try? String(contentsOf: binaryDirectory.appendingPathComponent(".fingerprint"), encoding: .utf8)
            if current != package.fingerprint {
                let target = staging.appendingPathComponent(BinaryPackage.directoryName, isDirectory: true)
                notes = try package.render(into: target)
                staged.append((target, binaryDirectory))
            }
        } else if fileManager.fileExists(atPath: binaryDirectory.path) {
            obsolete.append(binaryDirectory)
        }

        // Everything the targets use goes into one generated package with a product per target, so projects keep
        // referencing the same products whatever the Podfile declares.
        let dependencyDirectory = generated.appendingPathComponent(DependencyPackage.directoryName, isDirectory: true)
        let targetCounts = Dictionary(projectPaths.flatMap { path in targetsByProject[path]!.map { ($0.name, 1) } }, uniquingKeysWith: +)
        func productBase(_ target: Target, _ path: String) -> String {
            targetCounts[target.name]! > 1 ? stem(path) + "-" + target.name : target.name
        }
        let used = Set(manifest.targets.flatMap { $0.products.map(\.package) })
        let usedPackages = manifest.packages.filter { used.contains($0.identity) }
        var products: [DependencyPackage.Product] = []
        for path in projectPaths {
            for target in targetsByProject[path]! {
                let linked = DependencyPackage.productName(productBase(target, path))
                products.append(.init(
                    name: linked, module: DependencyPackage.moduleName(linked),
                    dependencies: target.products.filter(\.link).map { ($0.product, $0.package) }
                        + target.binaries.map { ($0, BinaryPackage.directoryName) }))
                let unlinked = target.products.filter { !$0.link }
                if !unlinked.isEmpty {
                    let name = DependencyPackage.productName(productBase(target, path), unlinked: true)
                    products.append(.init(
                        name: name, module: DependencyPackage.moduleName(name), dependencies: unlinked.map { ($0.product, $0.package) }))
                }
            }
        }
        let dependencies = DependencyPackage(
            platforms: platforms,
            remote: usedPackages.compactMap { package in
                guard case .remote(let url) = package.location else { return nil }
                return .init(url: url, requirement: package.requirement!)
            },
            local: usedPackages.compactMap { package in
                guard case .local(let relative) = package.location else { return nil }
                return Paths.relative(from: dependencyDirectory, to: directory.appendingPathComponent(relative))
            } + (usesBinaries ? [Paths.relative(from: dependencyDirectory, to: binaryDirectory)] : []),
            products: products)
        try stage(DependencyPackage.directoryName, dependencies.files())

        // Build settings become one xcconfig per target; every target has one, so adding settings changes no project.
        let settingsDirectory = generated.appendingPathComponent("Settings", isDirectory: true)
        var settingsFiles: [String: [String: URL]] = [:]
        var settingsTexts: [String: String] = [:]
        for path in projectPaths {
            for target in targetsByProject[path]! {
                let file = settingsDirectory.appendingPathComponent(stem(path)).appendingPathComponent(folder(target.name) + ".xcconfig")
                settingsFiles[path, default: [:]][target.name] = file
                settingsTexts[Paths.relative(from: settingsDirectory, to: file)] = Self.xcconfig(target.settings)
            }
        }
        try stage("Settings", settingsTexts)

        // Script phases, binary resources and the check that the installation is current run from generated scripts.
        let scriptsDirectory = generated.appendingPathComponent(TargetScripts.directoryName, isDirectory: true)
        let signed = [directory.appendingPathComponent("Podfile")] + manifest.includes.map { URL(fileURLWithPath: $0) }
        var scriptFiles: [String: String] = [:]
        scriptFiles[TargetScripts.signatureFile] = try signed.map { file in
            let digest = SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
            return digest + "  " + Paths.relative(from: directory, to: file)
        }.joined(separator: "\n") + "\n"
        var scriptLocations: [String: [String: TargetScripts.Locations]] = [:]
        // Targets that embed a framework target of the Podfile embed its dynamic frameworks; they need not be in the Podfile.
        var embedders: [String: [String]] = [:]
        for path in projectPaths {
            embedders[path] = ProjectIntegration.embeddingTargets(projects[path]!, of: Set(targetsByProject[path]!.map(\.name)))
        }
        for path in projectPaths {
            let projectDirectory = projects[path]!.sourceRoot
            func locate(_ name: String) -> (URL, TargetScripts.Locations) {
                let targetDirectory = scriptsDirectory.appendingPathComponent(stem(path)).appendingPathComponent(folder(name))
                let locations = TargetScripts.Locations(
                    generated: Paths.relative(from: projectDirectory, to: generated), podfile: Paths.relative(from: projectDirectory, to: directory),
                    target: Paths.relative(from: projectDirectory, to: targetDirectory))
                scriptLocations[path, default: [:]][name] = locations
                return (targetDirectory, locations)
            }
            for target in targetsByProject[path]! {
                let (targetDirectory, locations) = locate(target.name)
                let resources = binaryEntries.filter { target.binaries.contains($0.binary.name) }.flatMap { entry in
                    entry.resources.map {
                        Paths.relative(
                            from: projectDirectory, to: binaryDirectory.appendingPathComponent(BinaryPackage.resourcePath(entry.binary.name, $0)))
                    }
                }
                // File lists cannot include other lists, so the scripts' own lists are read now.
                var fileLists: [String: [String]] = [:]
                for list in target.scriptPhases.flatMap({ $0.inputFileLists + $0.outputFileLists }) {
                    let resolved = list.replacingOccurrences(of: "$(SRCROOT)", with: projectDirectory.path)
                        .replacingOccurrences(of: "${SRCROOT}", with: projectDirectory.path)
                    let url = resolved.hasPrefix("/") ? URL(fileURLWithPath: resolved) : projectDirectory.appendingPathComponent(resolved)
                    if let text = try? String(contentsOf: url, encoding: .utf8) {
                        fileLists[list] = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
                    } else {
                        notes.append("\(target.name): file list \(list) is read when installing and was not found, so its files are not declared")
                    }
                }
                let files = TargetScripts.files(
                    scripts: target.scriptPhases, resources: resources, embedsFrameworks: embedders[path]!.contains(target.name),
                    signed: signed.map { Paths.relative(from: directory, to: $0) }, fileLists: fileLists, paths: locations)
                for (relative, text) in files {
                    scriptFiles[Paths.relative(from: scriptsDirectory, to: targetDirectory.appendingPathComponent(relative))] = text
                }
            }
            let declared = Set(targetsByProject[path]!.map(\.name))
            for name in embedders[path]! where !declared.contains(name) {
                let (targetDirectory, locations) = locate(name)
                let files = TargetScripts.files(scripts: [], resources: [], embedsFrameworks: true, signed: [], fileLists: [:], paths: locations)
                for (relative, text) in files where relative.hasPrefix(TargetScripts.Phase.finish.file + ".") {
                    scriptFiles[Paths.relative(from: scriptsDirectory, to: targetDirectory.appendingPathComponent(relative))] = text
                }
            }
        }
        try stage(TargetScripts.directoryName, scriptFiles)

        var report = InstallReport()
        report.binaries = usesBinaries ? manifest.binaries.map(\.name) : []
        report.notes = notes
        for path in projectPaths {
            var project = projects[path]!
            let projectDirectory = project.sourceRoot
            let relative = Paths.relative(from: projectDirectory, to: dependencyDirectory)
            // A file reference to the package folder rather than an XCLocalSwiftPackageReference: Xcode 26.2 crashes
            // resolving a graph that shrinks, as Firebase's does, when the project holds the latter.
            let package = ProjectPlan.PackageReference(key: "package:local:" + relative, object: [
                "isa": "PBXFileReference", "lastKnownFileType": "wrapper", "name": .string(DependencyPackage.directoryName),
                "path": .string(relative), "sourceTree": "SOURCE_ROOT",
            ])
            func phasePlan(_ phase: TargetScripts.Phase, _ target: String) -> ProjectPlan.PhasePlan {
                let locations = scriptLocations[path]![target]!
                return ProjectPlan.PhasePlan(
                    name: phase.rawValue, script: TargetScripts.phaseScript(phase, paths: locations),
                    inputFileLists: [TargetScripts.fileList(phase, outputs: false, paths: locations)],
                    outputFileLists: [TargetScripts.fileList(phase, outputs: true, paths: locations)], position: phase.position)
            }
            var plan = ProjectPlan()
            plan.packages = [package]
            let targets = targetsByProject[path]!
            for declared in usedPackages where targets.contains(where: { $0.products.contains { $0.package == declared.identity } }) {
                switch declared.location {
                case .remote(let url):
                    plan.managedPackageKeys.insert("package:" + PackageLocation.canonical(url))
                case .local(let path):
                    plan.managedPackageKeys.insert(
                        "package:local:" + Paths.relative(from: projectDirectory, to: directory.appendingPathComponent(path)))
                    plan.managedLocalProducts.formUnion(targets.flatMap { $0.products.filter { $0.package == declared.identity }.map(\.product) })
                }
            }
            for target in targets {
                let base = productBase(target, path)
                var products = [ProjectPlan.Product(package: package, name: DependencyPackage.productName(base), link: true)]
                if target.products.contains(where: { !$0.link }) {
                    products.append(.init(package: package, name: DependencyPackage.productName(base, unlinked: true), link: false))
                }
                plan.targets.append(.init(
                    name: target.name, products: products, phases: TargetScripts.Phase.allCases.map { phasePlan($0, target.name) },
                    settingsFile: Paths.relative(from: projectDirectory, to: settingsFiles[path]![target.name]!),
                    hasSettings: !target.settings.isEmpty))
            }
            let declared = Set(targets.map(\.name))
            for name in embedders[path]! where !declared.contains(name) {
                plan.targets.append(.init(name: name, products: [], phases: [phasePlan(.finish, name)], settingsFile: nil, hasSettings: false))
            }
            let changes = try ProjectIntegration.apply(plan, to: &project, adopt: options.adopt)
            projects[path] = project
            report.projects.append(.init(project: path, changes: changes))
        }

        // Every check passed: replace generated files, then write projects.
        for (source, destination) in staged { try Self.replace(destination, with: source) }
        for url in obsolete { try fileManager.removeItem(at: url) }
        for path in projectPaths { try projects[path]!.save() }
        try? fileManager.removeItem(at: staging)
        if let contents = try? fileManager.contentsOfDirectory(atPath: generated.path), contents.isEmpty {
            try? fileManager.removeItem(at: generated)
        }

        if options.resolve {
            for path in projectPaths {
                _ = try runner.run(
                    "/usr/bin/xcrun", ["xcodebuild", "-resolvePackageDependencies", "-project", projects[path]!.path.path],
                    in: directory)
                let used = Set(targetsByProject[path]!.flatMap { $0.products.map(\.package) })
                let packages = manifest.packages.filter { used.contains($0.identity) && $0.requirement != nil }
                let file = PackageResolved.location(project: projects[path]!.path)
                let problems = try PackageResolved(contentsOf: file).problems(for: packages)
                if !problems.isEmpty {
                    throw SwiftPodsError("Xcode resolved versions the Podfile does not allow:\n  " + problems.joined(separator: "\n  "), file: file.path)
                }
            }
        }
        return report
    }

    /// Removes everything SwiftPods added to the projects and the generated directory; with `cocoapods`,
    /// also a CocoaPods or SwiftPods 0.1 integration.
    public func deintegrate(cocoapods: Bool = false) throws -> InstallReport {
        var paths = Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.filter { $0.hasSuffix(".xcodeproj") } ?? [])
        if let manifest = try? manifest() { paths.formUnion(manifest.targets.compactMap(\.project)) }
        if let project { paths.insert(Paths.relative(from: directory, to: project)) }
        var report = InstallReport()
        do {
            var projects: [(String, XcodeProject)] = []
            for path in paths.sorted() {
                var project = try XcodeProject(path: directory.appendingPathComponent(path))
                var changes = try ProjectIntegration.apply(ProjectPlan(), to: &project, adopt: false)
                if cocoapods {
                    changes += CocoaPodsIntegration.remove(from: &project)
                    let workspace = project.path.deletingPathExtension().appendingPathExtension("xcworkspace")
                    if try CocoaPodsIntegration.removePodsProject(fromWorkspace: workspace) {
                        changes.append(ProjectChange(kind: .removed, subject: "Pods/Pods.xcodeproj from " + workspace.lastPathComponent))
                    }
                }
                projects.append((path, project))
                report.projects.append(.init(project: path, changes: changes))
            }
            for (_, project) in projects { try project.save() }
        } catch { throw SwiftPodsError.wrap(error) }
        if FileManager.default.fileExists(atPath: generated.path) { try FileManager.default.removeItem(at: generated) }
        return report
    }

    static func requirement(_ requirement: Requirement) -> PBXValue {
        switch requirement {
        case .exact(let version): ["kind": "exactVersion", "version": .string(version.description)]
        case .upToNextMajor(let version): ["kind": "upToNextMajorVersion", "minimumVersion": .string(version.description)]
        case .upToNextMinor(let version): ["kind": "upToNextMinorVersion", "minimumVersion": .string(version.description)]
        case .range(let lower, let upper):
            ["kind": "versionRange", "minimumVersion": .string(lower.description), "maximumVersion": .string(upper.description)]
        case .branch(let branch): ["kind": "branch", "branch": .string(branch)]
        case .revision(let revision): ["kind": "revision", "revision": .string(revision)]
        }
    }

    static func xcconfig(_ settings: [BuildSetting]) -> String {
        var lines = ["// Generated by SwiftPods from the Podfile. Do not edit."]
        for setting in settings {
            if let configurations = setting.configurations {
                lines += configurations.map { "\(setting.key)[config=\($0)] = \(setting.value)" }
            } else {
                lines.append("\(setting.key) = \(setting.value)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Text files below `directory` by relative path; hidden files, such as Xcode's `.swiftpm`, are not SwiftPods'.
    private static func files(in directory: URL) -> [String: String] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        else { return [:] }
        var result: [String: String] = [:]
        for case let url as URL in enumerator where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            result[Paths.relative(from: directory, to: url)] = try? String(contentsOf: url, encoding: .utf8)
        }
        return result
    }

    /// The platform a target builds for: the Podfile's, or the deployment target in the project's build settings.
    static func platform(of target: Target, in project: XcodeProject) -> Platform? {
        if let platform = target.platform, platform.deploymentTarget != nil { return platform }
        var settings: [String: PBXValue] = [:]
        let owners = (project.nativeTargets.first { $0.name == target.name }.map { [$0.id] } ?? []) + [project.rootID]
        for owner in owners {
            for id in project.configurations(of: owner).values.sorted() {
                for (key, value) in project[id]?["buildSettings"]?.dictionary ?? [:] where settings[key] == nil { settings[key] = value }
            }
        }
        let platforms: [(PlatformName, String, String)] = [
            (.ios, "iphoneos", "IPHONEOS_DEPLOYMENT_TARGET"), (.macos, "macosx", "MACOSX_DEPLOYMENT_TARGET"),
            (.tvos, "appletvos", "TVOS_DEPLOYMENT_TARGET"), (.watchos, "watchos", "WATCHOS_DEPLOYMENT_TARGET"),
            (.visionos, "xros", "XROS_DEPLOYMENT_TARGET"),
        ]
        let sdk = settings["SDKROOT"]?.string
        guard let (name, _, key) = platforms.first(where: { $0.0 == target.platform?.name || ($0.1 == sdk && target.platform == nil) }),
            let version = settings[key]?.string, Version(version) != nil
        else { return target.platform }
        return Platform(name: name, deploymentTarget: version)
    }

    /// Puts `source` at `destination`, swapping atomically when something is already there.
    static func replace(_ destination: URL, with source: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            guard renamex_np(source.path, destination.path, UInt32(RENAME_SWAP)) == 0 else {
                throw SwiftPodsError("Cannot replace \(destination.path): \(String(cString: strerror(errno)))")
            }
            try fileManager.removeItem(at: source)
        } else {
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.moveItem(at: source, to: destination)
        }
    }
}
