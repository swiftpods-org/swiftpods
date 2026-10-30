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
    private let runner: CommandRunner
    private let cache: URL
    private let sourcesCache: URL

    public static let generatedDirectory = "SwiftPods"

    public init(directory: URL, runner: CommandRunner = ProcessRunner(), cache: URL? = nil, sourcesCache: URL? = nil) {
        self.directory = directory.standardizedFileURL
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
        let projects = (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?
            .filter { $0.hasSuffix(".xcodeproj") }.sorted() ?? []
        guard projects.count == 1 else {
            throw SwiftPodsError(
                projects.isEmpty ? "No Xcode project next to the Podfile" : "Several Xcode projects next to the Podfile: " + projects.joined(separator: ", "),
                file: directory.appendingPathComponent("Podfile").path,
                hint: "Declare `project 'Path/To.xcodeproj'`")
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
                let used = Set(targetsByProject[path]!.flatMap { $0.products.map(\.package) })
                // A catalog may have changed since the project was committed; deployment must not follow it.
                let referenced = Set(projects[path]!.objects.values.compactMap { $0.string("repositoryURL").map(PackageLocation.canonical) })
                if let moved = manifest.packages.first(where: { package in
                    guard used.contains(package.identity), package.catalog != nil, case .remote(let url) = package.location else { return false }
                    return !referenced.contains(PackageLocation.canonical(url))
                }), case .remote(let url) = moved.location {
                    throw SwiftPodsError(
                        "The catalog resolves `\(moved.name)` to \(url), which \(path) does not reference", file: moved.declaredAt.description,
                        hint: "Run `swiftpods install` without --deployment, review the change and commit the project")
                }
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

        // Binaries become one generated local package.
        let binaryDirectory = generated.appendingPathComponent(BinaryPackage.directoryName, isDirectory: true)
        let usesBinaries = manifest.targets.contains { !$0.binaries.isEmpty }
        var binaryEntries: [BinaryPackage.Entry] = []
        var binaryNotes: [String] = []
        if usesBinaries {
            let store = BinaryStore(cache: cache, runner: runner, offline: options.offline)
            for binary in manifest.binaries {
                let contents = try store.contents(binary, podfileDirectory: directory)
                binaryEntries.append(BinaryPackage.Entry(binary: binary, xcframeworks: contents.xcframeworks, resources: contents.resources))
            }
            let entries = binaryEntries
            var platforms: [Platform] = []
            for target in manifest.targets where !target.binaries.isEmpty {
                guard let platform = target.platform else { continue }
                if let index = platforms.firstIndex(where: { $0.name == platform.name }) {
                    let current = platforms[index].deploymentTarget.flatMap(Version.init)
                    if let new = platform.deploymentTarget.flatMap(Version.init), current.map({ new < $0 }) ?? true {
                        platforms[index] = platform
                    }
                } else {
                    platforms.append(platform)
                }
            }
            let package = BinaryPackage(entries: entries, platforms: platforms)
            try package.validate()
            let current = try? String(contentsOf: binaryDirectory.appendingPathComponent(".fingerprint"), encoding: .utf8)
            if current != package.fingerprint {
                let target = staging.appendingPathComponent(BinaryPackage.directoryName, isDirectory: true)
                binaryNotes = try package.render(into: target)
                staged.append((target, binaryDirectory))
            }
        } else if fileManager.fileExists(atPath: binaryDirectory.path) {
            obsolete.append(binaryDirectory)
        }

        // Build settings become one xcconfig per target.
        let settingsDirectory = generated.appendingPathComponent("Settings", isDirectory: true)
        var settingsFiles: [String: [String: URL]] = [:]
        var settingsTexts: [URL: String] = [:]
        for path in projectPaths {
            let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            for target in targetsByProject[path]! where !target.settings.isEmpty {
                let name = target.name.replacingOccurrences(of: "/", with: "_") + ".xcconfig"
                let file = settingsDirectory.appendingPathComponent(stem).appendingPathComponent(name)
                settingsFiles[path, default: [:]][target.name] = file
                settingsTexts[file] = Self.xcconfig(target.settings)
            }
        }
        if !settingsTexts.isEmpty {
            let current = Self.files(in: settingsDirectory)
            let wanted = Dictionary(uniqueKeysWithValues: settingsTexts.map { (Paths.relative(from: settingsDirectory, to: $0.key), $0.value) })
            if current != wanted {
                let target = staging.appendingPathComponent("Settings", isDirectory: true)
                for (relative, text) in wanted {
                    let file = target.appendingPathComponent(relative)
                    try fileManager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Data(text.utf8).write(to: file)
                }
                staged.append((target, settingsDirectory))
            }
        } else if fileManager.fileExists(atPath: settingsDirectory.path) {
            obsolete.append(settingsDirectory)
        }

        var report = InstallReport()
        var packageProjects = Set<String>()
        report.binaries = usesBinaries ? manifest.binaries.map(\.name) : []
        report.notes = binaryNotes
        for path in projectPaths {
            var project = projects[path]!
            let projectDirectory = project.sourceRoot
            func reference(_ package: Package) -> ProjectPlan.PackageReference {
                switch package.location {
                case .remote(let url):
                    return .init(
                        key: "package:" + PackageLocation.canonical(url),
                        object: ["isa": "XCRemoteSwiftPackageReference", "repositoryURL": .string(url), "requirement": Self.requirement(package.requirement!)])
                case .local(let relative):
                    return local(directory.appendingPathComponent(relative))
                }
            }
            // A file reference to the package folder rather than an XCLocalSwiftPackageReference: Xcode 26.2 crashes
            // resolving a graph that shrinks, as Firebase's does, when the project holds the latter.
            func local(_ url: URL) -> ProjectPlan.PackageReference {
                let relative = Paths.relative(from: projectDirectory, to: url)
                return .init(key: "package:local:" + relative, object: [
                    "isa": "PBXFileReference", "lastKnownFileType": "wrapper", "name": .string(url.lastPathComponent),
                    "path": .string(relative), "sourceTree": "SOURCE_ROOT",
                ])
            }
            let targets = targetsByProject[path]!
            var plan = ProjectPlan()
            var references: [String: ProjectPlan.PackageReference] = [:]
            for package in manifest.packages where targets.contains(where: { $0.products.contains { $0.package == package.identity } }) {
                let value = reference(package)
                references[package.identity] = value
                plan.packages.append(value)
            }
            let binaries = targets.contains { !$0.binaries.isEmpty } ? local(binaryDirectory) : nil
            if let binaries { plan.packages.append(binaries) }
            for target in targets {
                var products = target.products.map { ProjectPlan.Product(package: references[$0.package]!, name: $0.product, link: $0.link) }
                products += target.binaries.map { ProjectPlan.Product(package: binaries!, name: $0, link: true) }
                let resources = binaryEntries.filter { target.binaries.contains($0.binary.name) }.flatMap { entry in
                    entry.resources.map {
                        Paths.relative(
                            from: projectDirectory,
                            to: binaryDirectory.appendingPathComponent(BinaryPackage.resourcePath(entry.binary.name, $0)))
                    }
                }
                plan.targets.append(.init(
                    name: target.name, products: products, scripts: target.scriptPhases,
                    settingsFile: settingsFiles[path]?[target.name].map { Paths.relative(from: projectDirectory, to: $0) },
                    resources: resources))
            }
            if !plan.packages.isEmpty { packageProjects.insert(path) }
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
            for path in projectPaths where packageProjects.contains(path) {
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

    private static func files(in directory: URL) -> [String: String] {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return [:] }
        var result: [String: String] = [:]
        for case let url as URL in enumerator where url.pathExtension == "xcconfig" {
            result[Paths.relative(from: directory, to: url)] = try? String(contentsOf: url, encoding: .utf8)
        }
        return result
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
