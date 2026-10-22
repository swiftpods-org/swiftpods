import XCTest

@testable import SwiftPodsCore

final class NativeSwiftPackagePkgConfigTests: XCTestCase {
    private func fixture(output: String, status: Int = 0) throws -> (URL, NativePBX, NativeSwiftPackageGraph) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let sources = root.appendingPathComponent("checkouts/SDK/Sources/CSystem")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try Data("module CSystem { export * }\n".utf8).write(to: sources.appendingPathComponent("module.modulemap"))
        try jsonData([
            "object": [
                "dependencies": [
                    [
                        "packageRef": ["identity": "sdk", "location": "https://example.invalid/sdk.git"],
                        "state": ["name": "sourceControlCheckout"], "subpath": "SDK",
                    ]
                ]
            ]
        ]).write(to: root.appendingPathComponent("workspace-state.json"))
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let tool = bin.appendingPathComponent("pkg-config")
        let script = """
            #!/bin/sh
            [ "$1" = --cflags ] && [ "$2" = -- ] && [ "$3" = fixture ] || exit 77
            [ "$PKG_CONFIG_PATH" = expected ] || exit 78
            printf x >> \(NativeShellString.quote(root.appendingPathComponent("calls").path))
            printf '%s' \(NativeShellString.quote(output))
            exit \(status)
            """
        try Data(script.utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        let user = try NativePBX(root.appendingPathComponent("App.xcodeproj/project.pbxproj"))
        let maps = NativeSwiftPackageModuleMaps(directory: root.appendingPathComponent("Maps"))
        let graph = try NativeSwiftPackageGraph(
            directory: root,
            environment: ["PATH": bin.path, "PKG_CONFIG_PATH": "expected"], moduleMaps: maps
        ) { _ in
            [
                "products": [["name": "SDK", "targets": ["CSystem"]]],
                "targets": [["name": "CSystem", "type": "system", "pkgConfig": "fixture"]],
            ]
        }
        return (root, user, graph)
    }

    private func exported(_ user: NativePBX, graph: NativeSwiftPackageGraph, platform: String = "osx") throws
        -> NativeSwiftPackageCompileSettings.Interface
    {
        let declaration = try NativeSwiftPackageDeclaration([
            "git": "https://example.invalid/sdk.git", "exact": "1.0.0", "products": ["SDK"], "link": false,
        ])
        return try NativeSwiftPackageCompileSettings.interface(
            [declaration], graph: graph,
            destination: .init(
                sdk: platform == "osx" ? "macosx" : "iphoneos", platform: platform,
                variant: "device", architecture: "arm64"), user: user)
    }

    func testPkgConfigExportsQuotedPathsAndCompilerFlagsAndIsCachedAcrossDestinations() throws {
        let (root, user, graph) = try fixture(
            output:
                "-I\"/opt/SDK headers\" -F'/opt/SDK frameworks' -DAPI_ENABLED=1 -pthread -isystem '/opt/System headers'\n"
        )
        for platform in ["osx", "ios"] {
            let value = try exported(user, graph: graph, platform: platform)
            XCTAssertTrue(value.headers.contains(user.buildSettingPath(URL(fileURLWithPath: "/opt/SDK headers"))))
            XCTAssertEqual(value.frameworks, [user.buildSettingPath(URL(fileURLWithPath: "/opt/SDK frameworks"))])
            let flags = value.values["SWIFTPODS_SPM_CFLAGS"] ?? []
            XCTAssertTrue(flags.contains(NativeBuildSetting.quoted("-DAPI_ENABLED=1")))
            XCTAssertTrue(flags.contains(NativeBuildSetting.quoted("-pthread")))
            XCTAssertTrue(flags.contains(NativeBuildSetting.quoted("-isystem")))
            XCTAssertTrue(
                flags.contains(
                    NativeBuildSetting.quoted(user.buildSettingPath(URL(fileURLWithPath: "/opt/System headers")))))
        }
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("calls"), encoding: .utf8), "x")
    }

    func testPkgConfigFailuresDoNotSilentlyProduceIncompleteInterfaces() throws {
        let (_, user, graph) = try fixture(output: "missing dependency", status: 1)
        XCTAssertThrowsError(try exported(user, graph: graph)) {
            XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-SPM-PKGCONFIG")
        }
    }

    func testPkgConfigPreservesHeaderAndFrameworkSearchOrderWhileRemovingDuplicates() throws {
        let (_, user, graph) = try fixture(
            output:
                "-I'/opt/z headers' -I '/opt/a headers' -I'/opt/z headers' -F/opt/z-frameworks -F /opt/a-frameworks -F/opt/z-frameworks"
        )
        let value = try exported(user, graph: graph)
        let headers = ["/opt/z headers", "/opt/a headers"].map {
            NativeBuildSetting.quoted(user.buildSettingPath(URL(fileURLWithPath: $0)))
        }
        let frameworks = ["/opt/z-frameworks", "/opt/a-frameworks"].map {
            NativeBuildSetting.quoted(user.buildSettingPath(URL(fileURLWithPath: $0)))
        }
        XCTAssertEqual(Array((value.values["SWIFTPODS_SPM_HEADERS"] ?? []).prefix(2)), headers)
        XCTAssertEqual(value.values["SWIFTPODS_SPM_FRAMEWORKS"], frameworks)
        XCTAssertEqual(value.values["SWIFTPODS_SPM_HEADERS"]?.filter { $0 == headers[0] }.count, 1)
    }

    func testPkgConfigHeaderPrecedenceCompilesTheSelectedPublicInterface() throws {
        let (root, user, graph) = try fixture(output: "-Iz-preferred -Ia-fallback")
        let package = root.appendingPathComponent("checkouts/SDK")
        for (directory, selection) in [("z-preferred", 7), ("a-fallback", 99)] {
            let path = package.appendingPathComponent(directory)
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            try Data("#define SDK_CHOICE \(selection)\n".utf8).write(to: path.appendingPathComponent("selected.h"))
        }
        let sources = package.appendingPathComponent("Sources/CSystem")
        try Data("module CSystem [system] { header \"shim.h\" export * }\n".utf8)
            .write(to: sources.appendingPathComponent("module.modulemap"))
        try Data("#include <selected.h>\n#if SDK_CHOICE != 7\n#error Wrong SDK header selected\n#endif\n".utf8)
            .write(to: sources.appendingPathComponent("shim.h"))
        let consumer = root.appendingPathComponent("consumer.m")
        try Data("@import CSystem;\n".utf8).write(to: consumer)
        let value = try exported(user, graph: graph)
        let scope = NativeBuildSettingScope(["SRCROOT": root.path])
        let headers = try (value.values["SWIFTPODS_SPM_HEADERS"] ?? []).map {
            "-I" + (try scope.expandedPathExpression($0))
        }
        let flags = try (value.values["SWIFTPODS_SPM_CFLAGS"] ?? []).map { try scope.expandedPathExpression($0) }
        let response = root.appendingPathComponent("compiler.rsp")
        try Data((headers + flags).joined(separator: "\n").utf8).write(to: response)
        let result = try ToolProcess.run(
            "/usr/bin/xcrun",
            [
                "clang", "-Werror", "-fmodules", "-fsyntax-only",
                "-fmodules-cache-path=" + root.appendingPathComponent("ModuleCache").path,
                "@" + response.path, consumer.path,
            ])
        XCTAssertEqual(result.status, 0, String(decoding: result.error, as: UTF8.self))
    }

    func testMalformedOrLinkerFlagsCannotBecomeCompilerInterfaceFlags() throws {
        for text in ["-I'broken", "-I", "-Xlinker -all_load", "-Wl,-all_load", "-L/opt/lib -lSDK"] {
            let (_, user, graph) = try fixture(output: text)
            XCTAssertThrowsError(try exported(user, graph: graph), text) {
                XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-SPM-PKGCONFIG")
            }
        }
    }
}
