import Foundation
import XCTest

@testable import SwiftPodsCore

final class NativeSchemeContainerBoundaryTests: XCTestCase {
    private func references(_ name: String, multiple: Bool) throws -> ([String], URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let spec = try NativeSpec(data: ["name": name, "version": "1.0"], directory: root, local: true)
        let request = try NativeDependency(["name": name], platform: "osx", deployment: "13.0")
        let engine = try NativeXcode(
            project: root,
            manifest: [
                "options": ["generate_multiple_pod_projects": multiple, "share_schemes_for_development_pods": true],
                "targets": [
                    [
                        "name": "Demo", "platform": ["name": "osx", "deployment_target": "13.0"],
                        "dependencies": [["name": name]],
                    ]
                ],
            ], resolution: NativeResolution(specs: [name: spec], requests: [request]), integrateUserProjects: false)
        try engine.generate()
        let project = root.appendingPathComponent("Pods/Pods.xcodeproj")
        let file = project.appendingPathComponent("xcshareddata/xcschemes/" + name + ".xcscheme")
        let document = try XMLDocument(contentsOf: file, options: [])
        let references = try document.nodes(forXPath: "//BuildableReference").compactMap {
            ($0 as? XMLElement)?.attribute(forName: "ReferencedContainer")?.stringValue
        }
        XCTAssertEqual(references.count, 1)
        return (references, multiple ? engine.projectForPod(name) : project)
    }

    func testMultipleProjectContainerResolvesTheActualUnicodeProject() throws {
        for name in ["Kit", "\u{301}Kit"] {
            let (values, expected) = try references(name, multiple: true)
            for value in values {
                XCTAssertTrue(value.hasPrefix("container:"), value)
                let path = String(value.dropFirst("container:".count))
                let resolved = URL(fileURLWithPath: path, relativeTo: expected.deletingLastPathComponent())
                    .standardizedFileURL
                XCTAssertEqual(resolved.path, expected.path)
            }
        }
    }

    func testSingleProjectSchemeStillResolvesTheAggregateProject() throws {
        for name in ["Kit", "\u{301}Kit"] {
            let (values, expected) = try references(name, multiple: false)
            for value in values {
                XCTAssertTrue(value.hasPrefix("container:"), value)
                let path = String(value.dropFirst("container:".count))
                XCTAssertEqual(
                    URL(fileURLWithPath: path, relativeTo: expected.deletingLastPathComponent()).standardizedFileURL
                        .path, expected.path)
            }
        }
    }
}
