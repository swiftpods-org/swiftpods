import XCTest

@testable import SwiftPodsCore

final class NativeLinkageSafetyTests: XCTestCase {
    private func engine(mode: String, transitive: Bool = false, independent: Bool = false) throws -> NativeXcode {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        for name in ["Kit", "Middle", "State"] {
            try Data("int \(name.lowercased())(void) { return 7; }\n".utf8)
                .write(to: root.appendingPathComponent(name + ".c"))
        }
        let kit = try NativeSpec(
            data: [
                "name": "Kit", "version": "1.0", "source_files": "Kit.c",
                "dependencies": independent ? [:] : [transitive ? "Middle" : "State": [] as [String]],
            ], directory: root)
        let middle = try NativeSpec(
            data: [
                "name": "Middle", "version": "1.0", "source_files": "Middle.c",
                "dependencies": ["State": [] as [String]],
            ], directory: root)
        let state = try NativeSpec(
            data: [
                "name": "State", "version": "1.0", "source_files": "State.c", "static_framework": true,
            ], directory: root)
        var targets: [[String: Any]] = [
            [
                "name": "Demo", "platform": ["name": "osx", "deployment_target": "13.0"],
                "dependencies": [["name": "Kit"]], "frameworks": mode,
            ]
        ]
        if independent {
            targets.append([
                "name": "Separate", "platform": ["name": "osx", "deployment_target": "13.0"],
                "dependencies": [["name": "State"]], "frameworks": "static",
            ])
        }
        return try NativeXcode(
            project: root, manifest: ["targets": targets],
            resolution: NativeResolution(specs: ["Kit": kit, "Middle": middle, "State": state], requests: []),
            integrateUserProjects: false)
    }

    func testDynamicPodsRejectDirectAndTransitiveStaticSourceDependencies() throws {
        for transitive in [false, true] {
            let engine = try engine(mode: "dynamic", transitive: transitive)
            XCTAssertThrowsError(try engine.generate()) { error in
                XCTAssertEqual((error as? Diagnostic)?.code, "SP-XCODE-STATIC-DEPENDENCY")
                XCTAssertEqual((error as? Diagnostic)?.dependencyChain.last, "State")
            }
        }
    }

    func testStaticAndIndependentConsumersRemainSupported() throws {
        for mode in ["static", "library"] {
            try engine(mode: mode, transitive: true).generate()
        }
        try engine(mode: "dynamic", independent: true).generate()
    }
}
