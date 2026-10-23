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

    func testFrameworkCopyKeepsLinksInsideTheAppAndPreservesSourceFiles() throws {
        for mode in ["relative", "absolute-binary", "absolute-directory", "parent-relative", "escaping"] {
            let engine = try engine()
            let user = try NativePBX(engine.project.appendingPathComponent("Demo.xcodeproj/project.pbxproj"))
            let target = user.add("target", ["isa": "PBXNativeTarget", "buildPhases": []])
            let source = engine.project.appendingPathComponent("SDK Input $ ' 🧩\n/SDK.framework")
            let version = source.appendingPathComponent("Versions/A")
            try FileManager.default.createDirectory(at: version, withIntermediateDirectories: true)
            let original = Data("SDK original bytes\n".utf8)
            try original.write(to: version.appendingPathComponent("SDK"))
            try FileManager.default.createSymbolicLink(
                atPath: source.appendingPathComponent("Versions/Current").path,
                withDestinationPath: mode == "absolute-directory" ? version.path : "A")
            let link =
                mode == "absolute-binary"
                ? version.appendingPathComponent("SDK").path
                : mode == "parent-relative" ? "Versions/A/../A/SDK" : "Versions/Current/SDK"
            try FileManager.default.createSymbolicLink(
                atPath: source.appendingPathComponent("SDK").path, withDestinationPath: link)
            if mode == "escaping" {
                let external = engine.project.appendingPathComponent("outside.txt")
                try original.write(to: external)
                try FileManager.default.createSymbolicLink(
                    at: version.appendingPathComponent("external"), withDestinationURL: external)
            }
            try engine.consumerCopyPhase(
                ["Debug": [NativeConsumerCopy(source: engine.consumerPath(source), destination: "SDK.framework")]],
                kind: "frameworks", label: "Pods-Demo", target: target, user: user)
            let script = engine.project.appendingPathComponent(
                "Pods/Target Support Files/Pods-Demo/Pods-Demo-frameworks.sh")
            var environment = ProcessInfo.processInfo.environment
            environment.merge([
                "PODS_ROOT": engine.project.appendingPathComponent("Pods").path,
                "TARGET_BUILD_DIR": engine.project.appendingPathComponent("Build").path,
                "FRAMEWORKS_FOLDER_PATH": "Frameworks", "CONFIGURATION": "Debug", "ARCHS": "",
                "CODE_SIGNING_ALLOWED": "NO", "DERIVED_FILE_DIR": engine.project.appendingPathComponent("Derived").path,
            ]) { _, new in new }
            let copied = try ToolProcess.run("/bin/sh", [script.path], environment: environment)
            XCTAssertEqual(try Data(contentsOf: version.appendingPathComponent("SDK")), original)
            if mode == "escaping" {
                XCTAssertNotEqual(copied.status, 0)
                continue
            }
            XCTAssertEqual(copied.status, 0, String(decoding: copied.error, as: UTF8.self))
            let installed = engine.project.appendingPathComponent("Build/Frameworks/SDK.framework")
            let binary = installed.appendingPathComponent("SDK")
            XCTAssertTrue(NativePath.isDescendant(binary.resolvingSymlinksInPath(), of: installed))
            if mode == "relative" {
                XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: binary.path), link)
            }
            if mode == "absolute-directory" {
                XCTAssertEqual(
                    try FileManager.default.destinationOfSymbolicLink(
                        atPath: installed.appendingPathComponent("Versions/Current").path),
                    "A")
            }
            try FileManager.default.moveItem(at: source, to: source.appendingPathExtension("hidden"))
            XCTAssertEqual(try Data(contentsOf: binary), original)
        }
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

    func testBundleCopiesRefreshNestedFilesEvenWhenSizeAndTimestampsMatch() throws {
        let engine = try engine()
        let user = try NativePBX(engine.project.appendingPathComponent("Demo.xcodeproj/project.pbxproj"))
        let target = user.add("target", ["isa": "PBXNativeTarget", "buildPhases": []])
        let source = engine.project.appendingPathComponent("Shared.bundle/Contents/value.txt")
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let bundle = source.deletingLastPathComponent().deletingLastPathComponent()
        try engine.consumerCopyPhase(
            ["Debug": [NativeConsumerCopy(source: engine.consumerPath(bundle), destination: "Shared.bundle")]],
            kind: "resources", label: "Pods-Demo", target: target, user: user)
        var environment = ProcessInfo.processInfo.environment
        environment.merge([
            "PODS_ROOT": engine.project.appendingPathComponent("Pods").path,
            "TARGET_BUILD_DIR": engine.project.appendingPathComponent("Build").path,
            "UNLOCALIZED_RESOURCES_FOLDER_PATH": "Resources", "CONFIGURATION": "Debug",
            "DERIVED_FILE_DIR": engine.project.appendingPathComponent("Derived").path,
        ]) { _, new in new }
        let script = engine.project.appendingPathComponent("Pods/Target Support Files/Pods-Demo/Pods-Demo-resources.sh")
        let destination = engine.project.appendingPathComponent("Build/Resources/Shared.bundle/Contents/value.txt")
        for value in ["first", "other"] {
            try Data(value.utf8).write(to: source)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: source.path)
            let copied = try ToolProcess.run("/bin/sh", [script.path], environment: environment)
            XCTAssertEqual(copied.status, 0, String(decoding: copied.error, as: UTF8.self))
            XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), value)
        }
    }

    func testCombinedCopyPlansRejectAliasedDestinationsBeforeChangingProjectsOrSupportFiles() throws {
        for kind in ["resources", "frameworks"] {
            for (first, second) in [
                ("Shared.bundle", "Shared.bundle"), ("Shared.bundle", "shared.bundle"),
                ("Straße.bundle", "STRASSE.bundle"),
            ] {
                let engine = try engine()
                let user = try NativePBX(engine.project.appendingPathComponent("Demo.xcodeproj/project.pbxproj"))
                let target = user.add("target", ["isa": "PBXNativeTarget", "buildPhases": []])
                let original = try jsonData(user.objects)
                let copies = [
                    NativeConsumerCopy(
                        source: NativeConsumerPath(variable: "BUILT_PRODUCTS_DIR", relative: "Generated.bundle"),
                        destination: first),
                    NativeConsumerCopy(
                        source: NativeConsumerPath(variable: "BUILT_PRODUCTS_DIR", relative: "Loose.bundle"),
                        destination: second),
                ]
                XCTAssertThrowsError(
                    try engine.consumerCopyPhase(
                        ["Debug": copies], kind: kind, label: "Pods-Demo", target: target, user: user)
                ) {
                    XCTAssertEqual(
                        ($0 as? Diagnostic)?.code, kind == "frameworks" ? "SP-DUPLICATE-SDK" : "SP-XCODE-RESOURCE")
                }
                XCTAssertEqual(try jsonData(user.objects), original)
                XCTAssertFalse(
                    FileManager.default.fileExists(
                        atPath: engine.project.appendingPathComponent("Pods/Target Support Files").path))
            }
        }
    }

    func testCopyNamespacesAreIndependentAcrossConfigurationsAndPermitIdenticalCopies() throws {
        let engine = try engine()
        let user = try NativePBX(engine.project.appendingPathComponent("Demo.xcodeproj/project.pbxproj"))
        let target = user.add("target", ["isa": "PBXNativeTarget", "buildPhases": []])
        let first = NativeConsumerCopy(
            source: NativeConsumerPath(variable: "BUILT_PRODUCTS_DIR", relative: "First.bundle"),
            destination: "Shared.bundle")
        let second = NativeConsumerCopy(
            source: NativeConsumerPath(variable: "BUILT_PRODUCTS_DIR", relative: "Second.bundle"),
            destination: "Shared.bundle")
        try engine.consumerCopyPhase(
            ["Debug": [first, first], "Release": [second]], kind: "resources", label: "Pods-Demo", target: target,
            user: user)
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
