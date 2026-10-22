import XCTest

@testable import SwiftPodsCore

final class NativeLockRecoveryTests: XCTestCase {
    private func lock() throws -> NativeLock {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("Podfile.lock")
        try Data("""
            PODS:
              - A (1.0):
                - B (= 1.0)
              - B (1.0)
              - C (1.0)
              - D (1.0)
            DEPENDENCIES:
              - A
              - D
            """.utf8).write(to: path)
        return try NativeLock(path)
    }

    func testRecoveryIncludesEveryPlatformBeforeUnlockingAndRetainsUnrelatedPins() throws {
        let lock = try lock()
        let a = try NativeSpec(data: [
            "name": "A", "version": "1.0", "ios": ["dependencies": ["B": ["= 1.0"]]],
            "osx": ["dependencies": ["C": ["= 1.0"]]],
        ])
        let direct = try [
            NativeDependency(["name": "A"], platform: "ios"),
            NativeDependency(["name": "A"], platform: "osx"),
            NativeDependency(["name": "D"], platform: "osx"),
        ]
        let graph = try lock.recoveredDependencies(direct) { request, version in
            XCTAssertEqual(version, "1.0")
            return request.root == "A" ? a : nil
        }
        XCTAssertEqual(lock.unlocked(["A"]), ["A", "B"])
        XCTAssertEqual(lock.unlocked(["A"], dependencies: graph), ["A", "B", "C"])
        XCTAssertEqual(lock.dependencies["A"], ["B"])
    }

    func testRecoveredSharedParentPreventsUnrelatedTransitiveUpdates() throws {
        let lock = try lock()
        let specs = try Dictionary(uniqueKeysWithValues: ["A", "D"].map { name in
            (name, try NativeSpec(data: ["name": name, "version": "1.0", "dependencies": ["C": [">= 1"]]]))
        })
        let direct = try ["A", "D"].map { try NativeDependency(["name": $0]) }
        let graph = try lock.recoveredDependencies(direct) { request, _ in specs[request.root] }
        XCTAssertEqual(lock.unlocked(["A"], dependencies: graph), ["A", "B"])
        XCTAssertEqual(lock.unlocked(["A", "D"], dependencies: graph), ["A", "B", "C", "D"])
    }
}
