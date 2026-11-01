import Foundation
@testable import SwiftPodsKit
import SwiftPodsTestSupport
import SwiftPodsXcode
import XCTest

final class ProjectIntegrationSecurityTests: XCTestCase {
    func testForeignObjectWithDeterministicIdentifierIsNotOverwritten() throws {
        let directory = try Fixtures.directory(podfile: "")
        defer { try? FileManager.default.removeItem(at: directory) }
        var project = try XcodeProject(path: directory.appendingPathComponent("App.xcodeproj"))

        let key = "package:local:SwiftPods/SwiftPodsDependencies"
        let identifier = XcodeProject.identifier(key)
        project[identifier] = [
            "isa": "PBXGroup", "children": [], "name": "Unrelated user object", "sourceTree": "<group>",
        ]
        let before = project.objects

        var plan = ProjectPlan()
        plan.packages = [
            .init(
                key: key,
                object: [
                    "isa": "PBXFileReference", "lastKnownFileType": "wrapper",
                    "path": "SwiftPods/SwiftPodsDependencies", "sourceTree": "SOURCE_ROOT",
                ])
        ]

        XCTAssertThrowsError(try ProjectIntegration.apply(plan, to: &project, adopt: false)) { error in
            XCTAssertTrue("\(error)".contains(identifier), "\(error)")
            XCTAssertTrue("\(error)".contains("collide"), "\(error)")
        }
        XCTAssertEqual(project.objects, before)
    }

    func testPackageLessLocalProductsFailClosedAtTheSemanticWorkBudget() throws {
        let directory = try Fixtures.directory(podfile: "")
        defer { try? FileManager.default.removeItem(at: directory) }
        var project = try XcodeProject(path: directory.appendingPathComponent("App.xcodeproj"))

        for index in 0..<1_001 {
            let key = "package:local:Vendor/Package\(index)"
            project[XcodeProject.identifier(key)] = [
                "isa": "PBXFileReference", "lastKnownFileType": "wrapper",
                "path": .string("Vendor/Package\(index)"), "sourceTree": "SOURCE_ROOT",
            ]
        }
        let targetID = try XCTUnwrap(project.nativeTargets.first?.id)
        var target = try XCTUnwrap(project[targetID])
        var products: [PBXValue] = []
        for index in 0..<1_000 {
            let id = String(format: "%024X", index + 1)
            project[id] = [
                "isa": "XCSwiftPackageProductDependency",
                "productName": .string("Product\(index)"),
            ]
            products.append(.string(id))
        }
        target["packageProductDependencies"] = .array(products)
        project[targetID] = target
        let before = project.objects

        XCTAssertThrowsError(try ProjectIntegration.apply(ProjectPlan(), to: &project, adopt: false)) { error in
            XCTAssertTrue("\(error)".contains("semantic integration work budget"), "\(error)")
        }
        XCTAssertEqual(project.objects, before)
    }

    func testCocoaPodsRemovalDeletesAllOwnedObjectsInOneBatch() throws {
        let directory = try Fixtures.directory(podfile: "")
        defer { try? FileManager.default.removeItem(at: directory) }
        var project = try XcodeProject(path: directory.appendingPathComponent("App.xcodeproj"))
        guard var rootGroup = project[project.project.string("mainGroup")!] else {
            return XCTFail("Fixture has no main group")
        }
        var children = rootGroup.strings("children")
        for index in 0..<64 {
            let file = String(format: "D%023X", index)
            let group = String(format: "E%023X", index)
            project[file] = [
                "isa": "PBXFileReference", "path": .string("Pods/Target Support Files/Pods-App/Pods-App-\(index).xcconfig"),
                "sourceTree": "<group>",
            ]
            project[group] = [
                "isa": "PBXGroup", "children": .array([.string(file)]),
                "name": "Pods", "sourceTree": "<group>",
            ]
            children.append(group)
        }
        rootGroup["children"] = .array(children.map(PBXValue.string))
        project[project.project.string("mainGroup")!] = rootGroup

        _ = try CocoaPodsIntegration.remove(from: &project)
        XCTAssertFalse(project.objects.values.contains { ($0.string("name") ?? $0.string("path")) == "Pods" })
        XCTAssertFalse(project.objects.values.contains { $0.string("path")?.contains("Pods/Target Support Files/") == true })
    }
}
