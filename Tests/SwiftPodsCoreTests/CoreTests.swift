import XCTest
@testable import SwiftPodsCore

final class CoreTests: XCTestCase {
    func testTreeRejectsDanglingAndComposedEscapingLinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/tmp/swiftpods-outside-missing")
        XCTAssertThrowsError(try FileFingerprint.tree(root, requireContainedLinks: true))
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("alias").path, withDestinationPath: ".")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "alias/../outside-missing")
        XCTAssertThrowsError(try FileFingerprint.tree(root, requireContainedLinks: true))
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "inside-missing")
        XCTAssertNoThrow(try FileFingerprint.tree(root, requireContainedLinks: true))
    }

    func testFingerprintsAndProjectJournalIgnorePrivateVarAlias() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("Demo.xcodeproj"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("project".utf8).write(to: directory.appendingPathComponent("Demo.xcodeproj/project.pbxproj"))
        let path = directory.path.hasPrefix("/private/var/") ? String(directory.path.dropFirst(8)) : "/private" + directory.path
        let alias = URL(fileURLWithPath: path)
        XCTAssertEqual(try FileFingerprint.tree(directory), try FileFingerprint.tree(alias))
        let state = ProjectState(directory: alias)
        try state.acquire()
        try state.begin(command: ["install"], profile: "test")
        let journal = try readObject(alias.appendingPathComponent(".swiftpods/state.json"))["journal"] as? [[String: Any]]
        XCTAssertTrue(journal?.contains { $0["path"] as? String == "Demo.xcodeproj/project.pbxproj" } == true)
    }

    func testRecoveryCanResumeAfterOneFileWasAlreadyRestored() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let lock = directory.appendingPathComponent("Podfile.lock")
        try Data("original".utf8).write(to: lock)
        var command: ProjectState? = ProjectState(directory: directory)
        try command?.acquire()
        try command?.begin(command: ["install"], profile: "test")
        try Data("failed".utf8).write(to: lock)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("Pods"), withIntermediateDirectories: true)
        try command?.finish(result: HostResult(status: 1, events: []), command: ["install"], profile: "test")
        command = nil
        // Reproduce a stop between atomic file replacements.
        try FileManager.default.removeItem(at: lock)
        let state = try readObject(directory.appendingPathComponent(".swiftpods/state.json"))
        let entry = try XCTUnwrap((state["journal"] as? [[String: Any]])?.first { $0["path"] as? String == "Podfile.lock" })
        try FileManager.default.copyItem(at: directory.appendingPathComponent(".swiftpods/backup/" + (entry["backup"] as! String)), to: lock)
        _ = try ProjectState(directory: directory).recover()
        XCTAssertEqual(try String(contentsOf: lock, encoding: .utf8), "original")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Pods").path))
    }

    func testRecoveryDetectsPermissionOnlyUserEdits() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let lock = directory.appendingPathComponent("Podfile.lock")
        try Data("original".utf8).write(to: lock)
        var command: ProjectState? = ProjectState(directory: directory)
        try command?.acquire()
        try command?.begin(command: ["install"], profile: "test")
        try Data("failed".utf8).write(to: lock)
        try command?.finish(result: HostResult(status: 1, events: []), command: ["install"], profile: "test")
        command = nil
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: lock.path)
        XCTAssertThrowsError(try ProjectState(directory: directory).recover()) { error in
            XCTAssertEqual((error as? Diagnostic)?.code, "SP-RECOVER-CONFLICT")
        }
    }

    func testSecretsAndURLCredentialsAreRedacted() {
        let redactor = Redactor(environment: ["SDK_TOKEN": "super-secret-42", "PATH": "/bin"])
        XCTAssertEqual(redactor.scrub("failed super-secret-42 https://alice:pw@example.com/pod?token=xyz"),
                       "failed [REDACTED] https://[REDACTED]@example.com/pod?token=[REDACTED]")
    }

    func testWhyIncludesEveryTransitiveTargetChain() throws {
        let report: [String: Any] = ["specs": [
            ["name": "Adapter", "version": "2.0", "dependencies": [["name": "Core/Sub", "requirement": "~> 3.0"]]],
            ["name": "Other", "version": "1.0", "dependencies": [["name": "Core/Sub", "requirement": ">= 3.0"]]],
            ["name": "Core/Sub", "version": "3.1", "dependencies": []]],
            "targets": [["name": "Game", "platform": "iOS 15.0", "dependencies": [["name": "Adapter", "requirement": "= 2.0"]]],
                        ["name": "Tests", "dependencies": [["name": "Other", "requirement": ">= 0"]]]]]
        let result = try DependencyGraph.why("Core", report: report)
        let chains = try XCTUnwrap(result["dependency_chains"] as? [[String: Any]])
        XCTAssertEqual(chains.count, 2)
        XCTAssertEqual(chains[0]["requirements"] as? [String], ["= 2.0", "~> 3.0"])
        XCTAssertEqual((chains[0]["nodes"] as? [[String: Any]])?.compactMap { $0["name"] as? String }, ["Adapter", "Core/Sub"])
        XCTAssertThrowsError(try DependencyGraph.why("Missing", report: report))
    }

    func testGraphDetectsHelperAndEnvironmentChangesWithoutExecution() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent(".swiftpods"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = directory.appendingPathComponent("helper.rb")
        try Data("raise 'must not execute'".utf8).write(to: helper)
        let report: [String: Any] = ["inputs": ["files": [helper.path: digest(try Data(contentsOf: helper))],
                                               "environment": ["FEATURE": ["status": "tracked", "sha256": digest(Data("value:enabled".utf8))]]]]
        try jsonData(report).write(to: directory.appendingPathComponent(".swiftpods/installation.json"))
        try Data("changed helper".utf8).write(to: helper)
        let result = try ProjectState(directory: directory).graph(environment: ["FEATURE": "disabled"])
        XCTAssertEqual(result["freshness"] as? String, "stale")
        XCTAssertEqual(Set(result["changed_inputs"] as? [String] ?? []), [helper.path, "ENV[FEATURE]"])
    }

    func testRecoveryRestoresPreviousSPMOwnershipAfterPostprocessingFailure() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent(".swiftpods"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ownership = directory.appendingPathComponent(".swiftpods/spm.json")
        try Data("original ownership".utf8).write(to: ownership)
        var command: ProjectState? = ProjectState(directory: directory)
        try command?.acquire()
        try command?.begin(command: ["install"], profile: "test")
        try command?.finish(result: HostResult(status: 0, events: [["kind": "spm_state", "owned": ["new"]]]), command: ["install"], profile: "test")
        try command?.finish(result: HostResult(status: 125, events: []), command: ["install"], profile: "test")
        command = nil
        _ = try ProjectState(directory: directory).recover()
        XCTAssertEqual(try String(contentsOf: ownership, encoding: .utf8), "original ownership")
    }

    func testStaticInspectionDoesNotExecuteRuby() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("executed")
        try Data("File.write('\(marker.path)', 'oops')\nraise 'must not run'".utf8).write(to: directory.appendingPathComponent("Podfile"))
        let report = StaticInspection(directory: directory).report(bundle: nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(report["status"] as? String, "failed")
        let checks = try XCTUnwrap(report["checks"] as? [[String: String]])
        XCTAssertEqual(checks.first { $0["name"] == "ruby_evaluation" }?["status"], "unknown")
    }

    func testLockPreventsConcurrentMutationsAndTracksInterruptedCommand() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var first: ProjectState? = ProjectState(directory: directory)
        try first?.acquire()
        try first?.begin(command: ["install"], profile: "test")
        XCTAssertThrowsError(try ProjectState(directory: directory).acquire()) { error in
            XCTAssertEqual((error as? Diagnostic)?.code, "SP-STATE-BUSY")
        }
        first = nil
        XCTAssertThrowsError(try ProjectState(directory: directory).acquire()) { error in
            XCTAssertEqual((error as? Diagnostic)?.code, "SP-STATE-RECOVERY")
        }
    }

    func testRecoveryRestoresManagedFilesAndPreservesLocalSources() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let lock = directory.appendingPathComponent("Podfile.lock")
        let local = directory.appendingPathComponent("local.c")
        try Data("original lock".utf8).write(to: lock)
        var command: ProjectState? = ProjectState(directory: directory)
        try command?.acquire()
        try command?.begin(command: ["install"], profile: "test")
        try Data("failed lock".utf8).write(to: lock)
        try Data("hook changed local source".utf8).write(to: local)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("Pods"), withIntermediateDirectories: true)
        try command?.finish(result: HostResult(status: 1, events: []), command: ["install"], profile: "test")
        command = nil
        let report = try ProjectState(directory: directory).recover()
        XCTAssertEqual(report["status"] as? String, "recovered")
        XCTAssertEqual(try String(contentsOf: lock, encoding: .utf8), "original lock")
        XCTAssertEqual(try String(contentsOf: local, encoding: .utf8), "hook changed local source")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Pods").path))
    }

    func testRecoveryRefusesToOverwriteLaterUserEdits() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let lock = directory.appendingPathComponent("Podfile.lock")
        try Data("original".utf8).write(to: lock)
        var command: ProjectState? = ProjectState(directory: directory)
        try command?.acquire()
        try command?.begin(command: ["install"], profile: "test")
        try Data("failed".utf8).write(to: lock)
        try command?.finish(result: HostResult(status: 1, events: []), command: ["install"], profile: "test")
        command = nil
        try Data("user edit after failure".utf8).write(to: lock)
        XCTAssertThrowsError(try ProjectState(directory: directory).recover()) { error in
            XCTAssertEqual((error as? Diagnostic)?.code, "SP-RECOVER-CONFLICT")
        }
        XCTAssertEqual(try String(contentsOf: lock, encoding: .utf8), "user edit after failure")
    }
}
