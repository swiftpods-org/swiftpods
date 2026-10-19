import XCTest

@testable import SwiftPodsCore

final class NativeValueContractTests: XCTestCase {
    func testNumericDependencyRequirementsConstrainResolutionAndInherit() throws {
        let spec = try NativeSpec(data: [
            "name": "Kit", "version": "1.0", "dependencies": ["Helper": 42],
            "subspecs": [["name": "Core", "dependencies": ["Helper": [">= 40"]]]],
        ])
        let request = try NativeDependency(["name": "Kit/Core"])
        let dependencies = try spec.dependencies(for: request)
        XCTAssertEqual(dependencies.first?.requirements, ["42", ">= 40"])
        let helper = try NativeSpec(data: ["name": "Helper", "version": "100.0"])
        XCTAssertThrowsError(
            try NativeResolver(candidates: { $0.root == "Kit" ? [spec] : [helper] }).resolve([request]))
        XCTAssertEqual((spec.data["dependencies"] as? [String: Int])?["Helper"], 42)
    }

    func testNumericDeploymentTargetParticipatesInBacktracking() throws {
        let high = try NativeSpec(data: ["name": "Kit", "version": "2.0", "platforms": ["osx": 14]])
        let low = try NativeSpec(data: ["name": "Kit", "version": "1.0", "platforms": ["osx": "13.0"]])
        let request = try NativeDependency(["name": "Kit"], platform: "osx", deployment: "13.0")
        let resolved = try NativeResolver(candidates: { _ in [high, low] }).resolve([request])
        XCTAssertEqual(resolved.specs["Kit"]?.version.description, "1.0")
        XCTAssertEqual((high.data["platforms"] as? [String: Int])?["osx"], 14)
    }

    func testStringPlatformsKeepTheirMeaningAndMalformedArraysAreRejected() throws {
        let spec = try NativeSpec(data: ["name": "Kit", "version": "1.0", "platforms": "osx"])
        let attributes = try spec.attributes("Kit", platform: "ios")
        XCTAssertNotNil((attributes["platforms"] as? [String: Any])?["osx"])
        XCTAssertThrowsError(try spec.dependencies(for: NativeDependency(["name": "Kit"], platform: "ios")))
        XCTAssertThrowsError(try NativeSpec(data: ["name": "Kit", "version": "1.0", "platforms": ["osx", "tvos"]]))
    }

    func testNumericSwiftVersionsAreSelectedWithoutRewritingRawData() throws {
        let spec = try NativeSpec(data: ["name": "Kit", "version": "1.0", "swift_versions": ["4.2", 5]])
        XCTAssertEqual(
            try NativeSwiftVersion.select(spec: spec, targets: [["swift_version_requirements": [">= 5"]]]), "5")
        XCTAssertEqual((spec.data["swift_versions"] as? [Any])?.last as? Int, 5)
        XCTAssertThrowsError(try NativeSpec(data: ["name": "Kit", "version": "1.0", "swift_versions": [true]]))
        let singular = try NativeSpec(data: ["name": "Kit", "version": "1.0", "swift_version": 5])
        XCTAssertEqual(try NativeSwiftVersion.select(spec: singular, targets: []), "5")
        XCTAssertThrowsError(try NativeSpec(data: ["name": "Kit", "version": "1.0", "swift_versions": 5]))
    }

    func testNestedContainerTypesAndSourceOptionsFailBeforeInstallation() {
        let invalid: [[String: Any]] = [
            ["dependencies": "Ignored"], ["dependencies": ["Other": ["invalid": true]]],
            ["dependencies": ["Other": ["not a requirement"]]],
            ["pod_target_xcconfig": "FLAG=1"], ["resource_bundles": "Resources/*.png"],
            ["resource_bundles": ["Bundle": [42]]],
            ["source": ["git": 42]], ["source": ["http": "https://example.invalid/source.zip", "flatten": 1]],
            ["source": ["http": "https://example.invalid/source.zip", "headers": ["X-Value": 42]]],
            ["testspecs": [["name": "T", "osx": ["deployment_target": ["invalid": true]]]]],
        ]
        for changes in invalid {
            let base: [String: Any] = ["name": "Kit", "version": "1.0"]
            XCTAssertThrowsError(try NativeSpec(data: base.merging(changes) { _, value in value }))
        }
    }

    func testPodNamesAcceptGraphicSymbolsWhileRejectingHiddenAndUnsafeComponents() throws {
        for name in ["Kit@Core", "📦Kit", "Kit's", "Family👩‍💻"] {
            XCTAssertEqual(try NativeSpec(data: ["name": name, "version": "1.0"]).name, name)
            XCTAssertEqual(try NativeDependency(["name": name + "/Core"]).root, name)
        }
        for name in [".Hidden", "Kit/.Hidden", "Kit/..", "Kit\\Other", "Kit\0Other", "Kit\nOther", "Kit\u{0080}Other"] {
            XCTAssertThrowsError(try NativeDependency(["name": name]), name)
        }
        for name in ["", "A/B", ".Hidden"] {
            XCTAssertThrowsError(
                try NativeSpec(data: ["name": "Kit", "version": "1.0", "subspecs": [["name": name]]]))
        }
    }
}
