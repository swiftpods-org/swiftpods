import Foundation
import XCTest

@testable import SwiftPodsCore

final class NativeCommandAndLockTests: XCTestCase {
    func testEmptyCommandReturnsDiagnosticInsteadOfCrashing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try jsonData(["schema_version": 1, "files": [String: [String: String]]()])
            .write(to: root.appendingPathComponent("compatibility.json"))
        let bundle = try RuntimeBundle(root: root)
        let result = NativeEngine(bundle: bundle).run(arguments: [], environment: [:], machine: true)
        XCTAssertEqual(result.status, 1)
        XCTAssertEqual(
            result.events.first { $0["kind"] as? String == "diagnostic" }?["code"] as? String, "SP-CLI-ARGUMENT")
        XCTAssertEqual(result.events.last?["kind"] as? String, "completed")
    }

    func testLockUnlocksAllConflictingTargetRequirementsRegardlessOfOrder() throws {
        try withLock("PODS:\n  - Kit (1.0)\nDEPENDENCIES:\n  - Kit\n") { lock in
            let compatible = try NativeDependency(["name": "Kit", "requirements": [">= 0"]])
            let changed = try NativeDependency(["name": "Kit", "requirements": [">= 2"]])
            XCTAssertEqual(try lock.changedRoots([compatible, changed]), ["Kit"])
            XCTAssertEqual(try lock.changedRoots([changed, compatible]), ["Kit"])
            XCTAssertEqual(try lock.changedRoots([compatible, compatible]), [])
        }
    }

    func testDuplicateCheckoutSourceAliasesProduceDiagnosticInsteadOfTrapping() throws {
        try assertInvalidSourceAliases("CHECKOUT OPTIONS")
    }

    func testDuplicateExternalSourceAliasesProduceDiagnosticInsteadOfTrapping() throws {
        try assertInvalidSourceAliases("EXTERNAL SOURCES")
    }

    func testHookGraphRejectsWrongReferenceListTypes() throws {
        let root = NativePBX.identifier("audit-hook-root")
        let keys = ["targets", "buildPhases", "dependencies", "buildConfigurations", "children", "files"]
        for key in keys {
            for invalid in [[123] as Any, "invalid" as Any, NSNull() as Any] {
                let object: [String: Any] = ["isa": "PBXProject", key: invalid]
                let graph: [String: Any] = ["rootObject": root, "objects": [root: object]]
                XCTAssertThrowsError(try NativeHookGraph.parse(["graph": graph]), "Invalid \(key): \(invalid)") {
                    error in
                    XCTAssertEqual((error as? Diagnostic)?.code, "SP-HOOK-GRAPH")
                }
            }
            let object: [String: Any] = ["isa": "PBXProject", key: [String]()]
            XCTAssertNoThrow(try NativeHookGraph.parse(["graph": ["rootObject": root, "objects": [root: object]]]))
        }
    }

    private func assertInvalidSourceAliases(_ section: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("Podfile.lock")
        let text =
            "\(section):\n  Kit:\n    ':git': 'https://example.org/a.git'\n    git: 'https://example.org/b.git'\n"
        try Data(text.utf8).write(to: path)
        XCTAssertThrowsError(try NativeLock(path)) { error in
            XCTAssertEqual((error as? Diagnostic)?.code, "SP-LOCK-SCHEMA")
        }
    }

    private func withLock(_ text: String, body: (NativeLock) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("Podfile.lock")
        try Data(text.utf8).write(to: path)
        try body(NativeLock(path))
    }
}
