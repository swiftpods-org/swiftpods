import Dispatch
import Foundation
import XCTest

@testable import SwiftPodsCore

final class NativeProcessInputBoundaryTests: XCTestCase {
    private final class ConcurrentResults {
        let lock = NSLock()
        var outputs: [Int: ToolOutput] = [:]
        var errors: [String] = []
        func store(_ output: ToolOutput, at index: Int) {
            lock.lock()
            outputs[index] = output
            lock.unlock()
        }
        func store(_ error: Error) {
            lock.lock()
            errors.append(String(describing: error))
            lock.unlock()
        }
    }

    func testValidUnicodeWhitespaceAndEmptyArgumentsRemainExact() throws {
        let value = "q\u{301}\tvalue\nnext 'quoted'"
        let result = try ToolProcess.run("/usr/bin/printf", ["%s%s", value, ""])
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(String(decoding: result.output, as: UTF8.self), value)
    }

    func testProcessArgumentsCannotSilentlyTruncateAtNul() {
        XCTAssertThrowsError(try ToolProcess.run("/usr/bin/printf", ["%s", "before\0after"])) {
            XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-PROCESS-ARGUMENT")
        }
    }

    func testExecutableCannotSilentlyTruncateAtNul() {
        XCTAssertThrowsError(try ToolProcess.run("/usr/bin/printf\0ignored", ["%s", "value"])) {
            XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-PROCESS-ARGUMENT")
        }
    }

    func testEnvironmentCannotSilentlyTruncateAtNul() {
        for environment in [["FIELD": "before\0after"], ["FIELD\0ignored": "value"]] {
            XCTAssertThrowsError(try ToolProcess.run("/usr/bin/env", [], environment: environment)) {
                XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-PROCESS-ARGUMENT")
            }
        }
    }

    func testEnvironmentNamesCannotBecomeDifferentVariables() {
        for name in ["FIELD=SUFFIX", "FIELD=\u{301}Suffix", "="] {
            XCTAssertThrowsError(try ToolProcess.run("/usr/bin/env", [], environment: [name: "value"])) {
                XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-PROCESS-ARGUMENT")
            }
        }
    }

    func testEnvironmentNamesCannotBeEmpty() {
        XCTAssertThrowsError(try ToolProcess.run("/usr/bin/env", [], environment: ["": "value"])) {
            XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-PROCESS-ARGUMENT")
        }
    }

    func testEnvironmentPreservesValidUnicodeNamesAndLiteralValues() throws {
        for (name, value) in [
            ("\u{301}FIELD", "a=b\nnext"), ("SPACE NAME", ""), ("dash-name", "東京 🧩"),
            ("line\nname", "literal=value"),
        ] {
            let result = try ToolProcess.run("/usr/bin/printenv", [name], environment: [name: value])
            XCTAssertEqual(result.status, 0)
            XCTAssertEqual(String(decoding: result.output, as: UTF8.self), value + "\n")
        }
    }

    func testToolCallsExecuteConcurrentlyWithSeparateCapturedStreams() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let results = ConcurrentResults()
        let group = DispatchGroup()
        let script = """
            : > "$1/$2"
            attempt=0
            while test "$attempt" -lt 500; do
              if test -f "$1/0" && test -f "$1/1" && test -f "$1/2" && test -f "$1/3"; then
                printf 'out:%s' "$2"
                printf 'err:%s' "$2" >&2
                exit 0
              fi
              attempt=$((attempt + 1))
              /bin/sleep .01
            done
            exit 97
            """
        for index in 0..<4 {
            group.enter()
            Thread {
                defer { group.leave() }
                do {
                    let output = try ToolProcess.run(
                        "/bin/sh", ["-c", script, "fixture", directory.path, String(index)], environment: [:])
                    results.store(output, at: index)
                } catch {
                    results.store(error)
                }
            }.start()
        }
        group.wait()
        XCTAssertEqual(results.errors, [])
        XCTAssertEqual(results.outputs.count, 4)
        for index in 0..<4 {
            let output = try XCTUnwrap(results.outputs[index])
            XCTAssertEqual(output.status, 0)
            XCTAssertEqual(String(decoding: output.output, as: UTF8.self), "out:\(index)")
            XCTAssertEqual(String(decoding: output.error, as: UTF8.self), "err:\(index)")
        }
    }
}
