import Darwin
import Foundation
@testable import SwiftPodsKit
import SwiftPodsManifest
import SwiftPodsSecurity
import XCTest

final class KitSecurityRegressionTests: XCTestCase {
    private final class ConcurrentOperationResult: @unchecked Sendable {
        private let lock = NSLock()
        private var storedError: (any Error)?

        func run(_ operation: () throws -> Void) {
            do {
                try operation()
            } catch {
                record(error)
            }
        }

        func record(_ error: any Error) {
            lock.withLock {
                if storedError == nil { storedError = error }
            }
        }

        var error: (any Error)? {
            lock.withLock { storedError }
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("swiftpods-scripts-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func packageResolved(_ json: String) throws -> PackageResolved {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Package.resolved")
        try json.write(to: file, atomically: true, encoding: .utf8)
        return try PackageResolved(contentsOf: file)
    }

    func testSharedFileSecurityMetadataRejectsEveryAllocationDimensionBeforeCopying() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("metadata")
        try Data("payload".utf8).write(to: file)
        let descriptor = open(file.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { close(descriptor) }

        func set(_ name: String, _ value: Data) throws {
            guard value.withUnsafeBytes({ bytes in
                name.withCString { fsetxattr(descriptor, $0, bytes.baseAddress, bytes.count, 0, 0) }
            }) == 0 else { throw CocoaError(.fileWriteUnknown) }
        }
        func remove(_ name: String) {
            _ = name.withCString { fremovexattr(descriptor, $0, 0) }
        }
        func limits(
            names: Int = 1_024, count: Int = 8, value: Int = 1_024, aggregate: Int = 2_048,
            aclEntries: Int = 8, aclBytes: Int = 4_096
        ) -> BoundedFileSecurityMetadata.Limits {
            .init(
                maximumAttributeNamesBytes: names, maximumAttributeCount: count,
                maximumAttributeValueBytes: value, maximumAggregateAttributeValueBytes: aggregate,
                maximumACLEntries: aclEntries, maximumACLBytes: aclBytes)
        }
        func assertRejected(
            _ configured: BoundedFileSecurityMetadata.Limits, containing expected: String,
            file: StaticString = #filePath, line: UInt = #line
        ) {
            XCTAssertThrowsError(
                try BoundedFileSecurityMetadata.capture(descriptor, limits: configured), file: file, line: line
            ) { error in
                XCTAssertTrue("\(error)".contains(expected), "\(error)", file: file, line: line)
            }
        }

        // Resource forks are xattr values too; they receive the same per-value and aggregate ceilings.
        let first = "com.apple.ResourceFork"
        let second = "com.swiftpods.tests.metadata-second"
        try set(first, Data(repeating: 0x41, count: 5))
        assertRejected(limits(value: 4), containing: "value exceeds")
        assertRejected(limits(names: 4), containing: "name list exceeds")

        remove(first)
        try set(first, Data(repeating: 0x41, count: 4))
        try set(second, Data(repeating: 0x42, count: 4))
        assertRejected(limits(aggregate: 7), containing: "Aggregate")
        assertRejected(limits(count: 1), containing: "too many extended attributes")

        _ = try ProcessRunner().run(
            "/bin/chmod", ["+a", "everyone allow read", file.path], in: directory)
        assertRejected(limits(aclEntries: 0), containing: "too many entries")
    }

    func testPhaseScriptTreatsTargetPathAsLiteral() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = "Scripts/Target$(touch injected)"
        let paths = TargetScripts.Locations(generated: "Generated", podfile: ".", target: target)
        let scriptDirectory = directory.appendingPathComponent(target)
        try FileManager.default.createDirectory(at: scriptDirectory, withIntermediateDirectories: true)
        try "exit 0\n".write(to: scriptDirectory.appendingPathComponent("prepare.sh"), atomically: true, encoding: .utf8)
        let launcher = directory.appendingPathComponent("phase.sh")
        try TargetScripts.phaseScript(.prepare, paths: paths).write(to: launcher, atomically: true, encoding: .utf8)

        _ = try ProcessRunner().run("/usr/bin/env", ["SRCROOT=\(directory.path)", "/bin/sh", launcher.path], in: directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("injected").path))
        XCTAssertEqual(
            TargetScripts.fileList(.prepare, outputs: false, paths: paths),
            "$(SRCROOT)/Scripts/Target$$(touch injected)/prepare.inputs.xcfilelist")
    }

    func testResourceCopyTreatsArchiveNameAsLiteral() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let relative = "Artifacts/Vendor/Resource name's; $(touch resource).bundle"
        let bundle = directory.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data("value".utf8).write(to: bundle.appendingPathComponent("value.txt"))
        let files = TargetScripts.files(
            scripts: [], resources: [relative], signed: [], fileLists: [:],
            paths: .init(generated: "Generated", podfile: ".", target: "Scripts/App"))
        let finish = directory.appendingPathComponent("finish.sh")
        try files["finish.sh"]!.write(to: finish, atomically: true, encoding: .utf8)
        let output = directory.appendingPathComponent("Build")

        _ = try ProcessRunner().run(
            "/usr/bin/env",
            ["SRCROOT=\(directory.path)", "TARGET_BUILD_DIR=\(output.path)", "UNLOCALIZED_RESOURCES_FOLDER_PATH=Resources", "/bin/sh", finish.path],
            in: directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("resource").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: output.appendingPathComponent("Resources/Resource name's; $(touch resource).bundle/value.txt").path))
        XCTAssertTrue(files["finish.inputs.xcfilelist"]!.contains("Resource name's; $$(touch resource).bundle"))
    }

    func testExplicitEnvironmentDiagnosticsNeverDumpTheEnvironment() throws {
        let manifest = try ManifestReader().evaluate(
            "target 'App' do\n  script_phase name: 'Diagnostic', script: 'true', show_env_vars_in_log: true\nend\n",
            file: "/project/Podfile")
        let files = TargetScripts.files(
            scripts: manifest.targets[0].scriptPhases, resources: [], signed: [], fileLists: [:],
            paths: .init(generated: "Generated", podfile: ".", target: "Scripts/App"))
        let finish = files["finish.sh"]!
        XCTAssertTrue(finish.contains("CONFIGURATION=${CONFIGURATION-}"), finish)
        XCTAssertTrue(finish.contains("LC_ALL=C /usr/bin/tr"), finish)
        XCTAssertTrue(finish.contains("/usr/bin/sed"), finish)
        XCTAssertFalse(finish.contains("env | sort"), finish)
        XCTAssertFalse(finish.contains("TOKEN"), finish)

        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scripts = directory.appendingPathComponent("Scripts/App", isDirectory: true)
        let poisonedPath = directory.appendingPathComponent("poisoned-path", isDirectory: true)
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: poisonedPath, withIntermediateDirectories: true)
        try files["1.sh"]!.write(to: scripts.appendingPathComponent("1.sh"), atomically: true, encoding: .utf8)
        let generated = scripts.appendingPathComponent("finish.sh")
        try finish.write(to: generated, atomically: true, encoding: .utf8)
        for command in ["tr", "sed"] {
            let poison = poisonedPath.appendingPathComponent(command)
            try "#!/bin/sh\nexit 91\n".write(to: poison, atomically: true, encoding: .utf8)
            XCTAssertEqual(chmod(poison.path, 0o700), 0)
        }

        let output = try ProcessRunner().run(
            "/usr/bin/env",
            [
                "SRCROOT=\(directory.path)", "PATH=\(poisonedPath.path)",
                "ACTION=build\n::error title=Injected::payload\u{1b}[31m\rrewritten",
                "CONFIGURATION=Debug", "PLATFORM_NAME=iphoneos", "SDK_NAME=iphoneos", "ARCHS=arm64",
                "/bin/sh", generated.path,
            ], in: directory)
        XCTAssertTrue(output.contains("SwiftPods environment: ACTION=build"), output)
        XCTAssertTrue(output.contains("SwiftPods environment: ::error title=Injected::payload[31mrewritten"), output)
        XCTAssertFalse(output.contains("\n::"), output)
        XCTAssertFalse(output.contains("\u{1b}"), output)
    }

    func testConcurrentWorkspaceWritersSerializeOnTheStableDirectoryInode() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = directory.appendingPathComponent("App.xcworkspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let contents = workspace.appendingPathComponent("contents.xcworkspacedata")
        let original = "<Workspace><FileRef location=\"group:Pods/Pods.xcodeproj\"></FileRef>\n</Workspace>\n"
        try original.write(to: contents, atomically: true, encoding: .utf8)
        let firstResult = ConcurrentOperationResult()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let completed = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            firstResult.run {
                _ = try CocoaPodsIntegration.removePodsProject(
                    fromWorkspace: workspace, beforeAtomicReplacement: {},
                    afterAtomicReplacement: {
                        entered.signal()
                        if release.wait(timeout: .now() + 5) == .timedOut {
                            firstResult.record(NSError(domain: "ConcurrentWorkspaceWriter", code: 1))
                        }
                    })
            }
            completed.signal()
        }
        guard entered.wait(timeout: .now() + 5) == .success else {
            release.signal()
            _ = completed.wait(timeout: .now() + 5)
            XCTFail("The first workspace writer did not reach atomic replacement")
            return
        }
        XCTAssertThrowsError(try CocoaPodsIntegration.removePodsProject(fromWorkspace: workspace)) { error in
            XCTAssertTrue("\(error)".contains("Another process is updating the Xcode workspace"), "\(error)")
        }
        release.signal()
        XCTAssertEqual(completed.wait(timeout: .now() + 5), .success)
        XCTAssertNil(firstResult.error)

        XCTAssertFalse(try String(contentsOf: contents, encoding: .utf8).contains("Pods/Pods.xcodeproj"))
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: workspace.path)
                .contains(where: { $0.hasPrefix(".contents.xcworkspacedata.swiftpods-") }))
    }

    func testGeneratedScriptsUseAbsoluteInfrastructureCommands() throws {
        let files = TargetScripts.files(
            scripts: [], resources: ["Artifacts/Vendor/Assets.bundle"], embedsFrameworks: true,
            signed: [], fileLists: [:],
            paths: .init(generated: "Generated", podfile: ".", target: "Scripts/App"))
        let scripts = [try XCTUnwrap(files["prepare.sh"]), try XCTUnwrap(files["finish.sh"])]
        let expression = try NSRegularExpression(
            pattern: #"(?m)(?:^|[;&|()]\s*)(?:rm|mkdir|basename|xcrun|sed|rsync|codesign|shasum)(?:\s|$)"#)
        for script in scripts {
            XCTAssertEqual(
                expression.numberOfMatches(in: script, range: NSRange(script.startIndex..., in: script)), 0,
                script)
        }
        let finish = scripts[1]
        for command in [
            "/bin/rm", "/bin/mkdir", "/usr/bin/basename", "/usr/bin/xcrun", "/usr/bin/sed",
            "/usr/bin/rsync", "/usr/bin/codesign",
        ] {
            XCTAssertTrue(finish.contains(command), "Missing \(command):\n\(finish)")
        }
        XCTAssertTrue(scripts[0].contains("/usr/bin/shasum"), scripts[0])
    }

    func testEmbeddedFrameworkCleanupRejectsTraversalInItsRecord() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let derived = directory.appendingPathComponent("Derived", isDirectory: true)
        let frameworks = directory.appendingPathComponent("Build/Frameworks", isDirectory: true)
        let victim = directory.appendingPathComponent("victim.framework", isDirectory: true)
        try FileManager.default.createDirectory(at: derived, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: frameworks, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
        try "../../victim\n".write(
            to: derived.appendingPathComponent("SwiftPodsEmbeddedFrameworks.txt"),
            atomically: true, encoding: .utf8)
        let script = directory.appendingPathComponent("embed.sh")
        try TargetScripts.embedFrameworks.write(to: script, atomically: true, encoding: .utf8)

        _ = try ProcessRunner().run(
            "/usr/bin/env",
            [
                "TARGET_BUILD_DIR=\(directory.appendingPathComponent("Build").path)",
                "FRAMEWORKS_FOLDER_PATH=Frameworks", "DERIVED_FILE_DIR=\(derived.path)",
                "EXECUTABLE_PATH=Missing", "BUILT_PRODUCTS_DIR=\(directory.appendingPathComponent("Products").path)",
                "/bin/sh", script.path,
            ], in: directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: victim.path))
    }

    func testDeploymentPinsMatchExactRevisionAndFetchOrigin() throws {
        let revision = String(repeating: "a", count: 40)
        let manifest = try ManifestReader().evaluate(
            "target 'App' do\n  spm 'https://example.com/Team/Kit.git', revision: '\(revision)'\nend\n",
            file: "/project/Podfile")
        let package = manifest.packages[0]
        let exact = PackageResolved(pins: [
            .init(location: "https://example.com/Team/Kit", version: nil, branch: nil, revision: revision)
        ])
        XCTAssertEqual(exact.problems(for: [package]), [])

        let wrongCase = PackageResolved(pins: [
            .init(location: "https://example.com/team/Kit", version: nil, branch: nil, revision: revision)
        ])
        XCTAssertTrue(wrongCase.problems(for: [package])[0].contains("has no pin"))

        let prefixOnly = PackageResolved(pins: [
            .init(location: "https://example.com/Team/Kit", version: nil, branch: nil, revision: revision + String(repeating: "b", count: 24))
        ])
        XCTAssertTrue(prefixOnly.problems(for: [package])[0].contains("pinned to revision"))

        let versionManifest = try ManifestReader().evaluate(
            "target 'App' do\n  spm 'https://example.com/Team/Versioned.git', exact: '1.0.0'\nend\n",
            file: "/project/Podfile")
        let versioned = versionManifest.packages[0]
        for invalid in [nil, "abc", String(repeating: "A", count: 40)] as [String?] {
            let resolved = PackageResolved(pins: [
                .init(location: "https://example.com/Team/Versioned", version: Version(1, 0, 0), branch: nil, revision: invalid)
            ])
            XCTAssertTrue(resolved.problems(for: [versioned])[0].contains("full lowercase commit revision"))
        }
        let versionedExact = PackageResolved(pins: [
            .init(location: "https://example.com/Team/Versioned", version: Version(1, 0, 0), branch: nil, revision: revision)
        ])
        XCTAssertEqual(versionedExact.problems(for: [versioned]), [])

        let metadataManifest = try ManifestReader().evaluate(
            "target 'App' do\n  spm 'https://example.com/Team/Metadata.git', exact: '1.0.0+trusted'\nend\n",
            file: "/project/Podfile")
        let metadataPin = PackageResolved(pins: [
            .init(
                location: "https://example.com/Team/Metadata", version: Version("1.0.0+resolved"), branch: nil,
                revision: revision)
        ])
        XCTAssertEqual(
            metadataPin.problems(for: metadataManifest.packages), [],
            "SwiftPM version identity and exact requirements ignore build metadata")

        let branchManifest = try ManifestReader().evaluate(
            "target 'App' do\n  spm 'https://example.com/Team/Branched.git', branch: 'main'\nend\n",
            file: "/project/Podfile")
        let branched = branchManifest.packages[0]
        let branchWithoutCommit = PackageResolved(pins: [
            .init(location: "https://example.com/Team/Branched", version: nil, branch: "main", revision: nil)
        ])
        XCTAssertTrue(branchWithoutCommit.problems(for: [branched])[0].contains("full lowercase commit revision"))
        let branchExact = PackageResolved(pins: [
            .init(location: "https://example.com/Team/Branched", version: nil, branch: "main", revision: revision)
        ])
        XCTAssertEqual(branchExact.problems(for: [branched]), [])
    }

    func testPackageResolvedDispatchesStrictlyBySchemaVersion() throws {
        let revision = String(repeating: "a", count: 40)
        let state = #"{"branch":null,"revision":"\#(revision)","version":"1.0.0"}"#
        let version1 = try packageResolved(
            #"{"object":{"pins":[{"package":"Kit","repositoryURL":"https://example.com/Kit.git","state":\#(state)}]},"version":1}"#)
        XCTAssertEqual(version1.pins, [
            .init(location: "https://example.com/Kit.git", version: Version(1, 0, 0), branch: nil, revision: revision)
        ])
        for schema in [2, 3] {
            let resolved = try packageResolved(
                #"{"pins":[{"identity":"kit","kind":"remoteSourceControl","location":"https://example.com/Kit.git","state":\#(state)}],"version":\#(schema)}"#)
            XCTAssertEqual(resolved.pins, version1.pins)
        }
        let originHash = String(repeating: "b", count: 64)
        let version3WithOrigin = try packageResolved(
            #"{"originHash":"\#(originHash)","pins":[{"identity":"kit","kind":"remoteSourceControl","location":"https://example.com/Kit.git","state":\#(state)}],"version":3}"#)
        XCTAssertEqual(version3WithOrigin.pins, version1.pins)

        let mixedGraph = try packageResolved(
            #"{"originHash":"\#(originHash)","pins":[{"identity":"kit","kind":"remoteSourceControl","location":"https://example.com/Kit.git","state":\#(state)},{"identity":"mona.linkedlist","kind":"registry","location":"mona.LinkedList","state":{"version":"1.1.0"}}],"version":3}"#)
        XCTAssertEqual(mixedGraph.pins, version1.pins)

        let mixedVersion1 =
            #"{"object":{"pins":[]},"pins":[{"identity":"kit","kind":"remoteSourceControl","location":"https://example.com/Kit.git","state":\#(state)}],"version":1}"#
        XCTAssertThrowsError(try packageResolved(mixedVersion1))
        let mixedVersion3 = #"{"object":{"pins":[]},"pins":[],"version":3}"#
        XCTAssertThrowsError(try packageResolved(mixedVersion3))
    }

    func testPackageResolvedRejectsMalformedUnsupportedAndDuplicatePins() throws {
        let revision = String(repeating: "a", count: 40)
        let state = #"{"revision":"\#(revision)","version":"1.0.0"}"#
        let valid = #"{"identity":"kit","kind":"remoteSourceControl","location":"https://example.com/Kit.git","state":\#(state)}"#
        let invalidPayloads = [
            #"{"pins":[],"version":4}"#,
            #"{"pins":[]}"#,
            #"{"originHash":"abc","pins":[],"version":3}"#,
            #"{"originHash":"\#(String(repeating: "b", count: 64))","pins":[],"version":2}"#,
            #"{"pins":[1],"version":3}"#,
            #"{"pins":[{"identity":"other","kind":"remoteSourceControl","location":"https://example.com/Kit.git","state":\#(state)}],"version":3}"#,
            #"{"pins":[{"identity":"kit","kind":"localSourceControl","location":"https://example.com/Kit.git","state":\#(state)}],"version":3}"#,
            #"{"pins":[{"identity":"mona.other","kind":"registry","location":"mona.LinkedList","state":{"version":"1.1.0"}}],"version":3}"#,
            #"{"pins":[{"identity":"kit","kind":"remoteSourceControl","location":"https://example.com/Kit.git","state":{"revision":"abc","version":"1.0.0"}}],"version":3}"#,
            #"{"pins":[{"identity":"kit","kind":"remoteSourceControl","location":"https://example.com/Kit.git","state":{"revision":"\#(revision)","version":"1.0.0-alpha_1"}}],"version":3}"#,
            #"{"pins":[{"identity":"kit","kind":"remoteSourceControl","location":"https://example.com/Kit.git","state":{"revision":"\#(revision)","version":1}}],"version":3}"#,
            #"{"pins":[\#(valid),{"identity":"kit","kind":"remoteSourceControl","location":"https://example.com/Kit/","state":\#(state)}],"version":3}"#,
            #"{"object":{"pins":[{"package":"Other","repositoryURL":"https://example.com/Kit.git","state":\#(state)}]},"version":1}"#,
            #"{"pins":[{"identity":"kit","kind":"remoteSourceControl","location":"https://example.com/Kit.git","state":{"branch":"main\n::error file=forged::injected","revision":"\#(revision)"}}],"version":3}"#,
            #"{"pins":[{"identity":"kit","kind":"remoteSourceControl","location":"https://example.com/Kit.git","state":{"branch":"refs/heads/../forged","revision":"\#(revision)"}}],"version":3}"#,
        ]
        for payload in invalidPayloads {
            XCTAssertThrowsError(try packageResolved(payload), payload)
        }
    }

    func testPackageResolvedRejectsDuplicateJSONKeysIncludingEscapedAliases() throws {
        let payloads = [
            #"{"pins":[],"version":2,"version":3}"#,
            #"{"pins":[],"version":2,"\u0076ersion":3}"#,
            #"{"pins":[{"identity":"kit","kind":"remoteSourceControl","location":"https://example.com/Kit.git","state":{"revision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","revision":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}}],"version":2}"#,
        ]
        for payload in payloads {
            XCTAssertThrowsError(try packageResolved(payload), payload) { error in
                XCTAssertTrue("\(error)".contains("duplicate JSON object keys"), "\(error)")
            }
        }
    }

    func testSwiftPodsLockRequiresAnExactSchemaAndUniqueJSONKeys() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent(SwiftPodsLock.fileName)
        let revision = String(repeating: "a", count: 40)
        let digest = String(repeating: "b", count: 64)
        let invalidPayloads = [
            #"{"catalogs":[],"version":1,"extra":true}"#,
            #"{"catalogs":[{"entries":[],"revision":"REVISION","url":"https://example.com/catalog.git","extra":true}],"version":1}"#
                .replacingOccurrences(of: "REVISION", with: revision),
            #"{"catalogs":[{"entries":[{"name":"Kit","sha256":"DIGEST","extra":true}],"revision":"REVISION","url":"https://example.com/catalog.git"}],"version":1}"#
                .replacingOccurrences(of: "REVISION", with: revision)
                .replacingOccurrences(of: "DIGEST", with: digest),
            #"{"catalogs":[],"version":1,"version":1}"#,
            #"{"catalogs":[],"version":1,"\u0076ersion":1}"#,
        ]
        for payload in invalidPayloads {
            try payload.write(to: file, atomically: true, encoding: .utf8)
            XCTAssertThrowsError(try SwiftPodsLock(contentsOf: file), payload)
        }

        let unsafeValues = [
            ("catalog", "Kit"),
            ("https://example.com/catalog.git\u{1B}[31m", "Kit"),
            ("https://example.com/" + String(repeating: "a", count: 4_096), "Kit"),
            ("https://example.com/catalog.git", "Kit\nforged"),
            ("https://example.com/catalog.git", String(repeating: "K", count: 4_097)),
        ]
        for (url, name) in unsafeValues {
            let payload: [String: Any] = [
                "version": 1,
                "catalogs": [[
                    "url": url, "revision": revision,
                    "entries": [["name": name, "sha256": digest]],
                ]],
            ]
            try JSONSerialization.data(withJSONObject: payload).write(to: file, options: .atomic)
            XCTAssertThrowsError(try SwiftPodsLock(contentsOf: file), "url=\(url), name=\(name)")
        }

        try #"{"catalogs":[],"version":1}"#.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(try SwiftPodsLock(contentsOf: file), SwiftPodsLock(resolutions: []))
    }

    func testSwiftPodsLockCapsCatalogAndEntryCardinality() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent(SwiftPodsLock.fileName)
        let revision = String(repeating: "a", count: 40)
        let digest = String(repeating: "b", count: 64)

        let catalogs: [[String: Any]] = (0..<33).map { index in
            ["url": "https://example.com/catalog-\(index).git", "revision": revision, "entries": []]
        }
        try JSONSerialization.data(withJSONObject: ["version": 1, "catalogs": catalogs]).write(to: file)
        XCTAssertThrowsError(try SwiftPodsLock(contentsOf: file))

        let entries: [[String: String]] = (0..<257).map { index in
            ["name": "Package\(index)", "sha256": digest]
        }
        try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "catalogs": [["url": "https://example.com/catalog.git", "revision": revision, "entries": entries]],
        ]).write(to: file)
        XCTAssertThrowsError(try SwiftPodsLock(contentsOf: file)) { error in
            XCTAssertTrue("\(error)".contains("unexpected") || "\(error)".contains("256"), "\(error)")
        }
    }

    func testPackageResolvedProjectSnapshotRejectsIntermediateSymlinksAndRestoresByCAS() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = directory.appendingPathComponent("App.xcodeproj", isDirectory: true)
        let resolved = PackageResolved.location(project: project)
        try FileManager.default.createDirectory(at: resolved.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data(#"{"pins":[],"version":3}"#.utf8)
        try original.write(to: resolved)
        let before = try PackageResolved.snapshot(project: project)

        let changed = Data(#"{"originHash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","pins":[],"version":3}"#.utf8)
        try changed.write(to: resolved)
        let after = try PackageResolved.currentSnapshot(project: project)
        XCTAssertNotEqual(before, after)
        try PackageResolved.restore(before, project: project, replacing: after)
        XCTAssertEqual(try Data(contentsOf: resolved), original)

        let concurrent = Data(#"{"originHash":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","pins":[],"version":3}"#.utf8)
        try changed.write(to: resolved)
        let expected = try PackageResolved.currentSnapshot(project: project)
        try concurrent.write(to: resolved)
        XCTAssertThrowsError(try PackageResolved.restore(before, project: project, replacing: expected)) { error in
            XCTAssertTrue("\(error)".contains("concurrent"), "\(error)")
        }
        XCTAssertEqual(try Data(contentsOf: resolved), concurrent)

        let shared = project.appendingPathComponent("project.xcworkspace/xcshareddata")
        try FileManager.default.removeItem(at: shared)
        let outside = directory.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: shared, withDestinationURL: outside)
        XCTAssertThrowsError(try PackageResolved.validateResolverPath(project: project)) { error in
            XCTAssertTrue("\(error)".contains("real directory"), "\(error)")
        }
    }

    func testPackageResolvedRollbackPreservesMetadataAndRejectsMetadataOnlyConcurrentEdits() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = directory.appendingPathComponent("App.xcodeproj", isDirectory: true)
        let resolved = PackageResolved.location(project: project)
        try FileManager.default.createDirectory(at: resolved.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data(#"{"pins":[],"version":3}"#.utf8)
        try original.write(to: resolved)
        XCTAssertEqual(chmod(resolved.path, 0o640), 0)
        let attributeName = "com.swiftpods.tests.package-resolved"
        let originalAttribute = Data("original-metadata".utf8)
        XCTAssertEqual(originalAttribute.withUnsafeBytes {
            setxattr(resolved.path, attributeName, $0.baseAddress, $0.count, 0, 0)
        }, 0)
        _ = try ProcessRunner().run(
            "/bin/chmod", ["+a", "everyone allow read", resolved.path], in: directory)
        var originalTimes = [
            timespec(tv_sec: 1_700_000_001, tv_nsec: 123_456_789),
            timespec(tv_sec: 1_700_000_002, tv_nsec: 987_654_321),
        ]
        XCTAssertEqual(utimensat(AT_FDCWD, resolved.path, &originalTimes, 0), 0)
        var originalStatus = stat()
        XCTAssertEqual(lstat(resolved.path, &originalStatus), 0)
        let originalDescriptor = open(resolved.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(originalDescriptor, 0)
        let originalSecurityMetadata = try FileSecurityMetadata(descriptor: originalDescriptor)
        close(originalDescriptor)
        let before = try PackageResolved.snapshot(project: project)

        let changed = Data(#"{"originHash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","pins":[],"version":3}"#.utf8)
        try changed.write(to: resolved)
        XCTAssertEqual(chmod(resolved.path, 0o600), 0)
        let changedAttribute = Data("resolver-metadata".utf8)
        XCTAssertEqual(changedAttribute.withUnsafeBytes {
            setxattr(resolved.path, attributeName, $0.baseAddress, $0.count, 0, 0)
        }, 0)
        let after = try PackageResolved.currentSnapshot(project: project)
        try PackageResolved.restore(before, project: project, replacing: after)

        var restoredStatus = stat()
        XCTAssertEqual(lstat(resolved.path, &restoredStatus), 0)
        XCTAssertEqual(restoredStatus.st_mode & 0o7777, originalStatus.st_mode & 0o7777)
        XCTAssertEqual(restoredStatus.st_atimespec.tv_sec, originalStatus.st_atimespec.tv_sec)
        XCTAssertEqual(restoredStatus.st_atimespec.tv_nsec, originalStatus.st_atimespec.tv_nsec)
        XCTAssertEqual(restoredStatus.st_mtimespec.tv_sec, originalStatus.st_mtimespec.tv_sec)
        XCTAssertEqual(restoredStatus.st_mtimespec.tv_nsec, originalStatus.st_mtimespec.tv_nsec)
        var restoredAttribute = Data(count: originalAttribute.count)
        let restoredAttributeCount = restoredAttribute.withUnsafeMutableBytes {
            getxattr(resolved.path, attributeName, $0.baseAddress, $0.count, 0, 0)
        }
        XCTAssertEqual(restoredAttributeCount, originalAttribute.count)
        XCTAssertEqual(restoredAttribute, originalAttribute)
        let restoredDescriptor = open(resolved.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(restoredDescriptor, 0)
        let restoredSecurityMetadata = try FileSecurityMetadata(descriptor: restoredDescriptor)
        close(restoredDescriptor)
        XCTAssertEqual(restoredSecurityMetadata, originalSecurityMetadata)
        XCTAssertEqual(try Data(contentsOf: resolved), original)

        try changed.write(to: resolved)
        XCTAssertEqual(changedAttribute.withUnsafeBytes {
            setxattr(resolved.path, attributeName, $0.baseAddress, $0.count, 0, 0)
        }, 0)
        let expected = try PackageResolved.currentSnapshot(project: project)
        let concurrentAttribute = Data("concurrent-metadata".utf8)
        XCTAssertEqual(concurrentAttribute.withUnsafeBytes {
            setxattr(resolved.path, attributeName, $0.baseAddress, $0.count, 0, 0)
        }, 0)
        XCTAssertThrowsError(try PackageResolved.restore(before, project: project, replacing: expected)) { error in
            XCTAssertTrue("\(error)".contains("concurrent"), "\(error)")
        }
        var preservedAttribute = Data(count: concurrentAttribute.count)
        let preservedAttributeCount = preservedAttribute.withUnsafeMutableBytes {
            getxattr(resolved.path, attributeName, $0.baseAddress, $0.count, 0, 0)
        }
        XCTAssertEqual(preservedAttributeCount, concurrentAttribute.count)
        XCTAssertEqual(preservedAttribute, concurrentAttribute)
        XCTAssertEqual(try Data(contentsOf: resolved), changed)
    }

    func testPackageResolvedRollbackRemovesOnlyResolverCreatedDirectorySuffix() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = directory.appendingPathComponent("App.xcodeproj", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let resolved = PackageResolved.location(project: project)
        let contents = Data(#"{"pins":[],"version":3}"#.utf8)

        let beforeWorkspace = try PackageResolved.currentSnapshot(project: project)
        try FileManager.default.createDirectory(at: resolved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: resolved)
        let afterWorkspace = try PackageResolved.currentSnapshot(project: project)
        try PackageResolved.restore(beforeWorkspace, project: project, replacing: afterWorkspace)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: project.appendingPathComponent("project.xcworkspace").path))

        let workspace = project.appendingPathComponent("project.xcworkspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)
        let beforeSharedData = try PackageResolved.currentSnapshot(project: project)
        try FileManager.default.createDirectory(at: resolved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: resolved)
        let afterSharedData = try PackageResolved.currentSnapshot(project: project)
        try PackageResolved.restore(beforeSharedData, project: project, replacing: afterSharedData)
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: workspace.appendingPathComponent("xcshareddata").path))
    }

    func testPackageResolvedRollbackDoesNotReverseOverAConcurrentReplacement() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = directory.appendingPathComponent("App.xcodeproj", isDirectory: true)
        let resolved = PackageResolved.location(project: project)
        try FileManager.default.createDirectory(at: resolved.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data(#"{"pins":[],"version":3}"#.utf8)
        let resolver = Data(#"{"originHash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","pins":[],"version":3}"#.utf8)
        let firstConcurrent = Data("first concurrent replacement".utf8)
        let secondConcurrent = Data("second concurrent replacement".utf8)
        try original.write(to: resolved)
        let before = try PackageResolved.snapshot(project: project)
        try resolver.write(to: resolved)
        let expected = try PackageResolved.currentSnapshot(project: project)

        XCTAssertThrowsError(try PackageResolved.restore(
            before, project: project, replacing: expected,
            afterSwapForTesting: { try! firstConcurrent.write(to: resolved) },
            beforeReverseSwapForTesting: { try! secondConcurrent.write(to: resolved, options: .atomic) }
        )) { error in
            XCTAssertTrue("\(error)".contains("before rollback reversal"), "\(error)")
        }
        XCTAssertEqual(try Data(contentsOf: resolved), secondConcurrent)
        let recoveryNames = try FileManager.default.contentsOfDirectory(atPath: resolved.deletingLastPathComponent().path)
            .filter { $0.hasPrefix(".Package.resolved.swiftpods-") }
        XCTAssertEqual(recoveryNames.count, 1)
        XCTAssertEqual(
            try Data(contentsOf: resolved.deletingLastPathComponent().appendingPathComponent(recoveryNames[0])),
            resolver)
    }

    func testPackageResolvedMissingTargetRejectsReplacedRecoverySource() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = directory.appendingPathComponent("App.xcodeproj", isDirectory: true)
        let resolved = PackageResolved.location(project: project)
        try FileManager.default.createDirectory(at: resolved.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data(#"{"pins":[],"version":3}"#.utf8)
        let attacker = Data("attacker recovery source".utf8)
        try original.write(to: resolved)
        let before = try PackageResolved.snapshot(project: project)
        try FileManager.default.removeItem(at: resolved)
        let missing = try PackageResolved.currentSnapshot(project: project)

        XCTAssertThrowsError(try PackageResolved.restore(
            before, project: project, replacing: missing,
            beforeMissingSourceRenameForTesting: {
                let quarantine = try! FileManager.default.contentsOfDirectory(
                    at: resolved.deletingLastPathComponent(), includingPropertiesForKeys: nil
                ).first { $0.lastPathComponent.hasPrefix(".swiftpods-package-resolved-source-quarantine-") }!
                try! attacker.write(to: quarantine.appendingPathComponent("recovery"), options: .atomic)
            }
        )) { error in
            XCTAssertTrue("\(error)".contains("source changed before installation"), "\(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: resolved.path))
        let quarantine = try XCTUnwrap(FileManager.default.contentsOfDirectory(
            at: resolved.deletingLastPathComponent(), includingPropertiesForKeys: nil
        ).first { $0.lastPathComponent.hasPrefix(".swiftpods-package-resolved-source-quarantine-") })
        XCTAssertEqual(try Data(contentsOf: quarantine.appendingPathComponent("recovery")), attacker)
        XCTAssertEqual(try Data(contentsOf: quarantine.appendingPathComponent("original-evidence")), original)
    }

    func testPackageResolvedAbsentOriginalCleanupQuarantinesAReplacedRecoveryName() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = directory.appendingPathComponent("App.xcodeproj", isDirectory: true)
        let resolved = PackageResolved.location(project: project)
        try FileManager.default.createDirectory(at: resolved.deletingLastPathComponent(), withIntermediateDirectories: true)
        let resolver = Data(#"{"pins":[],"version":3}"#.utf8)
        let attacker = Data("attacker absent-original cleanup replacement".utf8)
        let before = try PackageResolved.currentSnapshot(project: project)
        try resolver.write(to: resolved)
        let expected = try PackageResolved.currentSnapshot(project: project)

        XCTAssertThrowsError(try PackageResolved.restore(
            before, project: project, replacing: expected,
            beforeCleanupForTesting: {
                let recovery = try! FileManager.default.contentsOfDirectory(
                    at: resolved.deletingLastPathComponent(), includingPropertiesForKeys: nil
                ).first { $0.lastPathComponent.hasPrefix(".Package.resolved.swiftpods-removed-") }!
                try! attacker.write(to: recovery, options: .atomic)
            }
        )) { error in
            XCTAssertTrue("\(error)".contains("evidence remains"), "\(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: resolved.path))
        let quarantine = try XCTUnwrap(FileManager.default.contentsOfDirectory(
            at: resolved.deletingLastPathComponent(), includingPropertiesForKeys: nil
        ).first { $0.lastPathComponent.hasPrefix(".swiftpods-package-resolved-cleanup-quarantine-") })
        XCTAssertEqual(try Data(contentsOf: quarantine.appendingPathComponent("displaced")), attacker)
    }

    func testRollbackQuarantineClearsInheritedExtendedACLs() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try ProcessRunner().run(
            "/bin/chmod",
            ["+a", "everyone allow read,write,execute,file_inherit,directory_inherit", directory.path],
            in: directory)
        let inheritanceProbe = directory.appendingPathComponent("inheritance-probe", isDirectory: true)
        try FileManager.default.createDirectory(at: inheritanceProbe, withIntermediateDirectories: false)
        XCTAssertTrue(try SecureFileTree.hasExtendedACL(inheritanceProbe))
        try FileManager.default.removeItem(at: inheritanceProbe)

        let parent = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        XCTAssertGreaterThanOrEqual(parent, 0)
        defer { close(parent) }
        let quarantine = try RollbackQuarantine(parent: parent, prefix: "acl-test")
        let quarantineURL = directory.appendingPathComponent(quarantine.name, isDirectory: true)
        XCTAssertFalse(try SecureFileTree.hasExtendedACL(quarantineURL))
        var status = stat()
        XCTAssertEqual(lstat(quarantineURL.path, &status), 0)
        XCTAssertEqual(status.st_mode & 0o777, 0o700)
        try quarantine.finish()
        XCTAssertFalse(FileManager.default.fileExists(atPath: quarantineURL.path))
    }

    func testRollbackCleanupQuarantinesReplacedRecoveryNames() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = directory.appendingPathComponent("App.xcodeproj", isDirectory: true)
        let resolved = PackageResolved.location(project: project)
        try FileManager.default.createDirectory(at: resolved.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data(#"{"pins":[],"version":3}"#.utf8)
        let resolver = Data(#"{"originHash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","pins":[],"version":3}"#.utf8)
        let attacker = Data("attacker cleanup replacement".utf8)
        try original.write(to: resolved)
        let before = try PackageResolved.snapshot(project: project)
        try resolver.write(to: resolved)
        let expected = try PackageResolved.currentSnapshot(project: project)
        XCTAssertThrowsError(try PackageResolved.restore(
            before, project: project, replacing: expected,
            beforeCleanupForTesting: {
                let recovery = try! FileManager.default.contentsOfDirectory(
                    at: resolved.deletingLastPathComponent(), includingPropertiesForKeys: nil
                ).first { $0.lastPathComponent.hasPrefix(".Package.resolved.swiftpods-") }!
                try! attacker.write(to: recovery, options: .atomic)
            }
        )) { error in
            XCTAssertTrue("\(error)".contains("evidence remains"), "\(error)")
        }
        XCTAssertEqual(try Data(contentsOf: resolved), original)
        let packageQuarantine = try XCTUnwrap(FileManager.default.contentsOfDirectory(
            at: resolved.deletingLastPathComponent(), includingPropertiesForKeys: nil
        ).first { $0.lastPathComponent.hasPrefix(".swiftpods-package-resolved-cleanup-quarantine-") })
        XCTAssertEqual(try Data(contentsOf: packageQuarantine.appendingPathComponent("displaced")), attacker)

        let projectFile = directory.appendingPathComponent("project.pbxproj")
        try original.write(to: projectFile)
        XCTAssertThrowsError(try Installer.testTransactionRollback(
            at: projectFile, installed: resolver, afterSwap: {}, beforeReverseSwap: {},
            beforeCleanup: {
                let recovery = try! FileManager.default.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: nil
                ).first { $0.lastPathComponent.hasPrefix(".project.pbxproj.rollback-") }!
                try! attacker.write(to: recovery, options: .atomic)
            }
        )) { error in
            XCTAssertTrue("\(error)".contains("evidence remains"), "\(error)")
        }
        XCTAssertEqual(try Data(contentsOf: projectFile), original)
        let projectQuarantine = try XCTUnwrap(FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ).first { $0.lastPathComponent.hasPrefix(".swiftpods-project-cleanup-quarantine-") })
        XCTAssertEqual(try Data(contentsOf: projectQuarantine.appendingPathComponent("displaced")), attacker)
    }

    func testProjectRollbackDoesNotReverseOverAConcurrentReplacement() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("project.pbxproj")
        let original = Data("original project".utf8)
        let installed = Data("installed project".utf8)
        let firstConcurrent = Data("first concurrent replacement".utf8)
        let secondConcurrent = Data("second concurrent replacement".utf8)
        try original.write(to: file)

        XCTAssertThrowsError(try Installer.testTransactionRollback(
            at: file, installed: installed,
            afterSwap: { try! firstConcurrent.write(to: file) },
            beforeReverseSwap: { try! secondConcurrent.write(to: file, options: .atomic) }
        )) { error in
            XCTAssertTrue("\(error)".contains("before rollback reversal"), "\(error)")
        }
        XCTAssertEqual(try Data(contentsOf: file), secondConcurrent)
        let recoveryNames = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix(".project.pbxproj.rollback-") }
        XCTAssertEqual(recoveryNames.count, 1)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(recoveryNames[0])), installed)
    }

    func testPackageResolvedRejectsNonRegularAndOversizedFiles() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertThrowsError(try PackageResolved(contentsOf: directory)) { error in
            XCTAssertTrue("\(error)".contains("regular file"), "\(error)")
        }

        let real = directory.appendingPathComponent("real.resolved")
        try #"{"pins":[],"version":3}"#.write(to: real, atomically: true, encoding: .utf8)
        let symlink = directory.appendingPathComponent("linked.resolved")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: real)
        XCTAssertThrowsError(try PackageResolved(contentsOf: symlink)) { error in
            XCTAssertTrue("\(error)".contains("regular file"), "\(error)")
        }

        let fifo = directory.appendingPathComponent("fifo.resolved")
        XCTAssertEqual(fifo.path.withCString { mkfifo($0, 0o600) }, 0)
        XCTAssertThrowsError(try PackageResolved(contentsOf: fifo)) { error in
            XCTAssertTrue("\(error)".contains("regular file"), "\(error)")
        }

        let oversized = directory.appendingPathComponent("Package.resolved")
        XCTAssertTrue(FileManager.default.createFile(atPath: oversized.path, contents: Data()))
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(atOffset: UInt64(16 * 1_024 * 1_024 + 1))
        try handle.close()
        XCTAssertThrowsError(try PackageResolved(contentsOf: oversized)) { error in
            XCTAssertTrue("\(error)".contains("16 MiB limit"), "\(error)")
        }
    }

    func testSwiftPodsLockRejectsFIFOWithoutBlocking() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fifo = directory.appendingPathComponent(SwiftPodsLock.fileName)
        XCTAssertEqual(fifo.path.withCString { mkfifo($0, 0o600) }, 0)
        XCTAssertThrowsError(try SwiftPodsLock(contentsOf: fifo))
    }

    func testSwiftPodsLockWriteRollsBackLateFailuresForExistingAndAbsentFiles() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent(SwiftPodsLock.fileName)
        let noncanonical = Data("{ \"catalogs\" : [ ], \"version\" : 1 }\n".utf8)
        try noncanonical.write(to: file)
        let lock = try SwiftPodsLock(contentsOf: file)
        let existing = try SwiftPodsLock.read(at: file).state

        XCTAssertThrowsError(try lock.write(
            to: file, replacing: existing,
            _beforeFinalPathCheck: { throw SwiftPodsError("forced late failure") }))
        XCTAssertEqual(try Data(contentsOf: file), noncanonical)

        try FileManager.default.removeItem(at: file)
        let absent = try SwiftPodsLock.deferredRead(at: file).replacementState()
        XCTAssertThrowsError(try lock.write(
            to: file, replacing: absent,
            _beforeFinalPathCheck: { throw SwiftPodsError("forced late failure") }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testSwiftPodsLockHashesItsActualTemporaryBytesBeforeInstallation() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent(SwiftPodsLock.fileName)
        let noncanonical = Data("{ \"catalogs\" : [ ], \"version\" : 1 }\n".utf8)
        try noncanonical.write(to: file)
        let lock = try SwiftPodsLock(contentsOf: file)
        let existing = try SwiftPodsLock.read(at: file).state
        var attacker = try lock.data()
        attacker[attacker.startIndex] ^= 0x01

        XCTAssertThrowsError(try lock.write(
            to: file, replacing: existing,
            _beforeTemporaryInstall: {
                let temporary = try XCTUnwrap(FileManager.default.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: nil
                ).first { $0.lastPathComponent.hasPrefix(".SwiftPods.lock.tmp-") })
                try attacker.write(to: temporary)
            }
        )) { error in
            XCTAssertTrue("\(error)".contains("temporary source bytes changed"), "\(error)")
        }
        XCTAssertEqual(try Data(contentsOf: file), noncanonical)
    }

    func testSwiftPodsLockReverseSwapsAConcurrentReplacementWithoutDeletingIt() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent(SwiftPodsLock.fileName)
        let displacedOriginal = directory.appendingPathComponent("original.lock")
        let original = Data("{ \"catalogs\" : [ ], \"version\" : 1 }\n".utf8)
        let concurrent = Data("{\"catalogs\":[],\"version\":1} \n".utf8)
        try original.write(to: file)
        let lock = try SwiftPodsLock(contentsOf: file)
        let expected = try SwiftPodsLock.read(at: file).state

        XCTAssertThrowsError(try lock.write(
            to: file, replacing: expected,
            _beforeReplacementSwap: {
                try FileManager.default.moveItem(at: file, to: displacedOriginal)
                try concurrent.write(to: file)
            }
        )) { error in
            XCTAssertTrue("\(error)".contains("changed after it was read"), "\(error)")
        }
        XCTAssertEqual(try Data(contentsOf: file), concurrent)
        XCTAssertEqual(try Data(contentsOf: displacedOriginal), original)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains {
            $0.hasPrefix(".SwiftPods.lock.tmp-")
        })
    }

    func testSwiftPodsLockCleanupQuarantinesAReplacedRecoveryName() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent(SwiftPodsLock.fileName)
        let noncanonical = Data("{ \"catalogs\" : [ ], \"version\" : 1 }\n".utf8)
        let attacker = Data("attacker lock cleanup replacement".utf8)
        try noncanonical.write(to: file)
        let lock = try SwiftPodsLock(contentsOf: file)
        let existing = try SwiftPodsLock.read(at: file).state

        XCTAssertThrowsError(try lock.write(
            to: file, replacing: existing,
            _beforeCleanup: {
                let recovery = try XCTUnwrap(FileManager.default.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: nil
                ).first { $0.lastPathComponent.hasPrefix(".SwiftPods.lock.tmp-") })
                try attacker.write(to: recovery, options: .atomic)
            }
        )) { error in
            XCTAssertTrue("\(error)".contains("rollback failed"), "\(error)")
        }
        XCTAssertEqual(try Data(contentsOf: file), try lock.data())
        let quarantine = try XCTUnwrap(FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ).first { $0.lastPathComponent.hasPrefix(".swiftpods-lock-cleanup-quarantine-") })
        XCTAssertEqual(try Data(contentsOf: quarantine.appendingPathComponent("displaced")), attacker)
    }
}
