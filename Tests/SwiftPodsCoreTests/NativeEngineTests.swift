import XCTest

@testable import SwiftPodsCore

final class NativeEngineTests: XCTestCase {
    func testVersionsUseNumericAndPrereleaseOrdering() throws {
        XCTAssertLessThan(try PodVersion("1.9"), try PodVersion("1.10"))
        XCTAssertEqual(try PodVersion("1.0"), try PodVersion("1.0.0"))
        XCTAssertEqual(Set(try ["1.0", "1.0.0", "01.00.0"].map(PodVersion.init)).count, 1)
        XCTAssertLessThan(try PodVersion("1.0.beta.2"), try PodVersion("1.0.beta.10"))
        XCTAssertLessThan(try PodVersion("1.0.rc.1"), try PodVersion("1.0"))
        XCTAssertGreaterThan(try PodVersion("1.2.3.4"), try PodVersion("1.2.3"))
        XCTAssertThrowsError(try PodVersion("../bad"))
        XCTAssertLessThan(try PodVersion("1.0.RC"), try PodVersion("1.0.rc"))
        XCTAssertLessThan(try PodVersion("1.9999999999999999999999999"), try PodVersion("1.10000000000000000000000000"))
    }
    func testPessimisticRequirementsKeepTheirPrecision() throws {
        XCTAssertTrue(try PodRequirement(["~> 1.2"]).accepts(PodVersion("1.9.0")))
        XCTAssertFalse(try PodRequirement(["~> 1.2"]).accepts(PodVersion("2.0")))
        XCTAssertFalse(try PodRequirement(["~> 1.2.3"]).accepts(PodVersion("1.3")))
        XCTAssertTrue(try PodRequirement(["~> 1.2.3.4", "!= 1.2.3.5"]).accepts(PodVersion("1.2.3.9")))
        XCTAssertFalse(try PodRequirement(["~> 1.2.3.4"]).accepts(PodVersion("1.2.4")))
        XCTAssertTrue(try PodRequirement([">= 1.0, < 2.0"]).accepts(PodVersion("1.5")))
        XCTAssertThrowsError(try PodRequirement(["=> 1.0"]))
    }
    func testResolverBacktracksAcrossTransitiveConflicts() throws {
        func spec(_ name: String, _ version: String, _ dependencies: [String: [String]] = [:]) throws -> NativeSpec {
            try NativeSpec(data: ["name": name, "version": version, "dependencies": dependencies])
        }
        let catalog = try [
            "A": [spec("A", "2.0", ["B": [">= 2"]]), spec("A", "1.0", ["B": ["< 2"]])],
            "B": [spec("B", "2.0"), spec("B", "1.0")], "C": [spec("C", "1.0", ["B": ["< 2"]])],
        ]
        let resolver = NativeResolver(candidates: { catalog[$0.root] ?? [] })
        let result = try resolver.resolve([NativeDependency(["name": "A"]), NativeDependency(["name": "C"])])
        XCTAssertEqual(result.specs["A"]?.version.description, "1.0")
        XCTAssertEqual(result.specs["B"]?.version.description, "1.0")
        XCTAssertThrowsError(
            try resolver.resolve([
                NativeDependency(["name": "A", "requirements": [">= 2"]]), NativeDependency(["name": "C"]),
            ]))
    }
    func testResolverSubspecsPlatformAndLockedPreference() throws {
        let spec = try NativeSpec(data: [
            "name": "Kit", "version": "1.2.3.4", "default_subspecs": ["Core"],
            "subspecs": [["name": "Core", "dependencies": ["Helper": [">= 1"]]]],
        ])
        let helper = try NativeSpec(data: ["name": "Helper", "version": "1.0"])
        let result = try NativeResolver(candidates: { $0.root == "Kit" ? [spec] : [helper] }).resolve([
            NativeDependency(["name": "Kit"])
        ])
        XCTAssertEqual(Set(result.requests.map(\.name)), ["Kit", "Kit/Core", "Helper"])
        let incompatible = try NativeSpec(data: ["name": "New", "version": "1.0", "platforms": ["ios": "18.0"]])
        XCTAssertThrowsError(
            try NativeResolver(candidates: { _ in [incompatible] }).resolve([
                NativeDependency(["name": "New"], deployment: "15.0")
            ]))
        let old = try NativeSpec(data: ["name": "Old", "version": "1.0"])
        let newer = try NativeSpec(data: ["name": "Old", "version": "2.0"])
        let locked = try NativeResolver(candidates: { _ in [newer, old] }, locked: ["Old": "1.0"]).resolve([
            NativeDependency(["name": "Old"])
        ])
        XCTAssertEqual(locked.specs["Old"]?.version.description, "1.0")
    }
    func testResolverRejectsMergedCyclesAndBacktracksToAcyclicVersions() throws {
        let a = try NativeSpec(data: ["name": "A", "version": "2.0", "dependencies": ["B": [">= 0"]]])
        let older = try NativeSpec(data: ["name": "A", "version": "1.0"])
        let b = try NativeSpec(data: ["name": "B", "version": "1.0", "dependencies": ["C": [">= 0"]]])
        let c = try NativeSpec(data: ["name": "C", "version": "1.0", "dependencies": ["A": [">= 0"]]])
        let candidates = ["A": [a, older], "B": [b], "C": [c]]
        let roots = try ["A", "C"].map { try NativeDependency(["name": $0]) }
        let resolver = NativeResolver(candidates: { candidates[$0.root] ?? [] })
        XCTAssertEqual(try resolver.resolve(roots).specs["A"]?.version.description, "1.0")
        let pinned = NativeResolver(candidates: resolver.candidates, locked: ["A": "2.0"])
        XCTAssertThrowsError(try pinned.resolve(roots)) { error in
            let diagnostic = error as? Diagnostic
            XCTAssertEqual(diagnostic?.code, "SP-RESOLVE-CONFLICT")
            XCTAssertEqual(diagnostic?.dependencyChain, ["A", "B", "C", "A"])
        }
    }
    func testResolverRejectsCycleThroughDefaultSubspec() throws {
        let kit = try NativeSpec(data: [
            "name": "Kit", "version": "1.0", "default_subspecs": ["Core"],
            "subspecs": [["name": "Core", "dependencies": ["Helper": [">= 0"]]]],
        ])
        let helper = try NativeSpec(data: ["name": "Helper", "version": "1.0", "dependencies": ["Kit/Core": [">= 0"]]])
        XCTAssertThrowsError(
            try NativeResolver(candidates: { $0.root == "Kit" ? [kit] : [helper] }).resolve([
                NativeDependency(["name": "Kit"])
            ]))
    }
    func testNativeProjectRoundTripPreservesUnknownObjects() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("project.pbxproj")
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let graph = try NativePBX(path)
        let id = graph.add(
            "custom", ["isa": "FutureXcodeObject", "text": "quote\"slash\\line\n", "array": ["a", "b"]])
        graph.root = ["archiveVersion": "1", "rootObject": id]
        try graph.save()
        let loaded = try NativePBX(path, existing: true)
        XCTAssertEqual(loaded.objects[id]?["text"] as? String, "quote\"slash\\line\n")
        XCTAssertEqual(loaded.objects[id]?["array"] as? [String], ["a", "b"])
        try Data("external edit".utf8).write(to: path)
        XCTAssertThrowsError(try loaded.save())
    }
    func testLegacyLockPinsAndGeneratedLockCanBeReadWithoutRuby() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("Podfile.lock")
        try Data(
            "PODS:\n  - Helper (1.1.0)\n  - Kit/Core (1.2.3.4):\n    - Helper (~> 1.0)\n\nPODFILE CHECKSUM: abc\n\nCOCOAPODS: 1.17.0\n"
                .utf8
        ).write(to: path)
        let lock = try NativeLock(path)
        XCTAssertEqual(lock.versions, ["Kit": "1.2.3.4", "Helper": "1.1.0"])
        XCTAssertEqual(lock.checksum, "abc")
    }
}
