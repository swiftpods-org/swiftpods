import Foundation
import XCTest

@testable import SwiftPodsCore

final class NativeIntegrationLocationTests: XCTestCase {
    private let old = URL(fileURLWithPath: "/old/work", isDirectory: true)
    private let current = URL(fileURLWithPath: "/new/work", isDirectory: true)
    private let config = String(repeating: "A", count: 24)

    private func record(original: Any = NSNull()) -> [String: Any] {
        ["original": ["PODS_ROOT": original], "written": ["PODS_ROOT": old.appendingPathComponent("Pods").path]]
    }

    func testLegacyInternalOwnershipRestoresOriginalValuesAfterRelocation() throws {
        for original: Any in [NSNull(), "user-owned-pods"] {
            let before = old.appendingPathComponent("\u{301}App.xcodeproj/project.pbxproj").path
            let after = current.appendingPathComponent("\u{301}App.xcodeproj/project.pbxproj").path
            let settings: [String: Any] = [before + ":" + config: record(original: original)]
            let relocated = try NativeIntegrationLocation.relocated(settings, to: current)
            XCTAssertEqual(NativeIntegrationSettings.projectPaths(relocated), [after])
            let entry = try XCTUnwrap(relocated[after + ":" + config] as? [String: Any])
            let restored = try NativeIntegrationSettings.restore(["PODS_ROOT": "/old/work/Pods"], record: entry)
            if original is NSNull {
                XCTAssertNil(restored["PODS_ROOT"])
            } else {
                XCTAssertEqual(restored["PODS_ROOT"] as? String, "user-owned-pods")
            }
        }
    }

    func testRelativeExternalProjectsMoveAndAbsoluteExternalProjectsStaySelected() throws {
        let relative = "/old/Apps/App.xcodeproj/project.pbxproj"
        let absolute = "/shared/Fixed.xcodeproj/project.pbxproj"
        let settings: [String: Any] = [
            "_project_root": old.path,
            "_project_paths": [relative: "../Apps/App.xcodeproj/project.pbxproj", absolute: absolute],
            relative + ":" + config: record(), absolute + ":" + config: record(),
        ]
        let relocated = try NativeIntegrationLocation.relocated(settings, to: current)
        XCTAssertEqual(
            NativeIntegrationSettings.projectPaths(relocated), ["/new/Apps/App.xcodeproj/project.pbxproj", absolute])
    }

    func testSelectedOriginalAndCopiedProjectsKeepSeparateOwnershipRecords() throws {
        let before = old.appendingPathComponent("App.xcodeproj/project.pbxproj").path
        let after = current.appendingPathComponent("App.xcodeproj/project.pbxproj").path
        let settings: [String: Any] = ["_project_root": old.path, before + ":" + config: record()]
        let relocated = try NativeIntegrationLocation.relocated(
            settings, to: current, selected: [before: before, after: "App.xcodeproj/project.pbxproj"])
        XCTAssertEqual(NativeIntegrationSettings.projectPaths(relocated), [before, after])
        for path in [before, after] {
            let entry = try XCTUnwrap(relocated[path + ":" + config] as? [String: Any])
            XCTAssertNil(
                try NativeIntegrationSettings.restore(["PODS_ROOT": "/old/work/Pods"], record: entry)["PODS_ROOT"])
        }
    }

    func testRelocatedOwnershipPreservesAnExternalSettingEdit() throws {
        let path = "/old/work/App.xcodeproj/project.pbxproj"
        let relocated = try NativeIntegrationLocation.relocated([path + ":" + config: record()], to: current)
        let entry = try XCTUnwrap(relocated["/new/work/App.xcodeproj/project.pbxproj:" + config] as? [String: Any])
        XCTAssertEqual(
            try NativeIntegrationSettings.restore(["PODS_ROOT": "external-edit"], record: entry)["PODS_ROOT"]
                as? String,
            "external-edit")
        XCTAssertEqual(try jsonData(entry), try jsonData(record()))
    }

    func testAmbiguousLegacyExternalOwnershipRequiresExplicitRefresh() {
        XCTAssertThrowsError(
            try NativeIntegrationLocation.relocated(
                ["/other/App.xcodeproj/project.pbxproj:" + config: record()], to: current)
        ) {
            XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-INTEGRATION-LOCATION")
        }
    }

    func testConfigurationPackageAndAttributeRecordsMoveTogether() throws {
        let before = "/old/work/\u{301}App.xcodeproj/project.pbxproj"
        let after = "/new/work/\u{301}App.xcodeproj/project.pbxproj"
        let settings: [String: Any] = [
            before + ":" + config: record(),
            "_base_configurations": [before + ":" + config: "base"],
            "_support_configurations": [before + ":" + config: "support"],
            "_swift_packages": [before: ["objects": ["package": ["written": "original-bytes"]]]],
            "_project_attributes": [before: ["written": ["marker": "keep"]]],
        ]
        let moved = try NativeIntegrationLocation.relocated(settings, to: current)
        XCTAssertEqual((moved["_base_configurations"] as? [String: String])?[after + ":" + config], "base")
        XCTAssertEqual((moved["_support_configurations"] as? [String: String])?[after + ":" + config], "support")
        for field in ["_swift_packages", "_project_attributes"] {
            XCTAssertNotNil((moved[field] as? [String: Any])?[after])
            XCTAssertNil((moved[field] as? [String: Any])?[before])
        }
    }

    func testMalformedLocationBindingsAreRejected() {
        for (field, value): (String, Any) in [
            ("_project_paths", ["path": 1]), ("_workspace_paths", ["path": false]), ("_project_root", 7),
        ] {
            XCTAssertThrowsError(try NativeIntegrationLocation.relocated([field: value], to: current)) {
                XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-INTEGRATION-LOCATION")
            }
        }
    }

    func testWorkspaceBindingsPreserveRelativeAndAbsoluteExternalLocations() throws {
        let internalPath = "/old/work/\u{301}Demo.xcworkspace/contents.xcworkspacedata"
        let externalPath = "/shared/Fixed.xcworkspace/contents.xcworkspacedata"
        let owned = ["group:Pods/Pods.xcodeproj"]
        let settings: [String: Any] = [
            "_project_root": old.path,
            "_workspaces": [internalPath: owned, externalPath: owned],
            "_workspace_paths": [internalPath: internalPath, externalPath: externalPath],
        ]
        let relocated = try NativeIntegrationLocation.relocated(settings, to: current)
        let workspaces = relocated["_workspaces"] as? [String: [String]] ?? [:]
        XCTAssertEqual(
            Set(workspaces.keys), ["/new/work/\u{301}Demo.xcworkspace/contents.xcworkspacedata", externalPath])
        XCTAssertEqual(workspaces[externalPath], owned)
    }

    func testRelativeExternalProjectContractsRemainPortableWithoutIgnoringDependencyChanges() throws {
        let oldPath = "/old/Apps/App.xcodeproj"
        let newPath = "/new/Apps/App.xcodeproj"
        let oldManifest: [String: Any] = ["targets": [["_id": "old", "project": oldPath, "dependencies": ["1.0"]]]]
        let newManifest: [String: Any] = ["targets": [["_id": "new", "project": newPath, "dependencies": ["1.0"]]]]
        let oldContract = NativeIntegrationLocation.contractManifest(
            oldManifest, bindings: [oldPath + "/project.pbxproj": "../Apps/App.xcodeproj/project.pbxproj"], root: old)
        let newContract = NativeIntegrationLocation.contractManifest(
            newManifest, bindings: [newPath + "/project.pbxproj": "../Apps/App.xcodeproj/project.pbxproj"],
            root: current)
        XCTAssertEqual(try jsonData(oldContract), try jsonData(newContract))
        let changed: [String: Any] = ["targets": [["project": newPath, "dependencies": ["2.0"]]]]
        let changedContract = NativeIntegrationLocation.contractManifest(
            changed, bindings: [newPath + "/project.pbxproj": "../Apps/App.xcodeproj/project.pbxproj"], root: current)
        XCTAssertNotEqual(try jsonData(oldContract), try jsonData(changedContract))
    }
}
