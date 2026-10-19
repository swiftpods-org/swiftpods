import Darwin
import Foundation
import XCTest

@testable import SwiftPodsCore

final class CLIInvocationTests: XCTestCase {
    func testGraphRefreshReachesRuntimeValidationBeforeReadingInstallationState() throws {
        for arguments in [["graph", "--refresh"], ["why", "Foo", "--refresh"]] {
            try withProject { root, project, environment in
                let before = try FileFingerprint.tree(root)
                let result = try invoke(arguments + ["--project-directory", project.path], environment)
                XCTAssertEqual(result.0, 1)
                XCTAssertEqual(diagnosticCode(result), "SP-RUNTIME-PROFILE")
                XCTAssertEqual(try FileFingerprint.tree(root), before)
            }
        }
    }

    func testRepositoryPushReachesEngineRuntimeValidation() throws {
        try withProject { root, project, environment in
            let before = try FileFingerprint.tree(root)
            let result = try invoke(["repo", "push", "local", "--project-directory", project.path], environment)
            XCTAssertEqual(result.0, 1)
            XCTAssertEqual(diagnosticCode(result), "SP-RUNTIME-PROFILE")
            XCTAssertEqual(try FileFingerprint.tree(root), before)
        }
    }

    func testEnvironmentListSortsReadableProfilesWithoutLoadingTheirRuntime() throws {
        try withProject { root, project, environment in
            let parent = project.appendingPathComponent(".swiftpods/environments")
            for name in ["Zulu", "Alpha", "broken"] {
                let profile = parent.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
                let content = name == "broken" ? Data("invalid".utf8) : try jsonData(["name": name])
                try content.write(to: profile.appendingPathComponent("profile.json"))
            }
            let before = try FileFingerprint.tree(root)
            for arguments in [["env"], ["env", "list"]] {
                let result = try invoke(arguments + ["--project-directory", project.path], environment)
                XCTAssertEqual(result.0, 0)
                let profiles = try XCTUnwrap(result.1["profiles"] as? [[String: Any]])
                XCTAssertEqual(profiles.compactMap { $0["name"] as? String }, ["Alpha", "Zulu"])
                XCTAssertEqual(try FileFingerprint.tree(root), before)
            }
        }
    }

    func testEnvironmentShimUsesSelectedExecutableWithoutModifyingProject() throws {
        try withProject { root, project, environment in
            let shimDirectory = root.appendingPathComponent("bin with spaces")
            let before = try FileFingerprint.tree(project)
            let result = try invoke(
                ["env", "shim", "--directory", shimDirectory.path, "--project-directory", project.path], environment)
            XCTAssertEqual(result.0, 0)
            XCTAssertEqual(result.1["status"] as? String, "created")
            XCTAssertEqual(result.1["path_modified"] as? Bool, false)
            let target = try FileManager.default.destinationOfSymbolicLink(
                atPath: shimDirectory.appendingPathComponent("pod").path)
            XCTAssertEqual(target, Bundle.main.executableURL?.resolvingSymlinksInPath().path)
            XCTAssertEqual(try FileFingerprint.tree(project), before)
        }
    }

    func testStaticInspectionRejectsInvalidOptionsWithoutProjectWrites() throws {
        let cases = [
            ["doctor", "--platform", "invalid"], ["doctor", "--variant", "invalid"],
            ["doctor", "--arch", "invalid"], ["doctor", "--unknown"], ["migrate"],
        ]
        for arguments in cases {
            try withProject { root, project, environment in
                let before = try FileFingerprint.tree(root)
                assertArgumentError(try invoke(arguments + ["--project-directory", project.path], environment))
                XCTAssertEqual(try FileFingerprint.tree(root), before)
            }
        }
    }

    func testRecoveryWithoutJournalDoesNotCreatePrivateState() throws {
        try withProject { root, project, _ in
            let before = try FileFingerprint.tree(root)
            XCTAssertThrowsError(try ProjectState(directory: project).recover()) {
                XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-RECOVER-NOT-NEEDED")
            }
            XCTAssertEqual(try FileFingerprint.tree(root), before)
        }
    }

    func testInvalidRecoveryArgumentsPreserveInterruptedInstallation() throws {
        for argument in ["--dry-run", "--unknown", "unexpected", "--", "-\u{301}unknown", ""] {
            try withProject { root, project, environment in
                try interruptedInstallation(project)
                let before = try FileFingerprint.tree(root)
                let result = try invoke(["recover", argument, "--project-directory", project.path], environment)
                assertArgumentError(result)
                XCTAssertEqual(try FileFingerprint.tree(root), before)
            }
        }
    }

    func testInvalidRecoveryArgumentsDoNotCreatePrivateState() throws {
        try withProject { root, project, environment in
            let before = try FileFingerprint.tree(root)
            assertArgumentError(try invoke(["recover", "--unknown", "--project-directory", project.path], environment))
            XCTAssertEqual(try FileFingerprint.tree(root), before)
        }
    }

    func testCacheVerificationRejectsUnknownArgumentsBeforeCreatingCache() throws {
        for argument in ["--unknown", "extra", "-\u{301}unknown"] {
            try withProject { root, project, environment in
                let before = try FileFingerprint.tree(root)
                assertArgumentError(
                    try invoke(["cache", "verify", argument, "--project-directory", project.path], environment))
                XCTAssertEqual(try FileFingerprint.tree(root), before)
            }
        }
    }

    func testVersionCommandsMatchTheReleaseProfile() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let profile = try readObject(root.appendingPathComponent("Profiles/baseline.json"))
        let version = try XCTUnwrap(profile["swiftpods_version"] as? String)
        XCTAssertEqual(CLI.version, version)
        for command in ["version", "--version"] {
            try withProject { _, project, environment in
                let result = try invoke([command, "--project-directory", project.path], environment)
                XCTAssertEqual(result.0, 0)
                XCTAssertEqual(result.1["swiftpods_version"] as? String, version)
            }
        }
    }

    func testVersionRejectsUnknownArguments() throws {
        for command in ["version", "--version"] {
            try withProject { _, project, environment in
                assertArgumentError(
                    try invoke([command, "--unknown", "--project-directory", project.path], environment))
            }
        }
    }

    func testRuntimeVerificationRejectsUnknownArgumentsBeforeRuntimeValidation() throws {
        try withProject { root, project, environment in
            let before = try FileFingerprint.tree(root)
            assertArgumentError(
                try invoke(["runtime", "verify", "--unknown", "--project-directory", project.path], environment))
            XCTAssertEqual(try FileFingerprint.tree(root), before)
        }
    }

    func testRepositoryListAcceptsProjectDirectoryInEveryPosition() throws {
        try assertDirectoryPositions(["repo", "list"])
    }

    func testCacheListAcceptsProjectDirectoryInEveryPosition() throws {
        try assertDirectoryPositions(["cache", "list"])
    }

    func testVersionAcceptsLeadingProjectDirectory() throws {
        try assertDirectoryPositions(["version"])
    }

    func testEnvironmentListAcceptsLeadingEnvironmentSelection() throws {
        try withProject { root, project, environment in
            let before = try FileFingerprint.tree(root)
            let result = try invoke(
                ["--environment", "fixture", "env", "--project-directory", project.path, "list"], environment)
            XCTAssertEqual(result.0, 0)
            XCTAssertEqual(result.1["profiles"] as? [[String: String]], [])
            XCTAssertEqual(try FileFingerprint.tree(root), before)
        }
    }

    func testRecoveryAcceptsLeadingProjectDirectoryAndRestoresOriginalFiles() throws {
        try withProject { _, project, environment in
            try interruptedInstallation(project)
            let result = try invoke(["--project-directory", project.path, "recover"], environment)
            XCTAssertEqual(result.0, 0)
            XCTAssertEqual(result.1["status"] as? String, "recovered")
            XCTAssertEqual(
                try String(contentsOf: project.appendingPathComponent("Podfile.lock"), encoding: .utf8), "original")
            XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent("Pods").path))
        }
    }

    private func assertDirectoryPositions(_ command: [String]) throws {
        for inline in [false, true] {
            for position in 0...command.count {
                try withProject { _, project, environment in
                    var arguments = command
                    arguments.insert(
                        contentsOf: inline
                            ? ["--project-directory=" + project.path] : ["--project-directory", project.path],
                        at: position)
                    let before = try FileFingerprint.tree(project)
                    XCTAssertEqual(try invoke(arguments, environment).0, 0, arguments.description)
                    XCTAssertEqual(try FileFingerprint.tree(project), before)
                }
            }
        }
    }

    private func interruptedInstallation(_ project: URL) throws {
        let lock = project.appendingPathComponent("Podfile.lock")
        try Data("original".utf8).write(to: lock)
        var state: ProjectState? = ProjectState(directory: project)
        try state?.acquire()
        try state?.begin(command: ["install"], profile: "fixture")
        try Data("failed".utf8).write(to: lock)
        try FileManager.default.createDirectory(
            at: project.appendingPathComponent("Pods"), withIntermediateDirectories: false)
        try state?.finish(result: HostResult(status: 1, events: []), command: ["install"], profile: "fixture")
        state = nil
    }

    private func assertArgumentError(
        _ result: (Int32, [String: Any]), file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(result.0, 1, file: file, line: line)
        XCTAssertEqual(diagnosticCode(result), "SP-CLI-ARGUMENT", file: file, line: line)
    }

    private func diagnosticCode(_ result: (Int32, [String: Any])) -> String? {
        (result.1["diagnostic"] as? [String: Any])?["code"] as? String
    }

    private func invoke(_ arguments: [String], _ environment: [String: String]) throws -> (Int32, [String: Any]) {
        fflush(stdout)
        let saved = dup(STDOUT_FILENO)
        guard saved >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let pipe = Pipe()
        defer {
            fflush(stdout)
            _ = dup2(saved, STDOUT_FILENO)
            close(saved)
            try? pipe.fileHandleForWriting.close()
            try? pipe.fileHandleForReading.close()
        }
        guard dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO) >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let status = CLI.run(arguments: arguments + ["--json"], environment: environment)
        fflush(stdout)
        _ = dup2(saved, STDOUT_FILENO)
        try pipe.fileHandleForWriting.close()
        let report =
            try JSONSerialization.jsonObject(with: pipe.fileHandleForReading.readDataToEndOfFile()) as? [String: Any]
        return (status, try XCTUnwrap(report))
    }

    private func withProject(_ body: (URL, URL, [String: String]) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("work")
        let runtime = root.appendingPathComponent("runtime")
        for path in [project, runtime] {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        }
        try jsonData(["schema_version": 1, "files": [String: [String: String]]()])
            .write(to: runtime.appendingPathComponent("compatibility.json"))
        try body(
            root, project,
            ["SWIFTPODS_BUNDLE": runtime.path, "SWIFTPODS_CACHE_ROOT": root.appendingPathComponent("cache").path])
    }
}
