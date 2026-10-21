import Foundation
import XCTest

@testable import SwiftPodsCore

final class ProjectStorageTests: XCTestCase {
    private func fixture(git: Bool = true) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if git {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(".git"), withIntermediateDirectories: false)
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root.resolvingSymlinksInPath()
    }

    private func project(_ name: String, root: URL) throws -> URL {
        let directory = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("target 'Demo' do\nend\n".utf8).write(to: directory.appendingPathComponent("Podfile"))
        try Data("original lock".utf8).write(to: directory.appendingPathComponent("Podfile.lock"))
        return directory
    }

    private func finish(_ state: ProjectState, status: Int32 = 0, name: String = "Demo") throws {
        let report: [String: Any] = ["kind": "installation", "name": name, "specs": []]
        try state.finish(result: HostResult(status: status, events: [report]), command: ["install"], profile: "test")
    }

    func testSiblingProjectsShareOneRootWithoutSharingLocksOrReports() throws {
        let root = try fixture()
        let first = try project("Apps/First/Game", root: root)
        let second = try project("Apps/Second/Game", root: root)
        let firstStorage = ProjectStorage(project: first)
        let secondStorage = ProjectStorage(project: second)
        XCTAssertEqual(firstStorage.root, root.appendingPathComponent(".swiftpods"))
        XCTAssertEqual(firstStorage.root, secondStorage.root)
        XCTAssertNotEqual(firstStorage.directory, secondStorage.directory)
        let firstState = ProjectState(directory: first)
        let secondState = ProjectState(directory: second)
        try firstState.acquire()
        try secondState.acquire()
        XCTAssertThrowsError(try ProjectState(directory: first).acquire()) {
            XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-STATE-BUSY")
        }
        try firstState.begin(command: ["install"], profile: "test")
        try secondState.begin(command: ["install"], profile: "test")
        try finish(firstState, name: "First")
        try finish(secondState, name: "Second")
        XCTAssertEqual(try firstState.graph()["name"] as? String, "First")
        XCTAssertEqual(try secondState.graph()["name"] as? String, "Second")
        let firstIntegrity = ArtifactIntegrity(project: first)
        let secondIntegrity = ArtifactIntegrity(project: second)
        _ = try firstIntegrity.record(report: firstState.graph())
        _ = try secondIntegrity.record(report: secondState.graph())
        XCTAssertNotEqual(firstIntegrity.path, secondIntegrity.path)
        XCTAssertEqual(try firstIntegrity.verify()["status"] as? String, "passed")
        for directory in [first, second] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(".swiftpods").path))
        }
    }

    func testWorktreesAndNestedRepositoriesUseTheirOwnRoot() throws {
        let root = try fixture()
        let nested = try project("Modules/Nested", root: root)
        // A linked Git worktree or submodule uses a .git file instead of a directory.
        try Data("gitdir: /unused-for-path-discovery\n".utf8).write(to: nested.appendingPathComponent(".git"))
        let child = try project("Apps/Game", root: nested)
        XCTAssertEqual(ProjectStorage(project: child).root, nested.appendingPathComponent(".swiftpods"))
        XCTAssertEqual(ProjectStorage(project: nested).directory, nested.appendingPathComponent(".swiftpods"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".swiftpods").path))
    }

    func testParallelProjectsCanCreateTheirSharedStateContainer() throws {
        let root = try fixture()
        let projects = try (0..<20).map { try project("Apps/Game-\($0)", root: root) }
        DispatchQueue.concurrentPerform(iterations: projects.count) { index in
            do {
                try ProjectStorage(project: projects[index]).prepare()
            } catch {
                XCTFail("Cannot prepare state for project \(index): \(error)")
            }
        }
        for project in projects {
            XCTAssertTrue(FileManager.default.fileExists(atPath: ProjectStorage(project: project).directory.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent(".swiftpods").path))
        }
    }

    func testStandaloneProjectsKeepTheirStateBesideThePodfile() throws {
        let root = try fixture(git: false)
        let child = try project("Standalone", root: root)
        let storage = ProjectStorage(project: child)
        XCTAssertEqual(storage.directory, child.appendingPathComponent(".swiftpods"))
        XCTAssertEqual(storage.file("state.json"), storage.directory.appendingPathComponent("state.json"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.directory.path))
        var state: ProjectState? = ProjectState(directory: child)
        try state?.acquire()
        try state?.begin(command: ["install"], profile: "test")
        try finish(XCTUnwrap(state))
        state = nil
        XCTAssertNoThrow(try ProjectState(directory: child).acquire())
    }

    func testRepositoryRelocationAndProjectAliasesKeepTheSameIdentity() throws {
        let root = try fixture()
        let child = try project("Apps/Game", root: root)
        let original = ProjectStorage(project: child)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Alias"), withDestinationURL: child)
        XCTAssertEqual(ProjectStorage(project: root.appendingPathComponent("Alias")).directory, original.directory)
        let moved = root.appendingPathComponent("Moved")
        try FileManager.default.createDirectory(
            at: moved.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let movedProject = try project("Apps/Game", root: moved)
        XCTAssertEqual(
            ProjectStorage(project: movedProject).directory.lastPathComponent, original.directory.lastPathComponent)
    }

    func testLegacyReportsRemainReadableAndMoveOnTheNextMutation() throws {
        let root = try fixture(git: false)
        let child = try project("Apps/Game", root: root)
        var oldState: ProjectState? = ProjectState(directory: child)
        try oldState?.acquire()
        try oldState?.begin(command: ["install"], profile: "test")
        try finish(XCTUnwrap(oldState))
        oldState = nil
        let legacy = child.appendingPathComponent(".swiftpods")
        let before = try Data(contentsOf: legacy.appendingPathComponent("installation.json"))
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".git"), withIntermediateDirectories: false)
        let state = ProjectState(directory: child)
        XCTAssertEqual(try state.graph()["name"] as? String, "Demo")
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))
        try state.acquire()
        let storage = ProjectStorage(project: child)
        XCTAssertEqual(try Data(contentsOf: storage.file("installation.json")), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: storage.directory.appendingPathComponent("backup").path))
    }

    func testRecoveryMigratesLegacyJournalAndRestoresCentralReports() throws {
        let root = try fixture(git: false)
        let child = try project("Apps/Game", root: root)
        let legacy = child.appendingPathComponent(".swiftpods")
        var state: ProjectState? = ProjectState(directory: child)
        try state?.acquire()
        try state?.begin(command: ["install"], profile: "test")
        try finish(XCTUnwrap(state))
        let report = try Data(contentsOf: legacy.appendingPathComponent("installation.json"))
        try state?.begin(command: ["install"], profile: "test")
        try Data("partial lock".utf8).write(to: child.appendingPathComponent("Podfile.lock"))
        try Data("partial report".utf8).write(to: legacy.appendingPathComponent("installation.json"))
        try finish(XCTUnwrap(state), status: 1)
        state = nil
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".git"), withIntermediateDirectories: false)
        let recovered = try ProjectState(directory: child).recover()
        XCTAssertEqual(recovered["status"] as? String, "recovered")
        XCTAssertEqual(
            try String(contentsOf: child.appendingPathComponent("Podfile.lock"), encoding: .utf8), "original lock")
        XCTAssertEqual(try Data(contentsOf: ProjectStorage(project: child).file("installation.json")), report)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
    }

    func testMigrationRespectsAnExistingLegacyProcessLock() throws {
        let root = try fixture(git: false)
        let child = try project("Apps/Game", root: root)
        var oldState: ProjectState? = ProjectState(directory: child)
        try oldState?.acquire()
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".git"), withIntermediateDirectories: false)
        XCTAssertThrowsError(try ProjectState(directory: child).acquire()) {
            XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-STATE-BUSY")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: child.appendingPathComponent(".swiftpods").path))
        oldState = nil
        let state = ProjectState(directory: child)
        XCTAssertNoThrow(try state.acquire())
        XCTAssertFalse(FileManager.default.fileExists(atPath: child.appendingPathComponent(".swiftpods").path))
    }

    func testMigrationNeverOverwritesAnExistingCentralState() throws {
        let root = try fixture()
        let child = try project("Apps/Game", root: root)
        let storage = ProjectStorage(project: child)
        try storage.prepare()
        try Data("central".utf8).write(to: storage.file("state.json"))
        let legacy = child.appendingPathComponent(".swiftpods")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: false)
        try Data("legacy".utf8).write(to: legacy.appendingPathComponent("state.json"))
        XCTAssertThrowsError(try ProjectState(directory: child).acquire()) {
            XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-STATE-MIGRATION")
        }
        XCTAssertEqual(try String(contentsOf: storage.file("state.json"), encoding: .utf8), "central")
        XCTAssertEqual(try String(contentsOf: legacy.appendingPathComponent("state.json"), encoding: .utf8), "legacy")
    }

    func testSymlinkedCentralDirectoriesCannotRedirectProjectState() throws {
        for component in 0..<3 {
            let root = try fixture()
            let child = try project("Apps/Game", root: root)
            let storage = ProjectStorage(project: child)
            let outside = root.appendingPathComponent("Outside")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
            let link = storage.directories[component]
            try FileManager.default.createDirectory(
                at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
            XCTAssertThrowsError(try ProjectState(directory: child).acquire()) {
                XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-STATE-PATH")
            }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
        }
    }
}
