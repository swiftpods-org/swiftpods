import Foundation
@testable import SwiftPodsKit
import XCTest

final class ProcessRunnerTests: XCTestCase {
    /// Git prints warnings and traces to standard error; callers parse standard output as data.
    func testStandardErrorIsOnlyPartOfAFailure() throws {
        let runner = ProcessRunner()
        XCTAssertEqual(try runner.runData("/bin/sh", ["-c", "printf out; printf warning >&2; printf more"], in: nil),
                       Data("outmore".utf8))
        XCTAssertThrowsError(try runner.run("/bin/sh", ["-c", "echo progress; echo 'fatal: failure' >&2; exit 3"], in: nil)) {
            let message = "\($0)"
            XCTAssertTrue(message.contains("exit 3"), message)
            XCTAssertTrue(message.contains("progress"), message)
            XCTAssertTrue(message.contains("fatal: failure"), message)
        }
    }

    func testAChattyStandardErrorDoesNotBlockTheCommand() throws {
        let output = try ProcessRunner(timeout: 20).runData(
            "/bin/sh", ["-c", "head -c 1000000 /dev/zero >&2; printf done"], in: nil)
        XCTAssertEqual(output, Data("done".utf8))
    }

    func testAnInterruptionStopsTheCommandsWholeGroupPromptly() throws {
        defer { Interruption.reset() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftPods-interrupt-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        // The leader ends on SIGTERM; a worker of its group ignores it.
        let script = #"""
            /bin/sh -c 'trap "" TERM; sleep 3; printf done > completed' &
            sleep 30
            """#
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { Interruption.record(SIGTERM) }
        let start = Date()
        XCTAssertThrowsError(try ProcessRunner().run("/bin/sh", ["-c", script], in: directory)) {
            XCTAssertTrue("\($0)".contains("Interrupted by SIGTERM"), "\($0)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        Thread.sleep(until: start.addingTimeInterval(4))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("completed").path))

        // Nothing starts once SwiftPods was interrupted.
        XCTAssertThrowsError(try ProcessRunner().run("/usr/bin/touch", ["started"], in: directory))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("started").path))
    }

    func testTimeoutStopsAWorkerAfterItsParentExits() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftPods-timeout-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        let script = #"""
            /bin/sh -c 'trap "" TERM; printf started > started; sleep 7; printf done > completed' &
            wait
            """#
        let start = Date()
        XCTAssertThrowsError(try ProcessRunner(timeout: 1).run("/bin/sh", ["-c", script], in: directory)) {
            XCTAssertTrue("\($0)".contains("timed out"), "\($0)")
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("started").path))
        Thread.sleep(until: start.addingTimeInterval(8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("completed").path))
    }

    // MARK: With a terminal

    func testATimeoutWithATerminalIsNotAnInterruption() throws {
        let run = try runInTerminal("timeout")
        XCTAssertTrue(run.result.contains("sleep 30 timed out after 1 seconds"), run.result)
    }

    func testCtrlCStopsSwiftPodsWhenTheCommandExitsSuccessfully() throws {
        let run = try runInTerminal("interrupt", sending: .key(0x03))
        XCTAssertTrue(run.result.contains("Interrupted by SIGINT"), run.result)
        XCTAssertEqual(run.childStatus, String(128 + SIGINT))
    }

    func testAnInterruptOfTheCommandLeavesTheCallingGroupRunning() throws {
        let run = try runInTerminal("interrupt", sending: .interruptCommand)
        XCTAssertTrue(run.result.contains("Interrupted by SIGINT"), run.result)
        XCTAssertEqual(run.childStatus, String(128 + SIGINT))
    }

    func testCtrlZThatTheCommandIgnoresKeepsItsResult() throws {
        let run = try runInTerminal("suspend", sending: .key(0x1A))
        XCTAssertEqual(run.result, "completed")
        XCTAssertEqual(run.childStatus, "0")
    }

    private static let terminalMode = "SWIFTPODS_TERMINAL_TEST"
    private static let terminalDirectory = "SWIFTPODS_TERMINAL_DIRECTORY"

    /// Started by the tests above inside the pseudo-terminal of `script(1)`, where SwiftPods hands the terminal to the
    /// command it runs. Writes the outcome to `result`.
    func testTerminalChild() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let mode = environment[Self.terminalMode], let path = environment[Self.terminalDirectory] else {
            throw XCTSkip("Runs inside the terminal tests")
        }
        let directory = URL(fileURLWithPath: path)
        Interruption.install()
        let result: String
        do {
            switch mode {
            case "timeout": _ = try ProcessRunner(timeout: 1).run("/bin/sleep", ["30"], in: directory)
            case "suspend": _ = try ProcessRunner().run("/bin/sh", ["-c", "trap '' TSTP; : > started; sleep 2"], in: directory)
            default:
                _ = try ProcessRunner().run("/bin/sh", ["-c", #"""
                    trap 'exit 0' INT
                    printf '%s' "$$" > command-pid
                    : > started
                    sleep 30
                    """#], in: directory)
            }
            result = "completed"
        } catch {
            result = "\(error)"
        }
        try Data(result.utf8).write(to: directory.appendingPathComponent("result"))
        Interruption.endIfReceived()
    }

    private enum TerminalInput { case key(UInt8), interruptCommand }

    /// Runs `testTerminalChild` from a Bash script in a pseudo-terminal and records the status seen by the script.
    private func runInTerminal(_ mode: String, sending event: TerminalInput? = nil) throws -> (result: String, childStatus: String?) {
        guard let xctest = try? ProcessRunner().run("/usr/bin/xcrun", ["--find", "xctest"], in: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        else {
            throw XCTSkip("Needs xctest from Xcode")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftPods-terminal-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("run.sh")
        try Data(#"""
            "$1" -XCTest "$2" "$3"
            printf '%s' "$?" > child-status
            """#.utf8).write(to: script)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = [
            "-q", "/dev/null", "/bin/bash", script.path, xctest,
            String(reflecting: Self.self) + "/testTerminalChild", Bundle(for: Self.self).bundlePath,
        ]
        var environment = ProcessInfo.processInfo.environment
        environment[Self.terminalMode] = mode
        environment[Self.terminalDirectory] = directory.path
        process.environment = environment
        process.currentDirectoryURL = directory
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }

        func file(_ name: String) -> URL { directory.appendingPathComponent(name) }
        func wait(_ seconds: TimeInterval, until condition: () -> Bool) -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while !condition() {
                guard Date() < end else { return false }
                Thread.sleep(forTimeInterval: 0.05)
            }
            return true
        }
        if let event {
            guard wait(30, until: { FileTree.exists(file("started")) }) else {
                throw SwiftPodsError("The command in the terminal did not start")
            }
            switch event {
            case .key(let key):
                input.fileHandleForWriting.write(Data([key]))
            case .interruptCommand:
                let command = try String(contentsOf: file("command-pid"), encoding: .utf8)
                guard let pid = pid_t(command), pid > 0, getpgid(pid) == pid,
                    getsid(pid) > 0, getsid(pid) != getsid(0), kill(-pid, SIGINT) == 0
                else { throw SwiftPodsError("Cannot interrupt the test command's group") }
            }
        }
        guard wait(30, until: { !process.isRunning }) else { throw SwiftPodsError("The terminal test did not finish") }
        let result = (try? String(contentsOf: file("result"), encoding: .utf8)) ?? "no result"
        return (result, try? String(contentsOf: file("child-status"), encoding: .utf8))
    }
}
