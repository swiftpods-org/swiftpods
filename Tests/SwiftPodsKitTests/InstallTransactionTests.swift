import Darwin
import Foundation
@testable import SwiftPodsKit
import SwiftPodsTestSupport
import XCTest

final class InstallTransactionTests: XCTestCase {
    private final class Runner: DescriptorWorkingDirectoryCommandRunner, @unchecked Sendable {
        private let handler: (String, [String], URL?) throws -> String

        init(_ handler: @escaping (String, [String], URL?) throws -> String = { _, _, _ in "" }) {
            self.handler = handler
        }

        func run(_ executable: String, _ arguments: [String], in directory: URL?) throws -> String {
            try handler(executable, arguments, directory)
        }

        func run(
            _ executable: String, _ arguments: [String], in directory: URL?, timeout: TimeInterval
        ) throws -> String {
            try run(executable, arguments, in: directory)
        }

        func runDescriptorBacked(
            _ executable: String, _ arguments: [String], workingDirectoryDescriptor: Int32,
            timeout: TimeInterval
        ) throws -> String {
            try run(executable, arguments, in: nil)
        }

        func runData(
            _ executable: String, _ arguments: [String], in directory: URL?, timeout: TimeInterval,
            maximumOutputBytes: Int
        ) throws -> Data {
            let result = Data(try run(executable, arguments, in: directory).utf8)
            guard result.count <= maximumOutputBytes else { throw SwiftPodsError("Test output exceeded its limit") }
            return result
        }
    }

    private var directories: [URL] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        super.tearDown()
    }

    private func fixture(_ podfile: String) throws -> URL {
        let directory = try Fixtures.directory(podfile: podfile)
        directories.append(directory)
        return directory
    }

    private func packageResolved(_ pins: String) -> Data {
        Data("{\"pins\":\(pins),\"version\":3}".utf8)
    }

    private func journalWorkspace() throws -> (directory: URL, generated: URL, staging: URL, projectFile: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "swiftpods-journal-tests-\(UUID().uuidString)", isDirectory: true)
        directories.append(directory)
        let generated = directory.appendingPathComponent("SwiftPods", isDirectory: true)
        let staging = generated.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        let project = directory.appendingPathComponent("App.xcodeproj", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(staging.path, 0o700), 0)
        try Data("SwiftPods generated staging v1\n".utf8)
            .write(to: staging.appendingPathComponent(".swiftpods-staging"))
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let projectFile = project.appendingPathComponent("project.pbxproj")
        try Data("original project\n".utf8).write(to: projectFile)
        return (directory, generated, staging, projectFile)
    }

    private func workspaceDescriptor(_ directory: URL) throws -> Int32 {
        let descriptor = directory.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else { throw CocoaError(.fileReadUnknown) }
        return descriptor
    }

    func testDeploymentRejectsAllowedPinAndTransitiveDriftBeforeXcode() throws {
        let directory = try fixture(
            "target 'App' do\n  spm 'https://github.com/example/Kit.git', branch: 'main'\nend\n")
        let project = directory.appendingPathComponent("App.xcodeproj", isDirectory: true)
        let resolved = PackageResolved.location(project: project)
        try FileManager.default.createDirectory(
            at: resolved.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = packageResolved(
            #"[{"identity":"kit","kind":"remoteSourceControl","location":"https://github.com/example/Kit.git","state":{"branch":"main","revision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}]"#)
        let drifted = packageResolved(
            #"[{"identity":"kit","kind":"remoteSourceControl","location":"https://github.com/example/Kit.git","state":{"branch":"main","revision":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}},{"identity":"transitive","kind":"remoteSourceControl","location":"https://github.com/example/Transitive.git","state":{"revision":"cccccccccccccccccccccccccccccccccccccccc","version":"1.0.0"}}]"#)
        try original.write(to: resolved)
        let invoked = NSLock()
        var xcodeWasInvoked = false
        let runner = Runner { executable, _, _ in
            if executable == "/usr/bin/xcrun" {
                invoked.lock()
                xcodeWasInvoked = true
                invoked.unlock()
            }
            return ""
        }
        let installer = Installer(
            directory: directory, runner: runner, cache: directory.appendingPathComponent(".cache"),
            generatedMutationHook: { point in
                guard point == .afterPublish("SwiftPodsDependencies") else { return }
                try! drifted.write(to: resolved, options: .atomic)
            })
        var options = InstallOptions()
        options.deployment = true

        XCTAssertThrowsError(try installer.install(options)) { error in
            XCTAssertTrue("\(error)".contains("changed after deployment validation"), "\(error)")
        }
        invoked.lock()
        let observedInvocation = xcodeWasInvoked
        invoked.unlock()
        XCTAssertFalse(observedInvocation)
        XCTAssertEqual(try Data(contentsOf: resolved), drifted)
    }

    func testFinalProjectCASPreservesConcurrentEditAfterChangedSave() throws {
        let directory = try fixture("target 'App' do\n  settings 'SWIFT_VERSION' => '5.10'\nend\n")
        let projectFile = directory.appendingPathComponent("App.xcodeproj/project.pbxproj")
        let resolved = PackageResolved.location(project: directory.appendingPathComponent("App.xcodeproj"))
        let concurrent = Data("concurrent project edit\n".utf8)
        let runner = Runner { executable, arguments, _ in
            guard executable == "/usr/bin/xcrun", arguments.first == "xcodebuild" else { return "" }
            try FileManager.default.createDirectory(
                at: resolved.deletingLastPathComponent(), withIntermediateDirectories: true)
            try self.packageResolved("[]").write(to: resolved)
            try concurrent.write(to: projectFile, options: .atomic)
            return ""
        }
        var options = InstallOptions()
        options.resolve = true

        XCTAssertThrowsError(try Installer(
            directory: directory, runner: runner, cache: directory.appendingPathComponent(".cache")
        ).install(options)) { error in
            XCTAssertTrue("\(error)".contains("rollback was incomplete"), "\(error)")
        }
        XCTAssertEqual(try Data(contentsOf: projectFile), concurrent)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(InstallTransactionJournal.directoryName).path))
    }

    func testFinalProjectCASCoversNoOpProjectSave() throws {
        let directory = try fixture("target 'App' do\nend\n")
        _ = try Installer(directory: directory, cache: directory.appendingPathComponent(".cache")).install(.init())
        let projectFile = directory.appendingPathComponent("App.xcodeproj/project.pbxproj")
        let resolved = PackageResolved.location(project: directory.appendingPathComponent("App.xcodeproj"))
        let concurrent = Data("concurrent no-op project edit\n".utf8)
        let runner = Runner { executable, arguments, _ in
            guard executable == "/usr/bin/xcrun", arguments.first == "xcodebuild" else { return "" }
            try FileManager.default.createDirectory(
                at: resolved.deletingLastPathComponent(), withIntermediateDirectories: true)
            try self.packageResolved("[]").write(to: resolved)
            try concurrent.write(to: projectFile, options: .atomic)
            return ""
        }
        var options = InstallOptions()
        options.resolve = true

        XCTAssertThrowsError(try Installer(
            directory: directory, runner: runner, cache: directory.appendingPathComponent(".cache")
        ).install(options)) { error in
            XCTAssertTrue("\(error)".contains("rollback was incomplete"), "\(error)")
        }
        XCTAssertEqual(try Data(contentsOf: projectFile), concurrent)
    }

    func testFinalPackageResolvedCASRejectsReplacement() throws {
        let directory = try fixture("target 'App' do\nend\n")
        let project = directory.appendingPathComponent("App.xcodeproj")
        let resolved = PackageResolved.location(project: project)
        try FileManager.default.createDirectory(
            at: resolved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try packageResolved("[]").write(to: resolved)
        let expected = try PackageResolved.snapshot(project: project)
        let replacement = packageResolved(
            #"[{"identity":"other","kind":"remoteSourceControl","location":"https://example.com/Other.git","state":{"revision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","version":"1.0.0"}}]"#)
        try replacement.write(to: resolved, options: .atomic)

        XCTAssertThrowsError(try PackageResolved.verifyUnchanged(expected, project: project)) { error in
            XCTAssertTrue("\(error)".contains("changed before transaction commit"), "\(error)")
        }
        XCTAssertEqual(try Data(contentsOf: resolved), replacement)
    }

    func testLateLockCleanupFailureIsRecoveredOnTheNextInstall() throws {
        let directory = try fixture("")
        let catalog = directory.appendingPathComponent("catalog", isDirectory: true)
        try FileManager.default.createDirectory(
            at: catalog.appendingPathComponent("Packages", isDirectory: true), withIntermediateDirectories: true)
        try "package 'Kit', git: 'https://example.com/Kit.git', products: ['Kit']\n"
            .write(to: catalog.appendingPathComponent("Packages/Kit.podfile"), atomically: true, encoding: .utf8)
        let shell = ProcessRunner()
        _ = try shell.run("/usr/bin/git", ["init", "-q"], in: catalog)
        _ = try shell.run("/usr/bin/git", ["add", "-A"], in: catalog)
        _ = try shell.run(
            "/usr/bin/git", ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "Kit"],
            in: catalog)
        try "source '\(catalog.path)'\ntarget 'App' do\n  spm 'Kit', exact: '1.0.0'\nend\n"
            .write(to: directory.appendingPathComponent("Podfile"), atomically: true, encoding: .utf8)
        let runner = Runner { executable, arguments, workingDirectory in
            if executable == "/usr/bin/xcrun" { return "" }
            return try shell.run(executable, arguments, in: workingDirectory)
        }
        let cache = directory.appendingPathComponent(".cache")
        let sources = directory.appendingPathComponent(".sources")
        _ = try Installer(directory: directory, runner: runner, cache: cache, sourcesCache: sources).install(.init())
        let lock = directory.appendingPathComponent(SwiftPodsLock.fileName)
        let originalLock = try Data(contentsOf: lock)

        let failing = Installer(
            directory: directory, runner: runner, cache: cache, sourcesCache: sources,
            generatedMutationHook: { _ in },
            lockWriteHook: { point in
                if point == .beforeCleanup { throw SwiftPodsError("simulated late lock cleanup failure") }
            })
        XCTAssertThrowsError(try failing.install(.init())) { error in
            XCTAssertTrue("\(error)".contains("commit boundary"), "\(error)")
        }
        XCTAssertEqual(try Data(contentsOf: lock), originalLock)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(InstallTransactionJournal.directoryName).path))

        _ = try Installer(directory: directory, runner: runner, cache: cache, sourcesCache: sources).install(.init())
        XCTAssertEqual(try Data(contentsOf: lock), originalLock)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(InstallTransactionJournal.directoryName).path))
    }

    func testConcurrentLockReplacementDoesNotMakeCommittingJournalRecoverAsCommitted() throws {
        let workspace = try journalWorkspace()
        let lockFile = workspace.directory.appendingPathComponent(SwiftPodsLock.fileName)
        let racedOriginal = workspace.directory.appendingPathComponent("raced-original.lock")
        let original = Data("{ \"catalogs\" : [ ], \"version\" : 1 }\n".utf8)
        try original.write(to: lockFile)
        let lock = try SwiftPodsLock(contentsOf: lockFile)
        let planned = try lock.data()
        let expected = try SwiftPodsLock.read(at: lockFile).state
        let concurrent: Data = {
            var value = original
            value.append(contentsOf: " \n".utf8)
            return value
        }()
        var journal: InstallTransactionJournal? = try InstallTransactionJournal.begin(
            directory: workspace.directory, workspaceDescriptor: workspaceDescriptor(workspace.directory),
            generatedRoot: workspace.generated, stagingName: workspace.staging.lastPathComponent,
            lockFile: lockFile, lockPolicy: .replace, plannedLock: planned)
        try journal!.prepareCommit()

        XCTAssertThrowsError(try lock.write(
            to: lockFile, replacing: expected,
            _temporaryName: journal!.lockTemporaryName,
            _cleanupDirectoryName: journal!.lockCleanupDirectoryName,
            _beforeReplacementSwap: {
                try FileManager.default.moveItem(at: lockFile, to: racedOriginal)
                try concurrent.write(to: lockFile)
            }
        )) { error in
            XCTAssertTrue("\(error)".contains("changed after it was read"), "\(error)")
        }
        XCTAssertEqual(try Data(contentsOf: lockFile), concurrent)
        XCTAssertEqual(try Data(contentsOf: racedOriginal), original)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: workspace.directory.path).contains {
            $0.hasPrefix(".SwiftPods.lock.tmp-")
        })
        journal = nil

        try InstallTransactionJournal.recover(
            directory: workspace.directory, workspaceDescriptor: workspaceDescriptor(workspace.directory))

        XCTAssertEqual(try Data(contentsOf: lockFile), concurrent)
        XCTAssertEqual(try Data(contentsOf: racedOriginal), original)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: workspace.directory.appendingPathComponent(InstallTransactionJournal.directoryName).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.staging.path))
    }

    func testActiveJournalRecoversProjectCrashBeforeConfirmation() throws {
        let workspace = try journalWorkspace()
        let original = try Data(contentsOf: workspace.projectFile)
        let desired = Data("installed project\n".utf8)
        let attributeName = "com.swiftpods.tests.journal-backup"
        let attribute = Data("preserve-journal-metadata".utf8)
        XCTAssertEqual(attribute.withUnsafeBytes {
            setxattr(workspace.projectFile.path, attributeName, $0.baseAddress, $0.count, 0, 0)
        }, 0)
        var journal: InstallTransactionJournal? = try InstallTransactionJournal.begin(
            directory: workspace.directory, workspaceDescriptor: workspaceDescriptor(workspace.directory),
            generatedRoot: workspace.generated, stagingName: workspace.staging.lastPathComponent,
            lockFile: workspace.directory.appendingPathComponent(SwiftPodsLock.fileName), plannedLock: nil)
        try journal!.prepareProject(file: workspace.projectFile, desired: desired)
        try desired.write(to: workspace.projectFile, options: .atomic)
        journal = nil

        try InstallTransactionJournal.recover(
            directory: workspace.directory, workspaceDescriptor: workspaceDescriptor(workspace.directory))

        XCTAssertEqual(try Data(contentsOf: workspace.projectFile), original)
        let restoredAttributeSize = getxattr(
            workspace.projectFile.path, attributeName, nil, 0, 0, 0)
        XCTAssertEqual(restoredAttributeSize, attribute.count)
        var restoredAttribute = Data(count: max(0, restoredAttributeSize))
        XCTAssertEqual(restoredAttribute.withUnsafeMutableBytes {
            getxattr(
                workspace.projectFile.path, attributeName, $0.baseAddress, $0.count, 0, 0)
        }, attribute.count)
        XCTAssertEqual(restoredAttribute, attribute)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: workspace.directory.appendingPathComponent(InstallTransactionJournal.directoryName).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.staging.path))
    }

    func testResolverMetadataSnapshotSurvivesCrashAndPreservesLaterEdits() throws {
        for editAfterConfirmation in [false, true] {
            let workspace = try journalWorkspace()
            let name = "SwiftPodsDependencies"
            let staged = workspace.staging.appendingPathComponent(name, isDirectory: true)
            let published = workspace.generated.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: false)
            try Data("managed package\n".utf8).write(to: staged.appendingPathComponent("Package.swift"))
            var journal: InstallTransactionJournal? = try InstallTransactionJournal.begin(
                directory: workspace.directory, workspaceDescriptor: workspaceDescriptor(workspace.directory),
                generatedRoot: workspace.generated, stagingName: workspace.staging.lastPathComponent,
                lockFile: workspace.directory.appendingPathComponent(SwiftPodsLock.fileName), plannedLock: nil)
            try journal!.prepareGenerated(.publish, name: name)
            try FileManager.default.moveItem(at: staged, to: published)
            try journal!.synchronizeGeneratedMutation()
            let metadata = published.appendingPathComponent(".swiftpm")
            try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: false)
            XCTAssertEqual(chmod(metadata.path, 0o775), 0)
            let state = metadata.appendingPathComponent("workspace-state.json")
            try Data("resolver state".utf8).write(to: state)
            try journal!.confirmResolverGeneratedMetadata()
            if editAfterConfirmation { try Data("keep concurrent edit".utf8).write(to: state) }
            journal = nil

            if editAfterConfirmation {
                XCTAssertThrowsError(try InstallTransactionJournal.recover(
                    directory: workspace.directory, workspaceDescriptor: workspaceDescriptor(workspace.directory)))
                XCTAssertEqual(try Data(contentsOf: state), Data("keep concurrent edit".utf8))
            } else {
                try InstallTransactionJournal.recover(
                    directory: workspace.directory, workspaceDescriptor: workspaceDescriptor(workspace.directory))
                XCTAssertFalse(FileManager.default.fileExists(atPath: published.path))
                XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.staging.path))
                XCTAssertFalse(FileManager.default.fileExists(
                    atPath: workspace.directory.appendingPathComponent(InstallTransactionJournal.directoryName).path))
            }
        }
    }

    func testRolledBackJournalCleansAStagedTreeReturnedByRename() throws {
        let workspace = try journalWorkspace()
        let name = "Generated"
        let staged = workspace.staging.appendingPathComponent(name, isDirectory: true)
        let published = workspace.generated.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: false)
        try Data("generated payload\n".utf8).write(to: staged.appendingPathComponent("payload"))
        let journal = try InstallTransactionJournal.begin(
            directory: workspace.directory, workspaceDescriptor: workspaceDescriptor(workspace.directory),
            generatedRoot: workspace.generated, stagingName: workspace.staging.lastPathComponent,
            lockFile: workspace.directory.appendingPathComponent(SwiftPodsLock.fileName), plannedLock: nil)
        try journal.prepareGenerated(.publish, name: name)
        try FileManager.default.moveItem(at: staged, to: published)
        try journal.synchronizeGeneratedMutation()

        // Model the normal in-process rollback: the exact published inode returns to staging, but its root ctime
        // advances on rename and must not be mistaken for unknown forensic evidence.
        try FileManager.default.moveItem(at: published, to: staged)
        try journal.finishRolledBack()

        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: workspace.directory.appendingPathComponent(InstallTransactionJournal.directoryName).path))
    }

    func testActiveJournalRecoversConfirmedPackageResolved() throws {
        let workspace = try journalWorkspace()
        let project = workspace.projectFile.deletingLastPathComponent()
        let resolved = PackageResolved.location(project: project)
        try FileManager.default.createDirectory(
            at: resolved.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = packageResolved("[]")
        let installed = packageResolved(
            #"[{"identity":"kit","kind":"remoteSourceControl","location":"https://example.com/Kit.git","state":{"revision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","version":"1.0.0"}}]"#)
        try original.write(to: resolved)
        let originalSnapshot = try PackageResolved.snapshot(project: project)
        var journal: InstallTransactionJournal? = try InstallTransactionJournal.begin(
            directory: workspace.directory, workspaceDescriptor: workspaceDescriptor(workspace.directory),
            generatedRoot: workspace.generated, stagingName: workspace.staging.lastPathComponent,
            lockFile: workspace.directory.appendingPathComponent(SwiftPodsLock.fileName), plannedLock: nil)
        try journal!.preparePackage(project: project, original: originalSnapshot)
        try installed.write(to: resolved, options: .atomic)
        let installedSnapshot = try PackageResolved.snapshot(project: project)
        try journal!.confirmPackage(project: project, installed: installedSnapshot)
        journal = nil

        try InstallTransactionJournal.recover(
            directory: workspace.directory, workspaceDescriptor: workspaceDescriptor(workspace.directory))

        XCTAssertEqual(try Data(contentsOf: resolved), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.staging.path))
    }

    func testCommittedJournalKeepsInstalledProjectAndFinishesCleanup() throws {
        let workspace = try journalWorkspace()
        let desired = Data("committed project\n".utf8)
        var journal: InstallTransactionJournal? = try InstallTransactionJournal.begin(
            directory: workspace.directory, workspaceDescriptor: workspaceDescriptor(workspace.directory),
            generatedRoot: workspace.generated, stagingName: workspace.staging.lastPathComponent,
            lockFile: workspace.directory.appendingPathComponent(SwiftPodsLock.fileName), plannedLock: nil)
        try journal!.prepareProject(file: workspace.projectFile, desired: desired)
        try desired.write(to: workspace.projectFile, options: .atomic)
        try journal!.confirmProject(file: workspace.projectFile)
        try journal!.markCommitted()
        journal = nil

        try InstallTransactionJournal.recover(
            directory: workspace.directory, workspaceDescriptor: workspaceDescriptor(workspace.directory))

        XCTAssertEqual(try Data(contentsOf: workspace.projectFile), desired)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: workspace.directory.appendingPathComponent(InstallTransactionJournal.directoryName).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.staging.path))
    }

    func testActiveJournalRefusesUnknownConcurrentProjectState() throws {
        let workspace = try journalWorkspace()
        let desired = Data("installed project\n".utf8)
        let concurrent = Data("concurrent project\n".utf8)
        var journal: InstallTransactionJournal? = try InstallTransactionJournal.begin(
            directory: workspace.directory, workspaceDescriptor: workspaceDescriptor(workspace.directory),
            generatedRoot: workspace.generated, stagingName: workspace.staging.lastPathComponent,
            lockFile: workspace.directory.appendingPathComponent(SwiftPodsLock.fileName), plannedLock: nil)
        try journal!.prepareProject(file: workspace.projectFile, desired: desired)
        try desired.write(to: workspace.projectFile, options: .atomic)
        try journal!.confirmProject(file: workspace.projectFile)
        try concurrent.write(to: workspace.projectFile, options: .atomic)
        journal = nil

        XCTAssertThrowsError(try InstallTransactionJournal.recover(
            directory: workspace.directory, workspaceDescriptor: workspaceDescriptor(workspace.directory)
        )) { error in
            XCTAssertTrue("\(error)".contains("unknown state"), "\(error)")
        }
        XCTAssertEqual(try Data(contentsOf: workspace.projectFile), concurrent)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: workspace.directory.appendingPathComponent(InstallTransactionJournal.directoryName).path))
    }

    func testCommittedJournalResumesPartiallyDeletedNestedStaging() throws {
        let workspace = try journalWorkspace()
        let tree = workspace.staging.appendingPathComponent("nested", isDirectory: true)
        let child = tree.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try Data("payload\n".utf8).write(to: child.appendingPathComponent("value.txt"))
        var journal: InstallTransactionJournal? = try InstallTransactionJournal.begin(
            directory: workspace.directory, workspaceDescriptor: workspaceDescriptor(workspace.directory),
            generatedRoot: workspace.generated, stagingName: workspace.staging.lastPathComponent,
            lockFile: workspace.directory.appendingPathComponent(SwiftPodsLock.fileName), plannedLock: nil)
        try journal!.markCommitted()

        XCTAssertThrowsError(try journal!.finishCommitted(_beforeStagingCleanup: {
            try FileManager.default.removeItem(at: child.appendingPathComponent("value.txt"))
            throw SwiftPodsError("simulated crash during staging cleanup")
        }))
        journal = nil

        try InstallTransactionJournal.recover(
            directory: workspace.directory, workspaceDescriptor: workspaceDescriptor(workspace.directory))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.staging.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: workspace.directory.appendingPathComponent(InstallTransactionJournal.directoryName).path))
    }

    func testActiveJournalResumesMissingOriginalPackageSuffixRemoval() throws {
        let workspace = try journalWorkspace()
        let project = workspace.projectFile.deletingLastPathComponent()
        let resolved = PackageResolved.location(project: project)
        let original = try PackageResolved.currentSnapshot(project: project)
        var journal: InstallTransactionJournal? = try InstallTransactionJournal.begin(
            directory: workspace.directory, workspaceDescriptor: workspaceDescriptor(workspace.directory),
            generatedRoot: workspace.generated, stagingName: workspace.staging.lastPathComponent,
            lockFile: workspace.directory.appendingPathComponent(SwiftPodsLock.fileName), plannedLock: nil)
        try journal!.preparePackage(project: project, original: original)
        try FileManager.default.createDirectory(
            at: resolved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try packageResolved("[]").write(to: resolved)
        try journal!.confirmPackage(project: project, installed: PackageResolved.snapshot(project: project))
        journal = nil

        XCTAssertThrowsError(try InstallTransactionJournal.recover(
            directory: workspace.directory, workspaceDescriptor: workspaceDescriptor(workspace.directory),
            _packageRecoveryHook: { project, recoveryID in
                let file = PackageResolved.location(project: project)
                let residue = file.deletingLastPathComponent().appendingPathComponent(
                    ".Package.resolved.swiftpods-journal-removed-\(recoveryID)")
                try FileManager.default.moveItem(at: file, to: residue)
                throw SwiftPodsError("simulated crash after Package.resolved removal rename")
            }
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: resolved.path))

        try InstallTransactionJournal.recover(
            directory: workspace.directory, workspaceDescriptor: workspaceDescriptor(workspace.directory))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: project.appendingPathComponent("project.xcworkspace").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: workspace.directory.appendingPathComponent(InstallTransactionJournal.directoryName).path))
    }

    func testRecoveryPromotesOnlyItsExactOrphanJournalUpdate() throws {
        let workspace = try journalWorkspace()
        _ = try InstallTransactionJournal.begin(
            directory: workspace.directory, workspaceDescriptor: workspaceDescriptor(workspace.directory),
            generatedRoot: workspace.generated, stagingName: workspace.staging.lastPathComponent,
            lockFile: workspace.directory.appendingPathComponent(SwiftPodsLock.fileName), plannedLock: nil)
        let journalDirectory = workspace.directory.appendingPathComponent(
            InstallTransactionJournal.directoryName, isDirectory: true)
        let manifest = journalDirectory.appendingPathComponent("journal.json")
        let data = try Data(contentsOf: manifest)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let transactionID = try XCTUnwrap(object["transactionID"] as? String)
        let update = journalDirectory.appendingPathComponent(".journal-\(transactionID)")
        try data.write(to: update)

        try InstallTransactionJournal.recover(
            directory: workspace.directory, workspaceDescriptor: workspaceDescriptor(workspace.directory))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.staging.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalDirectory.path))
    }

    func testTransactionManifestParserBudgetCoversItsStructuralTreeLimit() throws {
        let workspace = try journalWorkspace()
        _ = try InstallTransactionJournal.begin(
            directory: workspace.directory, workspaceDescriptor: workspaceDescriptor(workspace.directory),
            generatedRoot: workspace.generated, stagingName: workspace.staging.lastPathComponent,
            lockFile: workspace.directory.appendingPathComponent(SwiftPodsLock.fileName), plannedLock: nil)
        let manifest = workspace.directory.appendingPathComponent(
            InstallTransactionJournal.directoryName, isDirectory: true
        ).appendingPathComponent("journal.json")
        var root = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        let initial = try XCTUnwrap(root["initialStaging"] as? [String: Any])
        let seedTree = try XCTUnwrap(initial.values.first as? [String: Any])
        let seedMembers = try XCTUnwrap(seedTree["members"] as? [String: Any])
        let seedMember = try XCTUnwrap(seedMembers.values.first)
        var members: [String: Any] = ["": seedMember]
        for index in 0..<18_000 {
            members[String(format: "f%05d", index)] = seedMember
        }
        let largeTree: [String: Any] = ["members": members]
        root["initialStaging"] = ["bulk": largeTree]
        // The same authenticated tree can legitimately occur in the initial snapshot and a mutation record. This
        // crosses the generic 500k-value JSON budget while remaining far below transaction structural limits.
        root["generated"] = [["kind": "withdraw", "name": "bulk", "rootBefore": largeTree]]
        let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])

        XCTAssertThrowsError(try StrictJSONKeyValidator.validate(
            data, maximumStringBytes: data.count, maximumAggregateStringBytes: data.count))
        XCTAssertNoThrow(try InstallTransactionJournal.validateEncodedManifestForTesting(data))
    }

    func testTransactionManifestRejectsOversizedPathComponentBeforeRecovery() throws {
        let workspace = try journalWorkspace()
        _ = try InstallTransactionJournal.begin(
            directory: workspace.directory, workspaceDescriptor: workspaceDescriptor(workspace.directory),
            generatedRoot: workspace.generated, stagingName: workspace.staging.lastPathComponent,
            lockFile: workspace.directory.appendingPathComponent(SwiftPodsLock.fileName), plannedLock: nil)
        let manifest = workspace.directory.appendingPathComponent(
            InstallTransactionJournal.directoryName, isDirectory: true
        ).appendingPathComponent("journal.json")
        var root = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        root["generatedRootName"] = String(repeating: "a", count: 256)
        let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])

        XCTAssertThrowsError(try InstallTransactionJournal.validateEncodedManifestForTesting(data)) { error in
            XCTAssertTrue("\(error)".contains("Unsafe transaction journal path component"), "\(error)")
        }
    }

    func testTransactionManifestRejectsUnknownFieldBeforeInspectingHugeValue() throws {
        var data = Data(#"{"unexpected":""#.utf8)
        data.append(Data(repeating: 0x61, count: 8 * 1_024 * 1_024))
        data.append(Data(#""}"#.utf8))

        XCTAssertThrowsError(try InstallTransactionJournal.validateEncodedManifestForTesting(
            data, maximumPreflightBytes: 128
        )) { error in
            XCTAssertTrue("\(error)".contains("unexpected field"), "\(error)")
            XCTAssertFalse("\(error)".contains("inspection budget"), "\(error)")
        }
    }

    func testTransactionManifestRejectsHugeKnownScalarBeforeFoundationDecode() throws {
        var data = Data(#"{"schema":"#.utf8)
        data.append(Data(repeating: 0x31, count: 8 * 1_024 * 1_024))
        data.append(Data("}".utf8))

        XCTAssertThrowsError(try InstallTransactionJournal.validateEncodedManifestForTesting(
            data, maximumPreflightBytes: 256
        )) { error in
            XCTAssertTrue("\(error)".contains("oversized number"), "\(error)")
            XCTAssertFalse("\(error)".contains("inspection budget"), "\(error)")
        }
    }

    func testImmutableGeneratedStagingFailsBeforeJournalCreation() throws {
        let workspace = try journalWorkspace()
        let marker = workspace.staging.appendingPathComponent(".swiftpods-staging")
        guard marker.path.withCString({ chflags($0, UInt32(UF_IMMUTABLE)) }) == 0 else {
            throw XCTSkip("The test filesystem does not support UF_IMMUTABLE")
        }
        defer { _ = marker.path.withCString { chflags($0, 0) } }

        XCTAssertThrowsError(try InstallTransactionJournal.begin(
            directory: workspace.directory, workspaceDescriptor: workspaceDescriptor(workspace.directory),
            generatedRoot: workspace.generated, stagingName: workspace.staging.lastPathComponent,
            lockFile: workspace.directory.appendingPathComponent(SwiftPodsLock.fileName), plannedLock: nil
        )) { error in
            XCTAssertTrue("\(error)".contains("immutable, append-only, or no-unlink"), "\(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: workspace.directory.appendingPathComponent(InstallTransactionJournal.directoryName).path))
    }

    func testImmutableProjectIsRejectedBeforeManifestMutation() throws {
        let workspace = try journalWorkspace()
        var journal: InstallTransactionJournal? = try InstallTransactionJournal.begin(
            directory: workspace.directory, workspaceDescriptor: workspaceDescriptor(workspace.directory),
            generatedRoot: workspace.generated, stagingName: workspace.staging.lastPathComponent,
            lockFile: workspace.directory.appendingPathComponent(SwiftPodsLock.fileName), plannedLock: nil)
        let manifest = workspace.directory.appendingPathComponent(
            InstallTransactionJournal.directoryName, isDirectory: true
        ).appendingPathComponent("journal.json")
        let before = try Data(contentsOf: manifest)
        guard workspace.projectFile.path.withCString({ chflags($0, UInt32(UF_IMMUTABLE)) }) == 0 else {
            journal = nil
            throw XCTSkip("The test filesystem does not support UF_IMMUTABLE")
        }
        defer { _ = workspace.projectFile.path.withCString { chflags($0, 0) } }

        XCTAssertThrowsError(try journal!.prepareProject(
            file: workspace.projectFile, desired: Data("changed\n".utf8)
        )) { error in
            XCTAssertTrue("\(error)".contains("immutable, append-only, or no-unlink"), "\(error)")
        }
        XCTAssertEqual(try Data(contentsOf: manifest), before)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                atPath: manifest.deletingLastPathComponent().path).sorted(),
            ["journal.json"])
        XCTAssertEqual(workspace.projectFile.path.withCString({ chflags($0, 0) }), 0)
        journal = nil
        try InstallTransactionJournal.recover(
            directory: workspace.directory, workspaceDescriptor: workspaceDescriptor(workspace.directory))
    }

    func testOpenJournalDetectsPathnameReplacementBeforeWorkspaceMutation() throws {
        let workspace = try journalWorkspace()
        var journal: InstallTransactionJournal? = try InstallTransactionJournal.begin(
            directory: workspace.directory, workspaceDescriptor: workspaceDescriptor(workspace.directory),
            generatedRoot: workspace.generated, stagingName: workspace.staging.lastPathComponent,
            lockFile: workspace.directory.appendingPathComponent(SwiftPodsLock.fileName), plannedLock: nil)
        let originalProject = try Data(contentsOf: workspace.projectFile)
        let journalPath = workspace.directory.appendingPathComponent(InstallTransactionJournal.directoryName)
        let movedPath = workspace.directory.appendingPathComponent(".swiftpods-transaction-moved")
        try FileManager.default.moveItem(at: journalPath, to: movedPath)
        try FileManager.default.createDirectory(at: journalPath, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(journalPath.path, 0o700), 0)

        XCTAssertThrowsError(try journal!.prepareProject(
            file: workspace.projectFile, desired: Data("changed\n".utf8)
        )) { error in
            XCTAssertTrue("\(error)".contains("journal pathname changed"), "\(error)")
        }
        XCTAssertEqual(try Data(contentsOf: workspace.projectFile), originalProject)

        try FileManager.default.removeItem(at: journalPath)
        try FileManager.default.moveItem(at: movedPath, to: journalPath)
        try journal!.markCommitted()
        try FileManager.default.moveItem(at: journalPath, to: movedPath)
        try FileManager.default.createDirectory(at: journalPath, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(journalPath.path, 0o700), 0)
        XCTAssertThrowsError(try journal!.finishCommitted()) { error in
            XCTAssertTrue("\(error)".contains("journal pathname changed"), "\(error)")
        }
        try FileManager.default.removeItem(at: journalPath)
        try FileManager.default.moveItem(at: movedPath, to: journalPath)
        journal = nil
        try InstallTransactionJournal.recover(
            directory: workspace.directory, workspaceDescriptor: workspaceDescriptor(workspace.directory))
    }

    func testRecoveryDescriptorDuplicatesPreserveIdentityAndCloseOnExec() throws {
        let source = open("/dev/null", O_RDONLY | O_CLOEXEC)
        guard source >= 0 else { throw CocoaError(.fileReadUnknown) }
        defer { close(source) }
        let duplicate = duplicateCloseOnExec(source, minimum: 200)
        guard duplicate >= 0 else { throw CocoaError(.fileReadUnknown) }
        defer { close(duplicate) }

        var sourceStatus = stat()
        var duplicateStatus = stat()
        XCTAssertEqual(fstat(source, &sourceStatus), 0)
        XCTAssertEqual(fstat(duplicate, &duplicateStatus), 0)
        XCTAssertEqual(sourceStatus.st_dev, duplicateStatus.st_dev)
        XCTAssertEqual(sourceStatus.st_ino, duplicateStatus.st_ino)
        let descriptorFlags = fcntl(duplicate, F_GETFD)
        XCTAssertGreaterThanOrEqual(descriptorFlags, 0)
        XCTAssertNotEqual(descriptorFlags & FD_CLOEXEC, 0)
        XCTAssertLessThan(duplicateCloseOnExec(-1), 0)
    }
}
