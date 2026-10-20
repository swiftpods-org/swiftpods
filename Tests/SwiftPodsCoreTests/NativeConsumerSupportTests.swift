import XCTest

@testable import SwiftPodsCore

final class NativeConsumerSupportTests: XCTestCase {
    private func engine() throws -> NativeXcode {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try NativeXcode(
            project: root, manifest: [:], resolution: NativeResolution(specs: [:], requests: []),
            integrateUserProjects: false)
    }

    func testCopyScriptTreatsFileNamesAsDataAndUpdatesExistingResources() throws {
        let engine = try engine()
        let user = try NativePBX(engine.project.appendingPathComponent("Demo.xcodeproj/project.pbxproj"))
        let target = user.add("target", ["isa": "PBXNativeTarget", "buildPhases": []])
        let name = "Café $(touch compromised) $Data ' 🧩.txt"
        let source = engine.project.appendingPathComponent(name)
        let destination = engine.project.appendingPathComponent("Build/Resources/" + name)
        try Data("first".utf8).write(to: source)
        try engine.consumerCopyPhase(
            ["Debug": [NativeConsumerCopy(source: engine.consumerPath(source), destination: name)]],
            kind: "resources", label: "Pods-Demo", target: target, user: user)
        let script = engine.project.appendingPathComponent("Pods/Target Support Files/Pods-Demo/Pods-Demo-resources.sh")
        var environment = ProcessInfo.processInfo.environment
        environment.merge([
            "PODS_ROOT": engine.project.appendingPathComponent("Pods").path,
            "TARGET_BUILD_DIR": engine.project.appendingPathComponent("Build").path,
            "UNLOCALIZED_RESOURCES_FOLDER_PATH": "Resources", "CONFIGURATION": "Debug",
            "DERIVED_FILE_DIR": engine.project.appendingPathComponent("Derived").path,
        ]) { _, new in new }
        for text in ["first", "updated"] {
            try Data(text.utf8).write(to: source)
            let copied = try ToolProcess.run(
                "/bin/sh", [script.path], directory: engine.project, environment: environment)
            XCTAssertEqual(copied.status, 0, String(decoding: copied.error, as: UTF8.self))
            XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), text)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: engine.project.appendingPathComponent("compromised").path))
        environment["CONFIGURATION"] = "Unknown"
        XCTAssertNotEqual(try ToolProcess.run("/bin/sh", [script.path], environment: environment).status, 0)
    }

    func testFileListsUseTheSelectedConfigurationAndKeepProjectsSmall() throws {
        let engine = try engine()
        let user = try NativePBX(engine.project.appendingPathComponent("Demo.xcodeproj/project.pbxproj"))
        let target = user.add("target", ["isa": "PBXNativeTarget", "buildPhases": []])
        let copy = NativeConsumerCopy(
            source: NativeConsumerPath(variable: "BUILT_PRODUCTS_DIR", relative: "SDK.framework"),
            destination: "SDK.framework")
        try engine.consumerCopyPhase(
            ["Debug": [copy], "Release": []], kind: "frameworks", label: "Pods-Demo", target: target, user: user)
        let support = engine.project.appendingPathComponent("Pods/Target Support Files/Pods-Demo")
        let debug = try String(
            contentsOf: support.appendingPathComponent("Pods-Demo-frameworks-Debug-input-files.xcfilelist"),
            encoding: .utf8)
        let release = try String(
            contentsOf: support.appendingPathComponent("Pods-Demo-frameworks-Release-input-files.xcfilelist"),
            encoding: .utf8)
        XCTAssertTrue(debug.contains("$(BUILT_PRODUCTS_DIR)/SDK.framework"))
        XCTAssertFalse(release.contains("SDK.framework"))
        XCTAssertEqual(user.objects.count, 2)
        XCTAssertTrue(
            user.objects.values.allSatisfy {
                !["PBXFileReference", "PBXBuildFile"].contains($0["isa"] as? String ?? "")
            })
    }

    func testResourceCompilerOutputsPreserveLocalizationAndCompiledExtensions() throws {
        let engine = try engine()
        let root = engine.project
        let resources = [
            "View.xib", "Base.lproj/Flow.storyboard", "de.lproj/Localizable.strings", "Model.xcdatamodeld",
            "PrivacyInfo.xcprivacy",
        ]
        for name in resources {
            let file = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: file)
        }
        let catalog = root.appendingPathComponent("Loose.xcstrings")
        try jsonData([
            "sourceLanguage": "en", "version": "1.0",
            "strings": [
                "key": ["localizations": ["en": ["stringUnit": ["state": "translated", "value": "Value"]]]]
            ],
        ]).write(to: catalog)
        let outputs = try NativeConsumerResourceOutputs.paths(resources.map(root.appendingPathComponent) + [catalog])
        XCTAssertEqual(
            Set(outputs),
            [
                "View.nib", "Base.lproj/Flow.storyboardc", "de.lproj/Localizable.strings", "Model.momd",
                "PrivacyInfo.xcprivacy", "en.lproj/Loose.strings",
            ])
    }

    func testLooseResourcesMoveToPodsWhileAssetCatalogsStayWithTheApp() throws {
        let engine = try engine()
        let root = engine.project
        try Data("payload".utf8).write(to: root.appendingPathComponent("plain.txt"))
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Icons.xcassets"), withIntermediateDirectories: true)
        let spec = try NativeSpec(
            data: ["name": "Kit", "version": "1.0", "resources": ["plain.txt", "Icons.xcassets"]], directory: root)
        let target: [String: Any] = [
            "name": "Demo", "platform": ["name": "ios", "deployment_target": "15.4"], "dependencies": [["name": "Kit"]],
        ]
        let generated = try NativeXcode(
            project: root, manifest: ["targets": [target]],
            resolution: NativeResolution(specs: ["Kit": spec], requests: []), integrateUserProjects: false)
        try generated.generate()
        XCTAssertEqual(generated.consumerNativeResources["Demo"]?.map(\.lastPathComponent), ["Icons.xcassets"])
        let resourceTarget = try XCTUnwrap(generated.consumerResourceTargets["Demo"])
        let resourceProduct = try XCTUnwrap(generated.consumerResourceProducts["Demo"])
        XCTAssertEqual(generated.consumerProductPath(resourceProduct).variable, "PODS_CONFIGURATION_BUILD_DIR")
        let reachable = NativeProjectProjection.reachable(generated.graph.objects, from: [resourceTarget])
        XCTAssertTrue(reachable.contains { generated.graph.objects[$0]?["path"] as? String == "../plain.txt" })
        XCTAssertFalse(
            reachable.contains {
                (generated.graph.objects[$0]?["path"] as? String)?.hasSuffix("Icons.xcassets") == true
            })
    }
}
