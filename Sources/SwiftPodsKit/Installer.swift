import CryptoKit
import Darwin
import Foundation
import SwiftPodsManifest
import SwiftPodsXcode

public struct InstallOptions: Sendable {
    /// Validate Xcode's frozen package graph and require a matching `SwiftPods.lock` for catalogs and overrides.
    public var deployment = false
    /// Let Xcode resolve packages after integration.
    public var resolve = false
    /// Take over package references added without SwiftPods.
    public var adopt = false
    /// Use cached binaries and catalogs only.
    public var offline = false
    /// Fetch the latest version of catalogs that are not pinned to a revision.
    public var updateSources = false
    /// Accepted for compatibility: script file lists are read wherever the Podfile says they are.
    public var allowExternalFileLists = false

    public init() {}
}

public struct InstallReport: Sendable, Codable {
    public struct ProjectReport: Sendable, Codable {
        public let project: String
        public var changes: [ProjectChange]
    }

    public var projects: [ProjectReport] = []
    public var binaries: [String] = []
    /// Things SwiftPods adjusted that a reader should know about, such as repaired SDK frameworks.
    public var notes: [String] = []
}

/// Installs a directory's Podfile into its Xcode projects.
///
/// Generated folders are rendered into a staging directory inside `SwiftPods/` and swapped in by rename; the project
/// files are written after them, and `SwiftPods.lock` last. A failure restores what this run replaced. An install that
/// is interrupted outright is completed by running it again: every step is idempotent.
public struct Installer: Sendable {
    public let directory: URL
    /// The project of targets that do not name one; nil means the only project next to the Podfile.
    public let project: URL?
    private let runner: CommandRunner
    private let cache: URL
    private let sourcesCache: URL

    public static let generatedDirectory = "SwiftPods"
    private static let ownershipFile = ".swiftpods-owned"
    private static let ownership = "SwiftPods generated directory v1\n"
    /// Folders inside `SwiftPods/` that SwiftPods writes; anything else there is the user's.
    private static let managedFolders = [
        BinaryPackage.directoryName, DependencyPackage.directoryName, TargetScripts.directoryName, "Settings",
        GeneratedPackageMetadata.overridesDirectory,
    ]

    public init(
        directory: URL, project: URL? = nil, runner: CommandRunner = ProcessRunner(), cache: URL? = nil, sourcesCache: URL? = nil
    ) {
        self.directory = directory.standardizedFileURL
        self.project = project?.standardizedFileURL
        self.runner = runner
        self.cache = cache ?? BinaryStore.defaultCache
        self.sourcesCache = sourcesCache ?? GitCatalog.defaultCache
    }

    private var generated: URL { directory.appendingPathComponent(Self.generatedDirectory, isDirectory: true) }
    private var lockFile: URL { directory.appendingPathComponent(SwiftPodsLock.fileName) }

    public func manifest(updateSources: Bool = false, offline: Bool = false) throws -> Manifest {
        let lockFile = lockFile
        let lockProvider: @Sendable () throws -> SwiftPodsLock?
        if updateSources { lockProvider = { nil } } else { lockProvider = { try SwiftPodsLock.read(at: lockFile) } }
        let catalog = GitCatalog(
            cache: sourcesCache, runner: runner, update: updateSources, offline: offline, lockProvider: lockProvider)
        return try manifest(using: catalog)
    }

    private func manifest(using catalog: GitCatalog) throws -> Manifest {
        let podfile = directory.appendingPathComponent("Podfile")
        guard FileManager.default.fileExists(atPath: podfile.path) else {
            throw SwiftPodsError("No Podfile in \(directory.path)")
        }
        do { return try ManifestReader(catalog: catalog).load(podfile.path) } catch { throw SwiftPodsError.wrap(error) }
    }

    public func install(_ options: InstallOptions) throws -> InstallReport {
        do { return try performInstall(options) } catch { throw SwiftPodsError.wrap(error) }
    }

    /// Serializes SwiftPods commands in one directory, without a lock file users would have to ignore.
    private final class WorkspaceLock {
        private let descriptor: Int32

        init(directory: URL) throws {
            descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard descriptor >= 0 else {
                throw SwiftPodsError("Cannot open \(directory.path): \(String(cString: strerror(errno)))")
            }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                close(descriptor)
                throw SwiftPodsError("Another SwiftPods command is updating \(directory.path)")
            }
        }

        deinit {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
    }

    /// The generated `SwiftPods/` directory. Each managed folder is written into a staging directory and swapped in
    /// whole by `rename`; until `finish`, the folders it replaced stay in staging so `rollback` can restore them.
    private final class GeneratedRoot {
        let url: URL
        private let staging: URL
        private var swapped: [(name: String, previous: URL?)] = []

        init(_ url: URL, create: Bool) throws {
            self.url = url
            let fileManager = FileManager.default
            let marker = url.appendingPathComponent(Installer.ownershipFile)
            if !FileTree.exists(url) {
                guard create else { throw SwiftPodsError("\(url.path) does not exist", hint: "Run swiftpods install") }
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            }
            guard FileTree.isDirectory(url) else { throw SwiftPodsError("\(url.path) is not a directory") }
            if !Self.hasMarker(marker, Installer.ownership) {
                guard try Self.isLegacyRoot(url) else {
                    throw SwiftPodsError(
                        "Refusing to manage non-SwiftPods directory \(url.path)",
                        hint: "Move it away, or run `swiftpods deintegrate` with the SwiftPods version that created it")
                }
                try Data(Installer.ownership.utf8).write(to: marker)
            }
            // Only a claimed SwiftPods root can contain staging this run is allowed to clean up.
            for name in try fileManager.contentsOfDirectory(atPath: url.path) where Self.isOwnedStaging(name, in: url) {
                let abandoned = url.appendingPathComponent(name)
                guard Self.canDiscard(abandoned) else { continue }
                try? fileManager.removeItem(at: abandoned)
            }
            staging = url.appendingPathComponent(Self.stagingPrefix + UUID().uuidString, isDirectory: true)
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
            do {
                try Data(Self.stagingOwnership.utf8).write(to: staging.appendingPathComponent(Self.stagingMarker))
            } catch {
                try? fileManager.removeItem(at: staging)
                throw error
            }
        }

        private static let stagingPrefix = ".swiftpods-staging-"
        private static let stagingMarker = ".swiftpods-staging"
        private static let stagingOwnership = "SwiftPods generated staging v1\n"
        private static let backupPrefix = ".previous-"

        private static func hasMarker(_ file: URL, _ value: String) -> Bool {
            guard let status = try? FileTree.status(file), status.st_mode & S_IFMT == S_IFREG,
                status.st_size == value.utf8.count
            else { return false }
            return (try? String(contentsOf: file, encoding: .utf8)) == value
        }

        private static func isOwnedStaging(_ name: String, in root: URL) -> Bool {
            let prefixes = [stagingPrefix, ".staging-"]
            guard let prefix = prefixes.first(where: { name.hasPrefix($0) }),
                UUID(uuidString: String(name.dropFirst(prefix.count))) != nil
            else { return false }
            let directory = root.appendingPathComponent(name)
            return FileTree.isDirectory(directory) && hasMarker(directory.appendingPathComponent(stagingMarker), stagingOwnership)
        }

        private static func canDiscard(_ staging: URL) -> Bool {
            guard let children = try? FileManager.default.contentsOfDirectory(atPath: staging.path) else { return false }
            return !children.contains { $0.hasPrefix(backupPrefix) }
        }

        /// An empty directory, or what SwiftPods 0.2 wrote before it had an ownership marker: only managed folders,
        /// with generated package manifests.
        private static func isLegacyRoot(_ url: URL) throws -> Bool {
            let children = try FileManager.default.contentsOfDirectory(atPath: url.path)
            guard !children.isEmpty else { return true }
            guard children.allSatisfy(Installer.managedFolders.contains), children.contains(DependencyPackage.directoryName) else {
                return false
            }
            return [DependencyPackage.directoryName, BinaryPackage.directoryName].filter(children.contains).allSatisfy { name in
                let manifest = url.appendingPathComponent(name).appendingPathComponent("Package.swift")
                let lines = ((try? String(contentsOf: manifest, encoding: .utf8)) ?? "").components(separatedBy: .newlines)
                return lines.count >= 2 && lines[0].hasPrefix("// swift-tools-version: ")
                    && lines[1] == "// Generated by SwiftPods from the Podfile. Do not edit."
            }
        }

        /// Where to write a folder before `publish` swaps it in.
        func staged(_ name: String) -> URL { staging.appendingPathComponent(name, isDirectory: true) }

        func publish(_ name: String) throws {
            try swap(name, with: staged(name))
        }

        func withdraw(_ name: String) throws {
            guard FileTree.exists(url.appendingPathComponent(name)) else { return }
            try swap(name, with: nil)
        }

        private func swap(_ name: String, with replacement: URL?) throws {
            let destination = url.appendingPathComponent(name)
            var previous: URL?
            if FileTree.exists(destination) {
                previous = staging.appendingPathComponent(Self.backupPrefix + name)
                try FileManager.default.moveItem(at: destination, to: previous!)
            }
            swapped.append((name, previous))
            if let replacement { try FileManager.default.moveItem(at: replacement, to: destination) }
        }

        var ownsOverrides: Bool {
            let marker = url.appendingPathComponent(GeneratedPackageMetadata.overridesDirectory)
                .appendingPathComponent(GeneratedPackageMetadata.overridesMarker)
            return (try? String(contentsOf: marker, encoding: .utf8)) == GeneratedPackageMetadata.overridesOwnership
        }

        /// Restores folders by rename and leaves any remaining backups in staging if restoration fails.
        func rollback() -> [String] {
            var problems: [String] = []
            for (name, previous) in swapped.reversed() {
                let destination = url.appendingPathComponent(name)
                do {
                    if FileTree.exists(destination) {
                        try FileManager.default.moveItem(at: destination, to: staged(name))
                    }
                    if let previous { try FileManager.default.moveItem(at: previous, to: destination) }
                } catch {
                    problems.append("Cannot restore \(destination.path): \(error.localizedDescription)")
                }
            }
            if problems.isEmpty {
                finish()
            } else {
                problems.append("Staging and any remaining backups are at \(staging.path)")
            }
            return problems
        }

        /// Discards the staging directory and, when nothing is left, the generated directory itself.
        func finish(deintegrating: Bool = false) {
            let fileManager = FileManager.default
            try? fileManager.removeItem(at: staging)
            guard let remaining = try? fileManager.contentsOfDirectory(atPath: url.path) else { return }
            if remaining.allSatisfy({ $0 == Installer.ownershipFile }) {
                try? fileManager.removeItem(at: url)
            } else if deintegrating {
                let retainsBackups = remaining.contains { name in
                    Self.isOwnedStaging(name, in: url) && !Self.canDiscard(url.appendingPathComponent(name))
                }
                if !retainsBackups { try? fileManager.removeItem(at: url.appendingPathComponent(Installer.ownershipFile)) }
            }
        }
    }

    private func defaultProject() throws -> String {
        if let project {
            guard FileManager.default.fileExists(atPath: project.appendingPathComponent("project.pbxproj").path) else {
                throw SwiftPodsError("No Xcode project at \(project.path)")
            }
            return Paths.relative(from: directory, to: project)
        }
        let projects = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".xcodeproj") }.sorted()
        guard projects.count == 1 else {
            throw SwiftPodsError(
                projects.isEmpty ? "No Xcode project next to the Podfile" : "Several Xcode projects next to the Podfile: " + projects.joined(separator: ", "),
                file: directory.appendingPathComponent("Podfile").path,
                hint: "Declare `project 'Path/To.xcodeproj'` or pass --project")
        }
        return projects[0]
    }

    /// Reads each project once; two paths naming the same project are an error.
    private func loadProjects(_ paths: [String]) throws -> [String: XcodeProject] {
        var projects: [String: XcodeProject] = [:]
        var identities: [String: String] = [:]
        for path in paths {
            let url = directory.appendingPathComponent(path)
            guard FileManager.default.fileExists(atPath: url.appendingPathComponent("project.pbxproj").path) else {
                throw SwiftPodsError("No Xcode project at \(url.path)")
            }
            let status = try FileTree.status(url.resolvingSymlinksInPath())
            let identity = "\(status.st_dev):\(status.st_ino)"
            if let existing = identities.updateValue(path, forKey: identity) {
                throw SwiftPodsError("Project paths \(existing) and \(path) refer to the same Xcode project")
            }
            projects[path] = try XcodeProject(path: url)
        }
        return projects
    }

    /// Runs `xcodebuild` on a project from its directory.
    private func resolvePackages(_ arguments: [String], project: XcodeProject) throws {
        _ = try runner.run(
            "/usr/bin/xcrun", arguments + ["-project", project.path.lastPathComponent],
            in: project.path.deletingLastPathComponent())
    }

    private static func firstMissingResolvedDirectory(in project: URL) -> URL? {
        let components = ["project.xcworkspace", "xcshareddata", "swiftpm"]
        return components.indices.map { project.appendingPathComponent(components[...$0].joined(separator: "/")) }
            .first { !FileTree.exists($0) }
    }

    private struct FileBackup {
        let file: URL
        let data: Data?
        var createdDirectory: URL? = nil

        func restore() throws {
            if let createdDirectory {
                if FileTree.exists(createdDirectory) { try FileManager.default.removeItem(at: createdDirectory) }
            } else if let data {
                try FileTree.replace(file, with: data)
            } else if FileTree.exists(file) {
                try FileManager.default.removeItem(at: file)
            }
        }
    }

    private static func restore(_ backups: [FileBackup]) -> [String] {
        var problems: [String] = []
        for backup in backups.reversed() {
            do {
                try backup.restore()
            } catch {
                problems.append("Cannot restore \(backup.file.path): \(error.localizedDescription)")
            }
        }
        return problems
    }

    private static func rollbackError(_ original: any Error, problems: [String]) -> any Error {
        guard !problems.isEmpty else { return original }
        return SwiftPodsError(
            "SwiftPods rollback was incomplete:\n  " + problems.joined(separator: "\n  "),
            hint: "Original error: \(original)")
    }

    /// The tree of each override, materialized from the bare Git cache into `staging`.
    private static func stageOverrides(
        _ packages: [Package], locked: [String: SwiftPodsLock.Override], catalog: GitCatalog, into staging: URL
    ) throws -> [SwiftPodsLock.Override] {
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data(GeneratedPackageMetadata.overridesOwnership.utf8)
            .write(to: staging.appendingPathComponent(GeneratedPackageMetadata.overridesMarker))
        return try packages.compactMap { package in
            guard case .pinnedOverride(let url, let revision, let submodules) = package.location else { return nil }
            let directory = staging.appendingPathComponent(package.identity, isDirectory: true)
            do {
                let metadata = try catalog.exportPackageTree(url: url, revision: revision, submodules: submodules, into: directory)
                let record = SwiftPodsLock.Override(
                    identity: package.identity, url: url, revision: revision, submodules: submodules,
                    sha256: try overrideDigest(directory, metadataPaths: metadata), metadataPaths: metadata)
                if let previous = locked[package.identity], previous.matches(package) {
                    guard previous == record else {
                        throw SwiftPodsError("The exported tree does not match the digest recorded in SwiftPods.lock")
                    }
                    return previous
                }
                return record
            } catch {
                throw SwiftPodsError("Cannot install package override \(package.identity): \(error)", file: package.declaredAt.description)
            }
        }
    }

    private static func overrideDigest(_ directory: URL, metadataPaths: [String]) throws -> String {
        try FileTree.digest(
            of: directory, skippingTopLevel: GeneratedPackageMetadata.directories, keeping: Set(metadataPaths), validatingLinks: true)
    }

    /// Whether `SwiftPods/Overrides` holds exactly the recorded trees.
    private static func overridesMatch(_ records: [SwiftPodsLock.Override], in directory: URL) -> Bool {
        let children = Set(((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []))
        guard children == Set(records.map(\.identity) + [GeneratedPackageMetadata.overridesMarker]) else { return false }
        return records.allSatisfy { record in
            (try? overrideDigest(directory.appendingPathComponent(record.identity), metadataPaths: record.metadataPaths)) == record.sha256
        }
    }

    private func performInstall(_ options: InstallOptions) throws -> InstallReport {
        let workspaceLock = try WorkspaceLock(directory: directory)
        defer { withExtendedLifetime(workspaceLock) {} }
        let lockFile = lockFile
        // An ordinary install keeps recorded catalog revisions; --update-sources resolves them again. Deployment is
        // always frozen.
        let honorsExistingLock = options.deployment || !options.updateSources
        let lockProvider: @Sendable () throws -> SwiftPodsLock?
        if honorsExistingLock { lockProvider = { try SwiftPodsLock.read(at: lockFile) } } else { lockProvider = { nil } }
        let catalog = GitCatalog(
            cache: sourcesCache, runner: runner, update: options.updateSources, offline: options.offline,
            requiresLock: options.deployment, lockProvider: lockProvider)
        let manifest = try manifest(using: catalog)
        let usedOverrides = Set(manifest.targets.flatMap { $0.packageOverrides ?? [] })
        let overrides = manifest.packages.filter { usedOverrides.contains($0.identity) }
        let usesLock = !overrides.isEmpty || !catalog.resolutions.isEmpty
        let existingLockData = try? Data(contentsOf: lockFile)
        let existingLock: SwiftPodsLock? = usesLock && honorsExistingLock ? try SwiftPodsLock.read(at: lockFile) : nil
        if options.deployment && usesLock && existingLock == nil {
            throw SwiftPodsError("Deployment requires SwiftPods.lock", file: lockFile.path)
        }
        let lockedOverrides = Dictionary(uniqueKeysWithValues: (existingLock?.pinnedOverrides ?? []).map { ($0.identity, $0) })
        let matchingOverrides = overrides.compactMap { package in lockedOverrides[package.identity].flatMap {
            $0.matches(package) ? $0 : nil
        } }
        if options.deployment, let existingLock {
            var problems = existingLock.problems(comparedTo: SwiftPodsLock(resolutions: catalog.resolutions, overrides: matchingOverrides))
            if matchingOverrides.count != overrides.count {
                problems.append("Every package override requires a matching URL, commit and submodule option")
            }
            guard problems.isEmpty else {
                throw SwiftPodsError(
                    "SwiftPods.lock does not satisfy the Podfile:\n  " + problems.joined(separator: "\n  "), file: lockFile.path,
                    hint: "Review the changes and run swiftpods install without --deployment; add --update-sources only if catalog revisions must move")
            }
        }
        var defaultProjectPath: String?
        func selectedDefaultProject() throws -> String {
            if let defaultProjectPath { return defaultProjectPath }
            let path = try defaultProject()
            defaultProjectPath = path
            return path
        }
        var projectPaths: [String] = []
        var targetsByProject: [String: [Target]] = [:]
        for target in manifest.targets {
            let path = try target.project ?? selectedDefaultProject()
            if targetsByProject[path] == nil { projectPaths.append(path) }
            targetsByProject[path, default: []].append(target)
        }
        let packagesByProject = Dictionary(uniqueKeysWithValues: projectPaths.map { path in
            let used = Set(targetsByProject[path]!.flatMap { $0.products.map(\.package) + ($0.packageOverrides ?? []) })
            return (path, manifest.packages.filter { used.contains($0.identity) })
        })
        var projects = try loadProjects(projectPaths)
        let compileOnlyTargets = Dictionary(uniqueKeysWithValues: projectPaths.map { path in
            (path, Set(targetsByProject[path]!.filter { $0.products.contains { !$0.link } }.map(\.name)))
        })
        let packageModulesByTarget = Dictionary(uniqueKeysWithValues: projectPaths.map { path in
            let staticLibraries = Set(projects[path]!.nativeTargets.compactMap {
                $0.productType == "com.apple.product-type.library.static" ? $0.name : nil
            })
            let modules = Dictionary(uniqueKeysWithValues: targetsByProject[path]!.map { target in
                let names = staticLibraries.contains(target.name)
                    ? Array(Set(target.products.filter(\.link).map { DependencyPackage.moduleName($0.product) })).sorted()
                    : []
                return (target.name, names)
            })
            return (path, modules)
        })
        // Targets embedding a framework target from the Podfile also receive an embedding phase.
        let embedders = Dictionary(uniqueKeysWithValues: projectPaths.map { path in
            let names = Set(targetsByProject[path]!.map(\.name))
            return (path, ProjectIntegration.embeddingTargets(projects[path]!, of: names))
        })
        let applicationRuntimeSearchPaths = Dictionary(uniqueKeysWithValues: projectPaths.map { path in
            let project = projects[path]!
            let declaredPlatforms = Dictionary(uniqueKeysWithValues: targetsByProject[path]!.map { ($0.name, $0.platform) })
            var paths: [String: String] = [:]
            for target in project.nativeTargets {
                guard target.productType == "com.apple.product-type.application",
                    let platform = Self.platformName(of: target.name, declared: declaredPlatforms[target.name] ?? nil, in: project)
                else { continue }
                let frameworks = platform == .macos ? "@executable_path/../Frameworks" : "@executable_path/Frameworks"
                if paths[target.name] == nil { paths[target.name] = "$(inherited) " + frameworks }
            }
            return (path, paths)
        })

        // Deployment checks the committed pins before changing anything; Xcode validates the whole graph later.
        var frozenResolved: [String: Data] = [:]
        var notes: [String] = []
        for path in projectPaths {
            let project = projects[path]!
            let file = PackageResolved.location(project: project.path)
            let workspace = project.path.deletingPathExtension().appendingPathExtension("xcworkspace")
            if FileTree.isDirectory(workspace), !packagesByProject[path]!.isEmpty {
                notes.append(
                    "\(workspace.lastPathComponent) keeps its own Package.resolved; SwiftPods resolves and checks the one in "
                        + "\(project.path.lastPathComponent). Open and build the project, or remove the workspace")
            }
            guard options.deployment else { continue }
            let packages = packagesByProject[path]!
            let declaresRemote = packages.contains { if case .remote = $0.location { true } else { false } }
            let data = FileTree.exists(file) ? try Data(contentsOf: file) : nil
            if declaresRemote, data == nil {
                throw SwiftPodsError(
                    "Cannot read \(file.path)", file: file.path, hint: "Run `swiftpods install --resolve` and commit Package.resolved")
            }
            if let data {
                // A catalog that moved a name since Package.resolved was committed leaves that package without a pin.
                let problems = try PackageResolved(data: data, file: file).problems(for: packages)
                guard problems.isEmpty else {
                    throw SwiftPodsError(
                        "Package.resolved does not satisfy the Podfile:\n  " + problems.joined(separator: "\n  "), file: file.path,
                        hint: "Run `swiftpods install --resolve` and commit Package.resolved")
                }
            }
            frozenResolved[path] = data
        }

        let overridesName = GeneratedPackageMetadata.overridesDirectory
        if options.deployment && !overrides.isEmpty && !FileTree.isDirectory(generated) {
            throw SwiftPodsError(
                "Deployment requires the materialized package overrides", hint: "Run swiftpods install to restore SwiftPods/Overrides first")
        }
        let generatedRoot = try GeneratedRoot(generated, create: true)
        var report = InstallReport()
        var projectOriginals: [FileBackup] = []
        /// Package.resolved files this run let Xcode change, with their contents before and the first directory of their
        /// path that did not exist.
        var resolvedOriginals: [FileBackup] = []
        var lockBackup: FileBackup?
        do {
            let ownsOverrides = generatedRoot.ownsOverrides
            if options.deployment && ownsOverrides && overrides.isEmpty {
                throw SwiftPodsError(
                    "Deployment has a materialized override directory that the Podfile no longer uses",
                    hint: "Run swiftpods install to remove obsolete overrides")
            }
            if !overrides.isEmpty, !ownsOverrides, FileTree.exists(generated.appendingPathComponent(overridesName)) {
                throw SwiftPodsError("Refusing to replace an unowned SwiftPods/Overrides directory")
            }
            let overridesMatch = !overrides.isEmpty && matchingOverrides.count == overrides.count && ownsOverrides
                && Self.overridesMatch(matchingOverrides, in: generated.appendingPathComponent(overridesName))
            if options.deployment && !overrides.isEmpty && !overridesMatch {
                throw SwiftPodsError(
                    "Deployment package overrides do not match SwiftPods.lock",
                    hint: "Restore the locked tree with swiftpods install, or swiftpods install --offline with a warm cache")
            }
            var staged: [String] = []
            var obsolete: [String] = []
            let overrideRecords: [SwiftPodsLock.Override]
            if overrides.isEmpty {
                overrideRecords = []
                if ownsOverrides { obsolete.append(overridesName) }
            } else if overridesMatch {
                overrideRecords = matchingOverrides
            } else {
                overrideRecords = try Self.stageOverrides(
                    overrides, locked: lockedOverrides, catalog: catalog, into: generatedRoot.staged(overridesName))
                staged.append(overridesName)
            }
            let resolvedLock = SwiftPodsLock(resolutions: catalog.resolutions, overrides: overrideRecords)
            let lockContents: Data? = resolvedLock.isEmpty ? nil : (options.deployment ? existingLockData : try resolvedLock.data())

            /// Writes a folder of text files into staging, unless it already holds exactly these files.
            func stage(_ name: String, _ files: [String: String]) throws {
                let encoded = files.mapValues { Data($0.utf8) }
                guard try !Self.generatedTree(at: generated.appendingPathComponent(name), matches: encoded) else { return }
                let folder = generatedRoot.staged(name)
                for (relative, data) in encoded {
                    let file = folder.appendingPathComponent(relative)
                    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: file)
                }
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                staged.append(name)
            }
            func stem(_ path: String) -> String {
                Self.pathComponent(((path as NSString).lastPathComponent as NSString).deletingPathExtension)
            }
            func folder(_ name: String) -> String { Self.pathComponent(name) }
            let groupedProjects = Dictionary(grouping: projectPaths) { Self.fileSystemKey(stem($0)) }
            let projectFolders = Dictionary(uniqueKeysWithValues: projectPaths.map { path in
                let base = stem(path)
                let folder = groupedProjects[Self.fileSystemKey(base)]!.count == 1 ? base : base + "-" + Self.shortDigest(path)
                return (path, folder)
            })
            guard Set(projectFolders.values.map(Self.fileSystemKey)).count == projectFolders.count else {
                throw SwiftPodsError("Xcode project names produce colliding SwiftPods paths")
            }
            let targetNames = Dictionary(uniqueKeysWithValues: projectPaths.map { path in
                let names = targetsByProject[path]!.map(\.name) + embedders[path]!.filter {
                    embedder in !targetsByProject[path]!.contains { $0.name == embedder }
                }
                return (path, names)
            })
            let targetFolders = Dictionary(uniqueKeysWithValues: projectPaths.map { path in
                let names = targetNames[path]!
                let groups = Dictionary(grouping: names, by: Self.fileSystemKey)
                let folders = Dictionary(uniqueKeysWithValues: names.map { name in
                    let base = folder(name)
                    return (name, groups[Self.fileSystemKey(name)]!.count == 1 ? base : base + "-" + Self.shortDigest(name))
                })
                return (path, folders)
            })
            for (path, folders) in targetFolders {
                guard Set(folders.values.map(Self.fileSystemKey)).count == folders.count else {
                    throw SwiftPodsError("Targets in \(path) produce colliding SwiftPods paths")
                }
            }

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
            if usesBinaries {
                let store = BinaryStore(cache: cache, runner: runner, offline: options.offline)
                for binary in manifest.binaries {
                    let contents = try store.contents(binary, podfileDirectory: directory)
                    binaryEntries.append(BinaryPackage.Entry(
                        binary: binary, xcframeworks: contents.xcframeworks, resources: contents.resources,
                        xcframeworkPaths: contents.xcframeworkPaths, resourcePaths: contents.resourcePaths))
                }
                let package = try BinaryPackage(entries: binaryEntries, platforms: platforms)
                try package.validate()
                if !package.isInstalled(at: binaryDirectory) {
                    notes += try package.render(into: generatedRoot.staged(BinaryPackage.directoryName))
                    staged.append(BinaryPackage.directoryName)
                }
            } else if FileTree.exists(binaryDirectory) {
                obsolete.append(BinaryPackage.directoryName)
            }
            // Binary SDKs go through one generated package. Swift package products are attached directly to Xcode
            // targets below: a transitive dependency of a wrapper package is not visible to Objective-C/Objective-C++
            // compilation, even though Swift can import it.
            let dependencyDirectory = generated.appendingPathComponent(DependencyPackage.directoryName, isDirectory: true)
            let targetCounts = Dictionary(projectPaths.flatMap { path in targetsByProject[path]!.map { ($0.name, 1) } }, uniquingKeysWith: +)
            func productBase(_ target: Target, _ path: String) -> String {
                targetCounts[target.name]! > 1 ? projectFolders[path]! + "-" + target.name : target.name
            }
            var productSpecifications: [(name: String, dependencies: [(product: String, package: String)])] = []
            for path in projectPaths {
                for target in targetsByProject[path]! {
                    let linked = DependencyPackage.productName(productBase(target, path))
                    productSpecifications.append((
                        name: linked,
                        dependencies: target.binaries.map { ($0, BinaryPackage.directoryName) }))
                }
            }
            let productNames = productSpecifications.map(\.name)
            guard Set(productNames).count == productNames.count else {
                throw SwiftPodsError("Targets produce duplicate SwiftPods package products")
            }
            let moduleGroups = Dictionary(grouping: productNames) { Self.fileSystemKey(DependencyPackage.moduleName($0)) }
            let products = productSpecifications.map { specification in
                let base = DependencyPackage.moduleName(specification.name)
                let module = moduleGroups[Self.fileSystemKey(base)]!.count == 1 ? base : base + "_" + Self.shortDigest(specification.name)
                return DependencyPackage.Product(name: specification.name, module: module, dependencies: specification.dependencies)
            }
            guard Set(products.map { Self.fileSystemKey($0.module) }).count == products.count else {
                throw SwiftPodsError("Targets produce colliding Swift module names after disambiguation")
            }
            let dependencies = DependencyPackage(
                platforms: platforms,
                local: usesBinaries ? [Paths.relative(from: dependencyDirectory, to: binaryDirectory)] : [],
                products: products)
            try stage(DependencyPackage.directoryName, dependencies.files())

            // Build settings become one xcconfig per declared target. Application embedders outside the Podfile also get
            // the runtime search path required for frameworks copied into their bundle by the Finish phase.
            let settingsDirectory = generated.appendingPathComponent("Settings", isDirectory: true)
            var settingsFiles: [String: [String: URL]] = [:]
            var settingsTexts: [String: String] = [:]
            for path in projectPaths {
                let declared = Dictionary(uniqueKeysWithValues: targetsByProject[path]!.map { ($0.name, $0) })
                for name in targetNames[path]! {
                    let target = declared[name]
                    let runtimeSearchPaths = applicationRuntimeSearchPaths[path]?[name]
                    guard target != nil || runtimeSearchPaths != nil else { continue }
                    let file = settingsDirectory.appendingPathComponent(projectFolders[path]!)
                        .appendingPathComponent(targetFolders[path]![name]! + ".xcconfig")
                    settingsFiles[path, default: [:]][name] = file
                    settingsTexts[Paths.relative(from: settingsDirectory, to: file)] = Self.xcconfig(
                        target?.settings ?? [], runtimeSearchPaths: runtimeSearchPaths,
                        packageModuleBridge: !(packageModulesByTarget[path]?[name] ?? []).isEmpty,
                        compileOnlyPackages: compileOnlyTargets[path]!.contains(name))
                }
            }
            try stage("Settings", settingsTexts)

            // Script phases, binary resources and the check that the installation is current run from generated scripts.
            let scriptsDirectory = generated.appendingPathComponent(TargetScripts.directoryName, isDirectory: true)
            var scriptFiles: [String: String] = [:]
            var fileLists: [String: ScriptFileList?] = [:]
            var missingFileListUses: [String: (target: String, declaration: String, count: Int)] = [:]
            var fileListsByTarget: [String: [String: [String: [String]]]] = [:]
            // Script file lists are read now: their entries become the inputs and outputs of the generated phases.
            for path in projectPaths {
                let projectDirectory = projects[path]!.sourceRoot
                for target in targetsByProject[path]! {
                    var targetFileLists: [String: [String]] = [:]
                    for list in target.scriptPhases.flatMap({ $0.inputFileLists + $0.outputFileLists }) {
                        let resolved = list.replacingOccurrences(of: "$(SRCROOT)", with: projectDirectory.path)
                            .replacingOccurrences(of: "${SRCROOT}", with: projectDirectory.path)
                        let requested = resolved.hasPrefix("/")
                            ? URL(fileURLWithPath: resolved).standardizedFileURL
                            : projectDirectory.appendingPathComponent(resolved).standardizedFileURL
                        if fileLists[requested.path] == nil {
                            fileLists[requested.path] = try Self.readScriptFileList(requested, podfileDirectory: directory)
                        }
                        guard let fileList = fileLists[requested.path]! else {
                            if var use = missingFileListUses[requested.path] {
                                use.count += 1
                                missingFileListUses[requested.path] = use
                            } else {
                                missingFileListUses[requested.path] = (target.name, list, 1)
                            }
                            continue
                        }
                        targetFileLists[list] = fileList.entries
                    }
                    fileListsByTarget[path, default: [:]][target.name] = targetFileLists
                }
            }
            for (_, use) in missingFileListUses.sorted(by: { $0.key < $1.key }) {
                let repeated = use.count == 1 ? "" : " (referenced \(use.count) times across targets)"
                notes.append(
                    "\(use.target): file list \(use.declaration) is read when installing and was not found, "
                        + "so its files are not declared\(repeated)")
            }

            var freshnessFiles = manifest.files.map { file in
                (path: Paths.relative(from: directory, to: URL(fileURLWithPath: file.path)), contents: file.contents)
            }
            if let lockContents {
                freshnessFiles.append((path: SwiftPodsLock.fileName, contents: lockContents))
            }
            freshnessFiles.append(contentsOf: fileLists.values.compactMap { $0 }.sorted { $0.path < $1.path }.map { (path: $0.path, contents: $0.contents) })
            scriptFiles[TargetScripts.signatureFile] = freshnessFiles.map { file in
                let digest = SHA256.hash(data: file.contents).map { String(format: "%02x", $0) }.joined()
                return digest + "  " + file.path
            }.joined(separator: "\n") + "\n"
            let freshnessPaths = freshnessFiles.map(\.path)
            var scriptLocations: [String: [String: TargetScripts.Locations]] = [:]
            // Targets that embed a framework target of the Podfile embed its dynamic frameworks; they need not be in the Podfile.
            for path in projectPaths {
                let projectDirectory = projects[path]!.sourceRoot
                func locate(_ name: String) -> (URL, TargetScripts.Locations) {
                    let targetDirectory = scriptsDirectory.appendingPathComponent(projectFolders[path]!)
                        .appendingPathComponent(targetFolders[path]?[name] ?? folder(name))
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
                    let fileLists = fileListsByTarget[path]?[target.name] ?? [:]
                    let files = TargetScripts.files(
                        scripts: target.scriptPhases, resources: resources, embedsFrameworks: embedders[path]!.contains(target.name),
                        signed: freshnessPaths,
                        fileLists: fileLists, packageModules: packageModulesByTarget[path]?[target.name] ?? [],
                        compileOnlyPackages: compileOnlyTargets[path]!.contains(target.name), paths: locations)
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

            report.binaries = usesBinaries ? manifest.binaries.map(\.name) : []
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
                let targets = targetsByProject[path]!
                var packagesByIdentity: [String: ProjectPlan.PackageReference] = [:]
                var plan = ProjectPlan()
                plan.packages = [package]
                if usesBinaries {
                    // Xcode 26.2 also needs a folder reference for the binary package reached through the generated
                    // dependency container. Leaving that local package implicit can crash dependency-group updates.
                    let relative = Paths.relative(from: projectDirectory, to: binaryDirectory)
                    plan.packages.append(.init(key: "package:local:" + relative, object: [
                        "isa": "PBXFileReference", "lastKnownFileType": "wrapper",
                        "name": .string(BinaryPackage.directoryName), "path": .string(relative), "sourceTree": "SOURCE_ROOT",
                    ]))
                }
                for declared in packagesByProject[path]! {
                    switch declared.location {
                    case .remote(let url):
                        let key = "package:" + PackageLocation.canonical(url)
                        let reference = ProjectPlan.PackageReference(key: key, object: [
                            "isa": "XCRemoteSwiftPackageReference", "repositoryURL": .string(url),
                            "requirement": Self.requirement(declared.requirement!),
                        ])
                        packagesByIdentity[declared.identity] = reference
                        plan.packages.append(reference)
                    case .local, .pinnedOverride:
                        let declaredPath: String
                        switch declared.location {
                        case .local(let path): declaredPath = path
                        default: declaredPath = Self.generatedDirectory + "/" + overridesName + "/" + declared.identity
                        }
                        let relative = Paths.relative(
                            from: projectDirectory, to: directory.appendingPathComponent(declaredPath))
                        let key = "package:local:" + relative
                        let reference = ProjectPlan.PackageReference(key: key, object: [
                            "isa": "PBXFileReference", "lastKnownFileType": "wrapper",
                            "name": .string(declared.name), "path": .string(relative), "sourceTree": "SOURCE_ROOT",
                        ])
                        packagesByIdentity[declared.identity] = reference
                        plan.packages.append(reference)
                        plan.managedLocalProducts.formUnion(targets.flatMap { $0.products.filter { $0.package == declared.identity }.map(\.product) })
                    }
                }
                for target in targets {
                    let base = productBase(target, path)
                    let staticLibrary = project.nativeTargets.contains {
                        $0.name == target.name && $0.productType == "com.apple.product-type.library.static"
                    }
                    // An empty binary container has no code for a static archive. Keep its build dependency,
                    // avoiding libtool warnings about its empty object when all SDK uses are compile-only.
                    let linkContainer = !staticLibrary || !target.binaries.isEmpty
                        || (!target.products.isEmpty && !compileOnlyTargets[path]!.contains(target.name))
                    var products = [ProjectPlan.Product(package: package, name: DependencyPackage.productName(base), link: linkContainer)]
                    for product in target.products {
                        guard let dependencyPackage = packagesByIdentity[product.package] else {
                            throw SwiftPodsError("Target `\(target.name)` references unknown package `\(product.package)`")
                        }
                        products.append(.init(package: dependencyPackage, name: product.product, link: product.link))
                    }
                    plan.targets.append(.init(
                        name: target.name, products: products, phases: TargetScripts.Phase.allCases.map { phasePlan($0, target.name) },
                        settingsFile: Paths.relative(from: projectDirectory, to: settingsFiles[path]![target.name]!),
                        hasSettings: !target.settings.isEmpty || !(packageModulesByTarget[path]?[target.name] ?? []).isEmpty
                            || applicationRuntimeSearchPaths[path]?[target.name] != nil || compileOnlyTargets[path]!.contains(target.name)))
                }
                let declared = Set(targets.map(\.name))
                for name in embedders[path]! where !declared.contains(name) {
                    let settingsFile = settingsFiles[path]?[name].map { Paths.relative(from: projectDirectory, to: $0) }
                    plan.targets.append(.init(
                        name: name, products: [], phases: [phasePlan(.finish, name)],
                        settingsFile: settingsFile, hasSettings: settingsFile != nil))
                }
                let changes = try ProjectIntegration.apply(
                    plan, to: &project, adopt: options.adopt, migrateLegacyCrashlyticsPaths: true, notes: &report.notes)
                projects[path] = project
                report.projects.append(.init(project: path, changes: changes))
            }
            report.notes = notes + report.notes

            try Interruption.check()
            for name in staged {
                try Interruption.check()
                try generatedRoot.publish(name)
            }
            for name in obsolete {
                try Interruption.check()
                try generatedRoot.withdraw(name)
            }
            for path in projectPaths {
                try Interruption.check()
                let original = try Data(contentsOf: projects[path]!.file)
                if try projects[path]!.save() { projectOriginals.append(.init(file: projects[path]!.file, data: original)) }
            }

            if options.deployment {
                // Xcode knows the full graph, including local packages represented by ordinary file references.
                for path in projectPaths {
                    let before = frozenResolved[path]
                    let project = projects[path]!
                    let file = PackageResolved.location(project: project.path)
                    if before == nil {
                        resolvedOriginals.append(.init(file: file, data: nil, createdDirectory: Self.firstMissingResolvedDirectory(in: project.path)))
                    }
                    var resolverError: (any Error)?
                    do {
                        try resolvePackages(
                            [
                                "xcodebuild", "-resolvePackageDependencies", "-disableAutomaticPackageResolution",
                                "-onlyUsePackageVersionsFromResolvedFile", "-skipPackageUpdates",
                            ], project: project)
                    } catch {
                        resolverError = error
                    }
                    if FileTree.exists(file) != (before != nil) || (try? Data(contentsOf: file)) != before {
                        if let before { resolvedOriginals.append(.init(file: file, data: before)) }
                        throw SwiftPodsError(
                            "Xcode modified Package.resolved during frozen deployment validation",
                            file: file.path, hint: "Deployment validation must not update the committed Package.resolved")
                    }
                    if let resolverError { throw resolverError }
                }
            } else if options.resolve {
                for path in projectPaths {
                    let file = PackageResolved.location(project: projects[path]!.path)
                    let created = Self.firstMissingResolvedDirectory(in: projects[path]!.path)
                    let original = FileTree.exists(file) ? try Data(contentsOf: file) : nil
                    resolvedOriginals.append(.init(file: file, data: original, createdDirectory: created))
                    try resolvePackages(["xcodebuild", "-resolvePackageDependencies"], project: projects[path]!)
                    // SwiftPM writes no file when nothing has a remote pin.
                    guard FileManager.default.fileExists(atPath: file.path) else { continue }
                    let problems = try PackageResolved(contentsOf: file).problems(for: packagesByProject[path]!)
                    if !problems.isEmpty {
                        throw SwiftPodsError(
                            "Xcode resolved versions the Podfile does not allow:\n  " + problems.joined(separator: "\n  "), file: file.path)
                    }
                }
            }

            try Interruption.check()
            // The lock is optional for explicit-only Podfiles, created when absent and never required to be committed.
            if !options.deployment, let lockContents, lockContents != existingLockData {
                let original = FileTree.exists(lockFile) ? try Data(contentsOf: lockFile) : nil
                lockBackup = .init(file: lockFile, data: original)
                try FileTree.replace(lockFile, with: lockContents)
            }
            try Interruption.check()
        } catch {
            let backups = projectOriginals + resolvedOriginals + (lockBackup.map { [$0] } ?? [])
            let problems = Self.restore(backups) + generatedRoot.rollback()
            throw Self.rollbackError(error, problems: problems)
        }
        generatedRoot.finish()
        return report
    }

    /// Removes everything SwiftPods added to the projects and the generated directory; with `cocoapods`,
    /// also a CocoaPods or SwiftPods 0.1 integration.
    public func deintegrate(cocoapods: Bool = false) throws -> InstallReport {
        let workspaceLock = try WorkspaceLock(directory: directory)
        defer { withExtendedLifetime(workspaceLock) {} }
        // Projects named by the Podfile are found even when it cannot be read: their objects are recognized by
        // identifier, and leaving one integrated while `SwiftPods/` is removed would break its build.
        let entries = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        var paths = Set(entries.filter { $0.hasSuffix(".xcodeproj") })
        if entries.contains("Podfile") {
            do {
                // A catalog entry may be missing from the cache; the projects matter more than staying offline.
                let manifest = try (try? manifest(offline: true)) ?? manifest()
                paths.formUnion(manifest.targets.compactMap(\.project))
            } catch {
                guard project != nil else {
                    throw SwiftPodsError(
                        "Cannot read the Podfile to find every project to deintegrate: \(error)",
                        hint: "Fix the Podfile, or name the project with --project")
                }
            }
        }
        if let project { paths.insert(Paths.relative(from: directory, to: project)) }

        var report = InstallReport()
        var projects = try loadProjects(paths.sorted())
        var workspaces: [FileBackup] = []
        for path in paths.sorted() {
            var changes = try ProjectIntegration.apply(ProjectPlan(), to: &projects[path]!, adopt: false, notes: &report.notes)
            if cocoapods {
                changes += try CocoaPodsIntegration.remove(from: &projects[path]!)
            }
            report.projects.append(.init(project: path, changes: changes))
        }

        let generatedRoot = FileTree.exists(generated) ? try GeneratedRoot(generated, create: false) : nil
        var projectOriginals: [FileBackup] = []
        do {
            try Interruption.check()
            for name in Self.managedFolders where name != GeneratedPackageMetadata.overridesDirectory || generatedRoot?.ownsOverrides == true {
                try Interruption.check()
                try generatedRoot?.withdraw(name)
            }
            if cocoapods {
                for (index, path) in paths.sorted().enumerated() {
                    try Interruption.check()
                    let workspace = projects[path]!.path.deletingPathExtension().appendingPathExtension("xcworkspace")
                    if let original = try CocoaPodsIntegration.removePodsProject(fromWorkspace: workspace) {
                        workspaces.append(.init(file: workspace.appendingPathComponent("contents.xcworkspacedata"), data: original))
                        report.projects[index].changes.append(
                            ProjectChange(kind: .removed, subject: "Pods/Pods.xcodeproj from " + workspace.lastPathComponent))
                    }
                }
            }
            for path in paths.sorted() {
                try Interruption.check()
                let original = try Data(contentsOf: projects[path]!.file)
                if try projects[path]!.save() { projectOriginals.append(.init(file: projects[path]!.file, data: original)) }
            }
            try Interruption.check()
        } catch {
            let problems = Self.restore(workspaces + projectOriginals) + (generatedRoot?.rollback() ?? [])
            throw Self.rollbackError(SwiftPodsError.wrap(error), problems: problems)
        }
        generatedRoot?.finish(deintegrating: true)
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

    static func xcconfig(
        _ settings: [BuildSetting], runtimeSearchPaths: String? = nil, packageModuleBridge: Bool = false,
        compileOnlyPackages: Bool = false
    ) -> String {
        var lines = ["// Generated by SwiftPods from the Podfile. Do not edit."]
        if let runtimeSearchPaths {
            lines.append("LD_RUNPATH_SEARCH_PATHS = \(runtimeSearchPaths)")
        }
        // Xcode applies the last line that matches a configuration, so values for some configurations come after
        // the values for all of them.
        for setting in settings where setting.configurations == nil {
            lines.append("\(setting.key) = \(setting.value)")
        }
        for setting in settings {
            lines += (setting.configurations ?? []).map { "\(setting.key)[config=\($0)] = \(setting.value)" }
        }
        if packageModuleBridge || compileOnlyPackages {
            lines.append("HEADER_SEARCH_PATHS = $(inherited) \"\(TargetScripts.packageModuleSearchPath)\"")
        }
        if compileOnlyPackages {
            let arguments = TargetScripts.packageCompilerArguments
            lines.append("USE_RECURSIVE_SCRIPT_INPUTS_IN_SCRIPT_PHASES = YES")
            // Archive redirects OBJROOT below ArchiveIntermediates/<scheme>/IntermediateBuildFilesPath.
            // Resolve its shared PIF cache without assuming a DerivedData location or an ACTION value.
            lines.append("SWIFTPODS_PIF_CACHE_PREFIX_IntermediateBuildFilesPath = ../../../")
            lines.append("OTHER_CFLAGS = $(inherited) \(arguments)")
            lines.append("OTHER_CPLUSPLUSFLAGS = $(inherited) \(arguments)")
            lines.append("OTHER_SWIFT_FLAGS = $(inherited) -Xcc \(arguments)")
            // CONFIGURATION_BUILD_DIR can point at a static plugin's own library directory,
            // especially during archive. SwiftPM products remain in the shared build directory.
            let packageProducts = "$(BUILD_DIR)/$(CONFIGURATION)$(EFFECTIVE_PLATFORM_NAME)"
            lines.append("FRAMEWORK_SEARCH_PATHS = $(inherited) \"\(packageProducts)\" \"\(packageProducts)/PackageFrameworks\" \"$(BUILT_PRODUCTS_DIR)/PackageFrameworks\"")
            lines.append("SWIFT_INCLUDE_PATHS = $(inherited) \"\(packageProducts)\"")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The platform family controls the relative layout of an application's executable and Frameworks directory.
    private static func platformName(of target: String, declared: Platform?, in project: XcodeProject) -> PlatformName? {
        if let declared { return declared.name }
        var settings: [String: PBXValue] = [:]
        let owners = (project.nativeTargets.first { $0.name == target }.map { [$0.id] } ?? []) + [project.rootID]
        for owner in owners {
            for id in project.configurations(of: owner).values.sorted() {
                for (key, value) in project[id]?["buildSettings"]?.dictionary ?? [:] where settings[key] == nil {
                    settings[key] = value
                }
            }
        }
        let platforms: [(PlatformName, String, String)] = [
            (.ios, "iphoneos", "IPHONEOS_DEPLOYMENT_TARGET"), (.macos, "macosx", "MACOSX_DEPLOYMENT_TARGET"),
            (.tvos, "appletvos", "TVOS_DEPLOYMENT_TARGET"), (.watchos, "watchos", "WATCHOS_DEPLOYMENT_TARGET"),
            (.visionos, "xros", "XROS_DEPLOYMENT_TARGET"),
        ]
        if let sdk = settings["SDKROOT"]?.string, let platform = platforms.first(where: { $0.1 == sdk }) {
            return platform.0
        }
        return platforms.first(where: { settings[$0.2] != nil })?.0
    }
    /// Whether `directory` holds exactly the `expected` files by relative path. Hidden files, such as Xcode's
    /// `.swiftpm`, are not SwiftPods'. Any other file, such as a build product written into a generated package,
    /// makes the tree differ, so staging replaces it.
    private static func generatedTree(at directory: URL, matches expected: [String: Data]) throws -> Bool {
        guard FileTree.isDirectory(directory) else { return false }
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return false }
        var matched = 0
        for case let url as URL in enumerator {
            let type = try FileTree.status(url).st_mode & S_IFMT
            guard type != S_IFDIR else { continue }
            guard type == S_IFREG, let contents = expected[Paths.relative(from: directory, to: url)],
                (try? Data(contentsOf: url)) == contents
            else { return false }
            matched += 1
        }
        return matched == expected.count
    }

    private struct ScriptFileList {
        /// Relative to the Podfile directory when inside it, for the build-time Podfile check.
        let path: String
        let contents: Data
        let entries: [String]
    }

    /// A Podfile-declared `.xcfilelist`, or nil when it does not exist yet.
    private static func readScriptFileList(_ file: URL, podfileDirectory: URL) throws -> ScriptFileList? {
        let contents: Data
        do {
            contents = try Data(contentsOf: file)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        } catch {
            throw SwiftPodsError("Cannot read file list: \(error.localizedDescription)", file: file.path)
        }
        guard let text = String(data: contents, encoding: .utf8) else {
            throw SwiftPodsError("File list must be valid UTF-8", file: file.path)
        }
        let entries = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        let inside = file.path.hasPrefix(podfileDirectory.path + "/")
        return ScriptFileList(
            path: inside ? Paths.relative(from: podfileDirectory, to: file) : file.path, contents: contents, entries: entries)
    }

    /// A reversible, filesystem-safe component. Common ASCII names keep their existing spelling.
    private static func pathComponent(_ text: String) -> String {
        let text = text.precomposedStringWithCanonicalMapping
        if text.isEmpty { return "%00" }
        let safe = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_. ".utf8)
        let encoded = text.utf8.enumerated().map { index, byte in
            safe.contains(byte) && !(index == 0 && byte == 0x2E)
                ? String(UnicodeScalar(byte)) : String(format: "%%%02X", byte)
        }.joined()
        return encoded.isEmpty || encoded == "." || encoded == ".." ? text.utf8.map { String(format: "%%%02X", $0) }.joined() : encoded
    }

    private static func fileSystemKey(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.lowercased()
    }

    private static func shortDigest(_ text: String) -> String {
        SHA256.hash(data: Data(text.precomposedStringWithCanonicalMapping.utf8)).prefix(6)
            .map { String(format: "%02x", $0) }.joined()
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
}
