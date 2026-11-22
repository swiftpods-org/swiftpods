import CryptoKit
import Darwin
import Foundation
@testable import SwiftPodsKit
import SwiftPodsManifest
import SwiftPodsTestSupport
import SwiftPodsXcode
import XCTest

final class InstallerTests: XCTestCase {
    private final class RecordingRunner: CommandRunner, @unchecked Sendable {
        struct Invocation {
            let executable: String
            let arguments: [String]
            let directory: URL?
        }

        private let lock = NSLock()
        private let handler: (String, [String], URL?) throws -> String
        private var recorded: [Invocation] = []

        init(handler: @escaping (String, [String], URL?) throws -> String = { _, _, _ in "" }) {
            self.handler = handler
        }

        var invocations: [Invocation] {
            lock.lock()
            defer { lock.unlock() }
            return recorded
        }

        func run(_ executable: String, _ arguments: [String], in directory: URL?) throws -> String {
            lock.lock()
            recorded.append(.init(executable: executable, arguments: arguments, directory: directory))
            lock.unlock()
            return try handler(executable, arguments, directory)
        }
    }

    private var directories: [URL] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        super.tearDown()
    }

    private func fixture(_ podfile: String, files: [String: String] = [:]) throws -> URL {
        let directory = try Fixtures.directory(podfile: podfile, files: files)
        directories.append(directory)
        return directory
    }

    private func installer(_ directory: URL) -> Installer {
        Installer(directory: directory, cache: directory.appendingPathComponent(".cache"))
    }

    private func project(_ directory: URL) throws -> XcodeProject {
        try XcodeProject(path: directory.appendingPathComponent("App.xcodeproj"))
    }

    private func target(_ project: XcodeProject, _ name: String) -> PBXObject {
        project[project.nativeTargets.first { $0.name == name }!.id]!
    }

    private func products(_ project: XcodeProject, _ target: String) -> [String] {
        self.target(project, target).strings("packageProductDependencies").compactMap { project[$0]?.string("productName") }
    }

    private func phaseNames(_ project: XcodeProject, _ target: String) -> [String] {
        self.target(project, target).strings("buildPhases").map { project[$0]?.string("name") ?? project[$0]!.isa! }
    }

    private func linked(_ project: XcodeProject, _ target: String) -> [String] {
        let phases = self.target(project, target).strings("buildPhases").filter { project[$0]?.isa == "PBXFrameworksBuildPhase" }
        return phases.flatMap { project[$0]!.strings("files") }.compactMap { project[$0]?.string("productRef") }
            .compactMap { project[$0]?.string("productName") }
    }

    /// Local packages SwiftPods references by their folders, in its group.
    private func localPackages(_ project: XcodeProject) -> [String] {
        let group = project.objects.values.first { $0.isa == "PBXGroup" && $0.string("name") == "SwiftPods" }
        return (group?.strings("children") ?? []).compactMap { project[$0] }
            .filter { $0.isa == "PBXFileReference" && $0.string("lastKnownFileType") == "wrapper" }.compactMap { $0.string("path") }
    }

    private func generated(_ directory: URL, _ path: String) throws -> String {
        try String(contentsOf: directory.appendingPathComponent("SwiftPods").appendingPathComponent(path), encoding: .utf8)
    }

    private func preservedGeneratedStaging(_ directory: URL) throws -> URL {
        let root = directory.appendingPathComponent("SwiftPods", isDirectory: true)
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix(".staging-") }
        XCTAssertEqual(names.count, 1, "Expected one preserved generated transaction")
        return root.appendingPathComponent(try XCTUnwrap(names.first), isDirectory: true)
    }

    private func makeXCFramework(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("<plist version=\"1.0\"><dict/></plist>".utf8).write(to: url.appendingPathComponent("Info.plist"))
    }

    func testInstallIsIdempotentAndUndoneByDeintegrate() throws {
        let directory = try fixture(
            """
            platform :ios, '15.0'
            group :analytics do
              spm 'https://github.com/firebase/firebase-ios-sdk.git', '~> 13.0', products: %w[FirebaseCore FirebaseAnalytics]
              script_phase name: 'Crashlytics', script: 'run', execution_position: :after_compile
            end
            target 'App' do
              use :analytics
              spm 'Networking', path: 'Modules/Networking'
              settings 'OTHER_LDFLAGS' => '$(inherited) -ObjC'
              script_phase name: 'Generate', script: 'gen', execution_position: :before_compile
              target 'AppTests' do
                inherit! :none
                spm 'https://github.com/pointfreeco/swift-snapshot-testing.git', exact: '1.18.0', products: ['SnapshotTesting']
              end
            end
            target 'Plugin' do
              spm 'https://github.com/firebase/firebase-ios-sdk.git', '~> 13.0', products: ['FirebaseCore'], link: false
            end
            """)
        let report = try installer(directory).install(InstallOptions())
        XCTAssertTrue(report.projects[0].changes.contains { $0.description == "Added local package SwiftPods/SwiftPodsDependencies" })

        // Swift products are direct target dependencies, so Clang and Objective-C can see their modules. The
        // generated package remains the stable binary-SDK container.
        let installed = try project(directory)
        let repositories = installed.project.strings("packageReferences").compactMap { installed[$0]?.string("repositoryURL") }.sorted()
        XCTAssertEqual(repositories, [
            "https://github.com/firebase/firebase-ios-sdk.git",
            "https://github.com/pointfreeco/swift-snapshot-testing.git",
        ])
        XCTAssertEqual(localPackages(installed), ["SwiftPods/SwiftPodsDependencies", "Modules/Networking"])
        XCTAssertEqual(products(installed, "App"), ["SwiftPods-App", "FirebaseCore", "FirebaseAnalytics", "Networking"])
        XCTAssertEqual(linked(installed, "App"), ["SwiftPods-App", "FirebaseCore", "FirebaseAnalytics", "Networking"])
        XCTAssertNil(installed[target(installed, "App").strings("packageProductDependencies")[0]]?["package"], "Local products name no package")
        XCTAssertEqual(phaseNames(installed, "App"), ["[SwiftPods] Prepare", "PBXSourcesBuildPhase", "PBXFrameworksBuildPhase", "[SwiftPods] Finish"])
        XCTAssertEqual(products(installed, "AppTests"), ["SwiftPods-AppTests", "SnapshotTesting"])
        XCTAssertEqual(products(installed, "Plugin"), [])
        XCTAssertEqual(linked(installed, "Plugin"), [], "link: false must not put SDK objects into a static archive")
        XCTAssertEqual(target(installed, "Plugin").strings("dependencies").compactMap { installed[$0]?.string("productRef") }
            .compactMap { installed[$0]?.string("productName") }, ["SwiftPods-Plugin", "FirebaseCore"])

        // The generated package carries only binaries; Xcode owns Swift package requirements and products directly.
        let manifest = try generated(directory, "SwiftPodsDependencies/Package.swift")
        XCTAssertTrue(manifest.contains(#"platforms: [.iOS("15.0")]"#), manifest)
        XCTAssertFalse(manifest.contains("firebase-ios-sdk"), manifest)
        XCTAssertFalse(manifest.contains("swift-snapshot-testing"), manifest)
        XCTAssertFalse(manifest.contains("Modules/Networking"), manifest)
        let firebase = installed.project.strings("packageReferences").compactMap { installed[$0] }
            .first { $0.string("repositoryURL") == "https://github.com/firebase/firebase-ios-sdk.git" }
        XCTAssertEqual(firebase?["requirement"]?.dictionary?["kind"]?.string, "upToNextMajorVersion")
        XCTAssertEqual(firebase?["requirement"]?.dictionary?["minimumVersion"]?.string, "13.0.0")

        // Script phases run generated scripts; groups' scripts come first.
        let prepare = try generated(directory, "Scripts/App/App/prepare.sh")
        XCTAssertTrue(prepare.contains("/usr/bin/shasum -a 256 --check --strict --status"), prepare)
        XCTAssertTrue(prepare.contains(#"'/bin/sh' "${SRCROOT}/"'SwiftPods/Scripts/App/App/2.sh'"#), prepare)
        XCTAssertEqual(try generated(directory, "Scripts/App/App/2.sh"), "gen\n")
        XCTAssertTrue(try generated(directory, "Scripts/App/App/finish.sh").contains("/App/App/1.sh"))
        XCTAssertTrue(try generated(directory, "Scripts/Podfile.sha256").hasSuffix("  Podfile\n"))

        let settings = directory.appendingPathComponent("SwiftPods/Settings/App/App.xcconfig")
        XCTAssertEqual(
            try String(contentsOf: settings, encoding: .utf8),
            "// Generated by SwiftPods from the Podfile. Do not edit.\n"
                + "LD_RUNPATH_SEARCH_PATHS = $(inherited) @executable_path/Frameworks\n"
                + "OTHER_LDFLAGS = $(inherited) -ObjC\n")
        let configurations = installed.configurations(of: installed.nativeTargets[0].id).values
        XCTAssertTrue(configurations.allSatisfy { installed[$0]?.string("baseConfigurationReference") != nil })

        let text = try String(contentsOf: installed.file, encoding: .utf8)
        let again = try installer(directory).install(InstallOptions())
        XCTAssertEqual(again.projects[0].changes, [])
        XCTAssertEqual(try String(contentsOf: installed.file, encoding: .utf8), text)

        _ = try installer(directory).deintegrate()
        XCTAssertEqual(try String(contentsOf: installed.file, encoding: .utf8), Fixtures.project)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("SwiftPods").path))
    }

    func testInstallReplacesForeignBinaryContentOfAGeneratedPackage() throws {
        // A build with a relative SYMROOT writes products, such as Clang modules, into the generated package.
        let directory = try fixture(
            """
            target 'App' do
              spm 'Networking', path: 'Modules/Networking'
              settings 'OTHER_LDFLAGS' => '$(inherited) -ObjC'
            end
            """,
            files: [
                "Modules/Networking/Package.swift":
                    "// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(name: \"Networking\")\n",
            ])
        _ = try installer(directory).install(InstallOptions())
        let package = directory.appendingPathComponent("SwiftPods/SwiftPodsDependencies", isDirectory: true)
        let manifest = package.appendingPathComponent("Package.swift")
        let generatedManifest = try Data(contentsOf: manifest)
        let products = package.appendingPathComponent("build/SwiftExplicitPrecompiledModules", isDirectory: true)
        try FileManager.default.createDirectory(at: products, withIntermediateDirectories: true)
        try Data([0xFF, 0xFE, 0x00, 0x01]).write(to: products.appendingPathComponent("Module.pcm"))

        _ = try installer(directory).install(InstallOptions())
        XCTAssertFalse(FileManager.default.fileExists(atPath: package.appendingPathComponent("build").path))
        XCTAssertEqual(try Data(contentsOf: manifest), generatedManifest)

        // A generated file with binary content is stale content, not a reason to stop.
        try Data([0xFF, 0xFE, 0x00, 0x01]).write(to: manifest)
        _ = try installer(directory).install(InstallOptions())
        XCTAssertEqual(try Data(contentsOf: manifest), generatedManifest)
        XCTAssertEqual(try installer(directory).install(InstallOptions()).projects[0].changes, [])
    }

    func testStaticLibraryPreparesLinkedAndCompileOnlyPackageModules() throws {
        let directory = try fixture(
            """
            target 'Plugin' do
              spm 'Interop', path: 'Modules/Interop'
              spm 'BuildOnly', path: 'Modules/BuildOnly', link: false
            end
            """,
            files: [
                "Modules/Interop/Package.swift": "// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(name: \"Interop\")\n",
                "Modules/BuildOnly/Package.swift": "// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(name: \"BuildOnly\")\n",
            ])

        _ = try installer(directory).install(InstallOptions())

        let settings = try generated(directory, "Settings/App/Plugin.xcconfig")
        XCTAssertTrue(settings.contains("HEADER_SEARCH_PATHS = $(inherited) \"$(DERIVED_FILE_DIR)/SwiftPodsPackageModules\""), settings)
        XCTAssertFalse(settings.contains("LD_RUNPATH_SEARCH_PATHS"), settings)
        let prepare = try generated(directory, "Scripts/App/Plugin/prepare.sh")
        XCTAssertTrue(prepare.contains("package-modules.swift"), prepare)
        XCTAssertTrue(prepare.contains("DependencyStaticMetadataFileList"), prepare)
        let bridge = try generated(directory, "Scripts/App/Plugin/package-modules.swift")
        XCTAssertTrue(bridge.contains("extern module"), bridge)
        XCTAssertTrue(settings.contains("OTHER_SWIFT_FLAGS = $(inherited) -Xcc"), settings)
        XCTAssertTrue(settings.contains("USE_RECURSIVE_SCRIPT_INPUTS_IN_SCRIPT_PHASES = YES"), settings)
        XCTAssertTrue(settings.contains("FRAMEWORK_SEARCH_PATHS = $(inherited) \"$(BUILD_DIR)/$(CONFIGURATION)$(EFFECTIVE_PLATFORM_NAME)\" \"$(BUILD_DIR)/$(CONFIGURATION)$(EFFECTIVE_PLATFORM_NAME)/PackageFrameworks\" \"$(BUILT_PRODUCTS_DIR)/PackageFrameworks\""), settings)
        XCTAssertTrue(settings.contains("SWIFT_INCLUDE_PATHS = $(inherited) \"$(BUILD_DIR)/$(CONFIGURATION)$(EFFECTIVE_PLATFORM_NAME)\""), settings)
        XCTAssertTrue(
            try generated(directory, "Scripts/App/Plugin/prepare.inputs.xcfilelist")
                .contains("GeneratedModuleMaps$(EFFECTIVE_PLATFORM_NAME)"))
        XCTAssertTrue(
            try generated(directory, "Scripts/App/Plugin/prepare.inputs.xcfilelist")
                .contains("$(OBJROOT)/XCBuildData\n"))
        XCTAssertTrue(
            try generated(directory, "Scripts/App/Plugin/prepare.inputs.xcfilelist")
                .contains("$(OBJROOT)/$(SWIFTPODS_PIF_CACHE_PREFIX_$(OBJROOT:file))XCBuildData/PIFCache\n"))
        XCTAssertTrue(
            try generated(directory, "Scripts/App/Plugin/prepare.outputs.xcfilelist")
                .contains("$(DERIVED_FILE_DIR)/SwiftPodsPackageModules/module.modulemap"))
    }

    func testApplicationRuntimeSearchPathIsPlatformAwareAndKeepsPodfileOverrides() throws {
        let directory = try fixture(
            "platform :macos, '13.0'\ntarget 'App' do\n  settings 'LD_RUNPATH_SEARCH_PATHS' => '$(inherited) @loader_path/Frameworks'\nend\n")

        _ = try installer(directory).install(InstallOptions())

        XCTAssertEqual(
            try generated(directory, "Settings/App/App.xcconfig"),
            "// Generated by SwiftPods from the Podfile. Do not edit.\n"
                + "LD_RUNPATH_SEARCH_PATHS = $(inherited) @executable_path/../Frameworks\n"
                + "LD_RUNPATH_SEARCH_PATHS = $(inherited) @loader_path/Frameworks\n")
    }

    func testAValueForSomeConfigurationsFollowsTheValueForAll() throws {
        let directory = try fixture(
            "target 'App' do\n  settings 'OTHER_LDFLAGS[config=Debug]' => '-ObjC -lz', 'OTHER_LDFLAGS' => '-ObjC'\nend\n")

        _ = try installer(directory).install(InstallOptions())

        let settings = try generated(directory, "Settings/App/App.xcconfig")
        XCTAssertTrue(settings.hasSuffix("\nOTHER_LDFLAGS = -ObjC\nOTHER_LDFLAGS[config=Debug] = -ObjC -lz\n"), settings)
    }

    func testBaseConfigurationTraversalRejectsGroupCyclesAndSpecialFiles() throws {
        func configuredProject(_ directory: URL, path: String, groups: Bool) throws {
            var edited = try project(directory)
            let reference = "C00000000000000000000001"
            edited[reference] = [
                "isa": "PBXFileReference", "path": .string(path), "sourceTree": groups ? "<group>" : "SOURCE_ROOT",
            ]
            if groups {
                edited["C00000000000000000000002"] = [
                    "isa": "PBXGroup", "children": .array([.string(reference), .string("C00000000000000000000003")]),
                    "sourceTree": "<group>",
                ]
                edited["C00000000000000000000003"] = [
                    "isa": "PBXGroup", "children": [.string("C00000000000000000000002")], "sourceTree": "<group>",
                ]
            }
            for id in edited.configurations(of: edited.nativeTargets[0].id).values {
                edited[id]!["baseConfigurationReference"] = .string(reference)
            }
            try edited.save()
        }

        let cyclic = try fixture("target 'App' do\n  settings 'A' => 'B'\nend\n")
        try configuredProject(cyclic, path: "Config/App.xcconfig", groups: true)
        XCTAssertThrowsError(try installer(cyclic).install(.init())) {
            XCTAssertTrue("\($0)".contains("already uses"), "\($0)")
        }

        let fifo = try fixture("target 'App' do\n  settings 'A' => 'B'\nend\n")
        let config = fifo.appendingPathComponent("Config/App.xcconfig")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertEqual(config.path.withCString { mkfifo($0, S_IRUSR | S_IWUSR) }, 0)
        try configuredProject(fifo, path: "Config/App.xcconfig", groups: false)
        XCTAssertThrowsError(try installer(fifo).install(.init())) {
            XCTAssertTrue("\($0)".contains("already uses"), "\($0)")
        }
    }

    func testChangingThePodfileUpdatesDirectProductsAndGeneratedFiles() throws {
        let directory = try fixture(
            """
            platform :ios, '15.0'
            target 'App' do
              spm 'https://github.com/firebase/firebase-ios-sdk.git', exact: '13.0.1', products: ['FirebaseCore']
              spm 'https://github.com/Alamofire/Alamofire.git', '~> 5.9'
            end
            """)
        _ = try installer(directory).install(InstallOptions())
        let text = try String(contentsOf: try project(directory).file, encoding: .utf8)

        // New versions, products, packages, order, settings and scripts.
        try """
            platform :ios, '15.0'
            target 'App' do
              spm 'https://github.com/Alamofire/Alamofire.git', '~> 5.10'
              spm 'https://github.com/firebase/firebase-ios-sdk.git', exact: '13.1.0', products: %w[FirebaseCore FirebaseAnalytics]
              spm 'https://github.com/DataDog/dd-sdk-ios.git', '~> 3.15', products: ['DatadogCore']
              settings 'OTHER_LDFLAGS' => '-ObjC'
              script_phase name: 'Upload', script: 'upload', execution_position: :after_compile
            end
            """.write(to: directory.appendingPathComponent("Podfile"), atomically: true, encoding: .utf8)
        let report = try installer(directory).install(InstallOptions())
        XCTAssertFalse(report.projects[0].changes.isEmpty)
        let installed = try project(directory)
        XCTAssertNotEqual(try String(contentsOf: installed.file, encoding: .utf8), text)
        XCTAssertEqual(products(installed, "App"), [
            "SwiftPods-App", "Alamofire", "FirebaseCore", "FirebaseAnalytics", "DatadogCore",
        ])
        let references = installed.project.strings("packageReferences").compactMap { installed[$0] }
        XCTAssertEqual(Set(references.compactMap { $0.string("repositoryURL") }), Set([
            "https://github.com/Alamofire/Alamofire.git",
            "https://github.com/firebase/firebase-ios-sdk.git",
            "https://github.com/DataDog/dd-sdk-ios.git",
        ]))
        let firebase = references.first { $0.string("repositoryURL") == "https://github.com/firebase/firebase-ios-sdk.git" }
        XCTAssertEqual(firebase?["requirement"]?.dictionary?["version"]?.string, "13.1.0")
        let datadog = references.first { $0.string("repositoryURL") == "https://github.com/DataDog/dd-sdk-ios.git" }
        XCTAssertEqual(datadog?["requirement"]?.dictionary?["minimumVersion"]?.string, "3.15.0")
        XCTAssertTrue(try generated(directory, "Settings/App/App.xcconfig").contains("OTHER_LDFLAGS = -ObjC"))
        XCTAssertTrue(try generated(directory, "Scripts/App/App/finish.sh").contains("SwiftPods: Upload"))
    }

    func testProjectsFromSwiftPods02AreConverted() throws {
        let directory = try fixture(
            """
            target 'App' do
              spm 'https://github.com/firebase/firebase-ios-sdk.git', '~> 13.0', products: ['FirebaseCore']
              spm 'Networking', path: 'Modules/Networking'
            end
            """)
        _ = try installer(directory).install(InstallOptions())
        // What SwiftPods 0.2 used for local packages, plus an obsolete managed script.
        var old = try project(directory)
        let app = old.nativeTargets.first { $0.name == "App" }!.id
        let remote = "package:" + PackageLocation.canonical("https://github.com/firebase/firebase-ios-sdk.git")
        let local = "package:local:Modules/Networking"
        // 0.2 had these products under identifiers derived from the target's name, not the ones just installed.
        for (key, product) in [(remote, "FirebaseCore"), (local, "Networking")] {
            old.remove(XcodeProject.identifier(ProjectIntegration.productKey(targetID: app, package: key, product: product)))
        }
        old[XcodeProject.identifier(remote)] = [
            "isa": "XCRemoteSwiftPackageReference", "repositoryURL": "https://github.com/firebase/firebase-ios-sdk.git",
            "requirement": ["kind": "upToNextMajorVersion", "minimumVersion": "13.0.0"],
        ]
        old[XcodeProject.identifier(local)] = ["isa": "XCLocalSwiftPackageReference", "relativePath": "Modules/Networking"]
        for key in [remote, local] { old.append(XcodeProject.identifier(key), to: "packageReferences", of: old.rootID) }
        for (key, product) in [(remote, "FirebaseCore"), (local, "Networking")] {
            let dependency = XcodeProject.identifier(ProjectIntegration.legacyProductKey(target: "App", package: key, product: product))
            old[dependency] = ["isa": "XCSwiftPackageProductDependency", "package": .string(XcodeProject.identifier(key)), "productName": .string(product)]
            old.append(dependency, to: "packageProductDependencies", of: app)
            let file = XcodeProject.identifier("build-file:" + dependency)
            old[file] = ["isa": "PBXBuildFile", "productRef": .string(dependency)]
            old.append(file, to: "files", of: "A30000000000000000000001")
        }
        let script = XcodeProject.identifier(ProjectIntegration.legacyScriptKey(target: "App", name: "Upload"))
        old[script] = [
            "isa": "PBXShellScriptBuildPhase", "buildActionMask": "2147483647", "files": [], "name": "[SwiftPods] Upload",
            "runOnlyForDeploymentPostprocessing": "0", "shellPath": "/bin/sh", "shellScript": "upload",
        ]
        old.append(script, to: "buildPhases", of: app)
        try old.save()

        let changes = try installer(directory).install(InstallOptions()).projects[0].changes.map(\.description)
        XCTAssertTrue(changes.contains("Updated local package Modules/Networking"), "\(changes)")
        XCTAssertTrue(changes.contains("Updated product Networking in App"), "\(changes)")
        XCTAssertTrue(changes.contains { $0.contains("script phase [SwiftPods] Upload") }, "\(changes)")
        let converted = try project(directory)
        XCTAssertEqual(products(converted, "App"), ["SwiftPods-App", "FirebaseCore", "Networking"])
        XCTAssertEqual(try installer(directory).install(InstallOptions()).projects[0].changes, [])
    }

    func testReorderedPhasesAreReported() throws {
        let directory = try fixture("target 'App' do\nend\n")
        _ = try installer(directory).install(InstallOptions())
        var moved = try project(directory)
        let text = try String(contentsOf: moved.file, encoding: .utf8)
        // Someone drags SwiftPods' last phase to the front.
        var phases = target(moved, "App").strings("buildPhases")
        phases.insert(phases.removeLast(), at: 0)
        moved[moved.nativeTargets[0].id]!["buildPhases"] = .array(phases.map(PBXValue.string))
        try moved.save()

        let report = try installer(directory).install(InstallOptions())
        XCTAssertEqual(report.projects[0].changes.map(\.description), ["Reordered build phases in App"])
        XCTAssertEqual(try String(contentsOf: moved.file, encoding: .utf8), text)
    }

    func testRemovedDeclarationsLeaveUserObjectsAlone() throws {
        let directory = try fixture(
            """
            target 'App' do
              spm 'https://github.com/a/Kit.git', exact: '1.0.0'
              spm 'https://github.com/a/Extra.git', exact: '2.0.0'
            end
            """)
        _ = try installer(directory).install(InstallOptions())
        // Someone adds their own package in Xcode.
        var edited = try project(directory)
        let reference = "B00000000000000000000001"
        edited[reference] = ["isa": "XCRemoteSwiftPackageReference", "repositoryURL": "https://github.com/user/Own.git",
                             "requirement": ["kind": "exactVersion", "version": "1.0.0"]]
        edited.append(reference, to: "packageReferences", of: edited.rootID)
        try edited.save()

        try "target 'App' do\n  spm 'https://github.com/a/Kit.git', exact: '1.1.0'\nend\n"
            .write(to: directory.appendingPathComponent("Podfile"), atomically: true, encoding: .utf8)
        let report = try installer(directory).install(InstallOptions())
        let after = try project(directory)
        let urls = after.project.strings("packageReferences").compactMap { after[$0]?.string("repositoryURL") }
        XCTAssertEqual(Set(urls), Set(["https://github.com/user/Own.git", "https://github.com/a/Kit.git"]))
        XCTAssertEqual(products(after, "App"), ["SwiftPods-App", "Kit"])
        XCTAssertTrue(report.projects[0].changes.contains { $0.description == "Removed package https://github.com/a/Extra.git" })
        XCTAssertTrue(report.projects[0].changes.contains { $0.description == "Removed product Extra in App" })
        let manifest = try generated(directory, "SwiftPodsDependencies/Package.swift")
        XCTAssertFalse(manifest.contains("Extra"), manifest)
        let kit = after.project.strings("packageReferences").compactMap { after[$0] }
            .first { $0.string("repositoryURL") == "https://github.com/a/Kit.git" }
        XCTAssertEqual(kit?["requirement"]?.dictionary?["version"]?.string, "1.1.0")
    }

    func testForeignReferencesNeedAdoption() throws {
        let directory = try fixture("target 'App' do\n  spm 'https://github.com/a/Kit', exact: '1.0.0'\nend\n")
        var edited = try project(directory)
        edited["B00000000000000000000001"] = ["isa": "XCRemoteSwiftPackageReference", "repositoryURL": "https://github.com/a/Kit.git",
                                              "requirement": ["kind": "branch", "branch": "main"]]
        edited.append("B00000000000000000000001", to: "packageReferences", of: edited.rootID)
        edited["B00000000000000000000002"] = ["isa": "XCSwiftPackageProductDependency", "package": "B00000000000000000000001", "productName": "KitExtras"]
        edited.append("B00000000000000000000002", to: "packageProductDependencies", of: edited.nativeTargets[0].id)
        try edited.save()

        XCTAssertThrowsError(try installer(directory).install(InstallOptions())) { error in
            XCTAssertTrue("\(error)".contains("--adopt"), "\(error)")
        }
        var options = InstallOptions()
        options.adopt = true
        _ = try installer(directory).install(options)
        let after = try project(directory)
        XCTAssertNil(after["B00000000000000000000001"])
        XCTAssertNil(after["B00000000000000000000002"])
        XCTAssertEqual(after.project.strings("packageReferences"), [
            XcodeProject.identifier("package:" + PackageLocation.canonical("https://github.com/a/Kit")),
        ])
        XCTAssertEqual(products(after, "App"), ["SwiftPods-App", "Kit"])
    }

    func testBinariesBecomeAGeneratedPackage() throws {
        let directory = try fixture(
            """
            platform :ios, '15.4'
            target 'App' do
              binary 'Ads', path: 'Vendor/Ads', system_frameworks: ['WebKit'], libraries: ['z'], linker_flags: ['-ObjC'], dependencies: ['Core']
              binary 'Core', path: 'Vendor/Core.xcframework'
            end
            """)
        try makeXCFramework(directory.appendingPathComponent("Vendor/Ads/AdsSDK.xcframework"))
        try makeXCFramework(directory.appendingPathComponent("Vendor/Ads/AdsAdapter.xcframework"))
        try makeXCFramework(directory.appendingPathComponent("Vendor/Core.xcframework"))

        let report = try installer(directory).install(InstallOptions())
        XCTAssertEqual(report.binaries, ["Ads", "Core"])
        let package = directory.appendingPathComponent("SwiftPods/SwiftPodsBinaries")
        let manifest = try String(contentsOf: package.appendingPathComponent("Package.swift"), encoding: .utf8)
        XCTAssertTrue(manifest.contains(#"platforms: [.iOS("15.4")]"#), manifest)
        XCTAssertTrue(manifest.contains(#".binaryTarget(name: "AdsSDK", path: "Artifacts/Ads/AdsSDK.xcframework")"#), manifest)
        XCTAssertTrue(manifest.contains(#"dependencies: ["AdsAdapter", "AdsSDK", "CoreLinkage"]"#), manifest)
        XCTAssertTrue(manifest.contains(#"linkerSettings: [.linkedFramework("WebKit"), .linkedLibrary("z"), .unsafeFlags(["-ObjC"])]"#), manifest)
        XCTAssertTrue(FileManager.default.fileExists(atPath: package.appendingPathComponent("Artifacts/Core/Core.xcframework/Info.plist").path))

        let installed = try project(directory)
        XCTAssertEqual(localPackages(installed), ["SwiftPods/SwiftPodsDependencies", "SwiftPods/SwiftPodsBinaries"])
        XCTAssertEqual(products(installed, "App"), ["SwiftPods-App"])
        let dependencies = try generated(directory, "SwiftPodsDependencies/Package.swift")
        XCTAssertTrue(dependencies.contains(#".package(path: "../SwiftPodsBinaries")"#), dependencies)
        XCTAssertTrue(dependencies.contains(#".product(name: "Ads", package: "SwiftPodsBinaries")"#), dependencies)

        // Swift Package Manager accepts the generated manifests.
        let dump = try ProcessRunner().run("/usr/bin/xcrun", ["swift", "package", "dump-package"], in: package)
        XCTAssertTrue(dump.contains("\"AdsLinkage\""))
        let dependencyDump = try ProcessRunner().run(
            "/usr/bin/xcrun", ["swift", "package", "dump-package"], in: directory.appendingPathComponent("SwiftPods/SwiftPodsDependencies"))
        XCTAssertTrue(dependencyDump.contains("\"SwiftPods_App\""))

        let modified = try FileManager.default.attributesOfItem(atPath: package.appendingPathComponent("Package.swift").path)[.modificationDate] as? Date
        _ = try installer(directory).install(InstallOptions())
        let unchanged = try FileManager.default.attributesOfItem(atPath: package.appendingPathComponent("Package.swift").path)[.modificationDate] as? Date
        XCTAssertEqual(modified, unchanged, "An unchanged binary package is not regenerated")

        _ = try installer(directory).deintegrate()
        XCTAssertEqual(try String(contentsOf: installed.file, encoding: .utf8), Fixtures.project)
    }

    func testVersionedCatalystFrameworkSymlinksSurviveInstallAndReplacement() throws {
        let directory = try fixture("target 'App' do\n  binary 'Kit', path: 'Vendor/Kit.xcframework'\nend\n")
        let artifact = directory.appendingPathComponent("Vendor/Kit.xcframework")
        let frameworkPath = "ios-arm64_x86_64-maccatalyst/Kit.framework"
        let framework = artifact.appendingPathComponent(frameworkPath)
        let headers = framework.appendingPathComponent("Versions/A/Headers")
        try FileManager.default.createDirectory(at: headers, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "AvailableLibraries": [[
                "LibraryIdentifier": "ios-arm64_x86_64-maccatalyst", "LibraryPath": "Kit.framework",
                "SupportedArchitectures": ["arm64", "x86_64"], "SupportedPlatform": "ios",
                "SupportedPlatformVariant": "maccatalyst",
            ]],
            "CFBundlePackageType": "XFWK", "XCFrameworkFormatVersion": "1.0",
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: artifact.appendingPathComponent("Info.plist"))
        try FileManager.default.createSymbolicLink(
            atPath: framework.appendingPathComponent("Versions/Current").path, withDestinationPath: "A")
        try FileManager.default.createSymbolicLink(
            atPath: framework.appendingPathComponent("Headers").path,
            withDestinationPath: "Versions/Current/Headers")
        let installedFramework = directory.appendingPathComponent(
            "SwiftPods/SwiftPodsBinaries/Artifacts/Kit/Kit.xcframework/" + frameworkPath)
        // Run the built CLI so Release tests also exercise its optimized code and executable archive worker.
        let executable = Bundle(for: InstallerTests.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("swiftpods")

        for contents in ["original header\n", "original header\n", "updated header\n"] {
            let existing = try? String(contentsOf: headers.appendingPathComponent("Kit.h"), encoding: .utf8)
            if existing != contents {
                try Data(contents.utf8).write(to: headers.appendingPathComponent("Kit.h"))
            }
            _ = try ProcessRunner().run(
                executable.path, ["install", "--project-directory", directory.path, "--offline"], in: nil)

            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(
                atPath: installedFramework.appendingPathComponent("Headers").path), "Versions/Current/Headers")
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(
                atPath: installedFramework.appendingPathComponent("Versions/Current").path), "A")
            XCTAssertEqual(try String(
                contentsOf: installedFramework.appendingPathComponent("Headers/Kit.h"), encoding: .utf8), contents)
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(".swiftpods-transaction").path))
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(
                atPath: directory.appendingPathComponent("SwiftPods").path).contains { $0.hasPrefix(".staging-") })
        }
    }

    func testLocalBinaryMaySelectAnArtifactFromSwiftPodsWithoutRecursiveSnapshot() throws {
        let directory = try fixture("target 'App' do\nend\n")
        _ = try installer(directory).install(InstallOptions())
        let source = directory.appendingPathComponent("SwiftPods/Vendor/Kit.xcframework", isDirectory: true)
        try makeXCFramework(source)
        try """
            target 'App' do
              binary 'Kit', path: 'SwiftPods', xcframeworks: ['Vendor/Kit.xcframework']
            end
            """.write(to: directory.appendingPathComponent("Podfile"), atomically: true, encoding: .utf8)

        _ = try installer(directory).install(InstallOptions())
        let artifact = directory.appendingPathComponent(
            "SwiftPods/SwiftPodsBinaries/Artifacts/Kit/Kit.xcframework/Info.plist")
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.path))
        XCTAssertTrue(try generated(directory, "SwiftPodsBinaries/Package.swift")
            .contains(#".binaryTarget(name: "Kit", path: "Artifacts/Kit/Kit.xcframework")"#))

        // A second install sees the generated copy inside the broad source root, but the explicit selection remains
        // stable and must not recurse through a staging snapshot under that root.
        XCTAssertNoThrow(try installer(directory).install(InstallOptions()))
    }

    func testAppsEmbeddingAFrameworkTargetEmbedItsDynamicFrameworks() throws {
        let directory = try Fixtures.directory(
            podfile: "target 'Plugin' do\n  spm 'https://github.com/Alamofire/Alamofire.git', '~> 5.9'\nend\n", project: Fixtures.embeddingProject)
        directories.append(directory)
        _ = try installer(directory).install(InstallOptions())
        let installed = try project(directory)
        // App is not in the Podfile: it gets only the Finish phase, which embeds the dynamic frameworks Plugin links.
        XCTAssertEqual(phaseNames(installed, "App"), ["PBXSourcesBuildPhase", "PBXFrameworksBuildPhase", "Embed Frameworks", "[SwiftPods] Finish"])
        XCTAssertEqual(products(installed, "App"), [])
        XCTAssertNotNil(installed[installed.configurations(of: installed.nativeTargets[0].id)["Debug"]!]?.string("baseConfigurationReference"))
        XCTAssertEqual(
            try generated(directory, "Settings/App/App.xcconfig"),
            "// Generated by SwiftPods from the Podfile. Do not edit.\n"
                + "LD_RUNPATH_SEARCH_PATHS = $(inherited) @executable_path/Frameworks\n")
        XCTAssertTrue(try generated(directory, "Scripts/App/App/finish.sh").contains(TargetScripts.embedFrameworks))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("SwiftPods/Scripts/App/App/prepare.sh").path))
        XCTAssertFalse(try generated(directory, "Scripts/App/Plugin/finish.sh").contains(TargetScripts.embedFrameworks))
        try "target 'Plugin' do\n  spm 'https://github.com/Alamofire/Alamofire.git', '~> 5.10'\n  binary 'Ads', path: 'Vendor/Ads.xcframework'\nend\n"
            .write(to: directory.appendingPathComponent("Podfile"), atomically: true, encoding: .utf8)
        try makeXCFramework(directory.appendingPathComponent("Vendor/Ads.xcframework"))
        XCTAssertEqual(try installer(directory).install(InstallOptions()).projects[0].changes.map(\.description), [
            "Added local package SwiftPods/SwiftPodsBinaries",
            "Updated package https://github.com/Alamofire/Alamofire.git",
        ])
        XCTAssertEqual(products(try project(directory), "Plugin"), ["SwiftPods-Plugin", "Alamofire"])

        // Declared, App keeps the embedding after its own scripts.
        try "target 'App' do\n  script_phase name: 'Upload', script: 'upload'\nend\ntarget 'Plugin' do\nend\n"
            .write(to: directory.appendingPathComponent("Podfile"), atomically: true, encoding: .utf8)
        _ = try installer(directory).install(InstallOptions())
        let finish = try generated(directory, "Scripts/App/App/finish.sh")
        XCTAssertLessThan(finish.range(of: "SwiftPods: Upload")!.lowerBound, finish.range(of: TargetScripts.embedFrameworks)!.lowerBound)

        _ = try installer(directory).deintegrate()
        XCTAssertEqual(
            try String(contentsOf: installed.file, encoding: .utf8),
            try XcodeProject(path: installed.path, text: Fixtures.embeddingProject).serialized())
    }

    func testTargetsWithoutAProjectUseTheGivenOne() throws {
        let root = try fixture("")
        let ios = root.appendingPathComponent("ios")
        try FileManager.default.createDirectory(at: ios, withIntermediateDirectories: true)
        try "target 'App' do\n  spm 'https://github.com/Alamofire/Alamofire.git', '~> 5.9'\nend\n"
            .write(to: ios.appendingPathComponent("Podfile"), atomically: true, encoding: .utf8)
        let cache = root.appendingPathComponent(".cache")
        XCTAssertThrowsError(try Installer(directory: ios, cache: cache).install(InstallOptions())) {
            XCTAssertTrue("\($0)".contains("No Xcode project next to the Podfile"), "\($0)")
        }

        let installer = Installer(directory: ios, project: root.appendingPathComponent("App.xcodeproj"), cache: cache)
        _ = try installer.install(InstallOptions())
        let installed = try project(root)
        XCTAssertEqual(products(installed, "App"), ["SwiftPods-App", "Alamofire"])
        XCTAssertEqual(localPackages(installed), ["ios/SwiftPods/SwiftPodsDependencies"])
        let prepare = try String(contentsOf: ios.appendingPathComponent("SwiftPods/Scripts/App/App/prepare.sh"), encoding: .utf8)
        XCTAssertTrue(prepare.contains(#"cd "${SRCROOT}/"'ios'"#), prepare)

        _ = try installer.deintegrate()
        XCTAssertEqual(try String(contentsOf: installed.file, encoding: .utf8), Fixtures.project)
    }

    func testNestedBinaryResourceIsCopiedSeparatelyAndRemainsIdempotent() throws {
        let relative = "Ads.xcframework/ios-arm64/Ads.framework/AdsRes.bundle"
        let directory = try fixture(
            "target 'App' do\n  binary 'Ads', path: 'Vendor', resources: ['\(relative)']\nend\n")
        try makeXCFramework(directory.appendingPathComponent("Vendor/Ads.xcframework"))
        let bundle = directory.appendingPathComponent("Vendor/\(relative)")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data("nested-resource".utf8).write(to: bundle.appendingPathComponent("strings.txt"))

        _ = try installer(directory).install(InstallOptions())
        let installed = directory.appendingPathComponent("SwiftPods/SwiftPodsBinaries/Artifacts/Ads")
        for path in ["Ads.xcframework/ios-arm64/Ads.framework/AdsRes.bundle", "Resources/AdsRes.bundle"] {
            XCTAssertEqual(try Data(contentsOf: installed.appendingPathComponent(path + "/strings.txt")), Data("nested-resource".utf8))
        }
        let finish = try generated(directory, "Scripts/App/App/finish.sh")
        XCTAssertTrue(finish.contains("Artifacts/Ads/Resources/AdsRes.bundle"), finish)
        XCTAssertEqual(try installer(directory).install(InstallOptions()).projects[0].changes, [])
        _ = try installer(directory).deintegrate()
    }

    func testBinaryResourcesAreCopiedIntoTheApp() throws {
        let directory = try fixture("target 'App' do\n  binary 'Ads', path: 'Vendor/Ads', resources: ['AdsRes.bundle']\nend\n")
        try makeXCFramework(directory.appendingPathComponent("Vendor/Ads/Ads.xcframework"))
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("Vendor/Ads/Res/AdsRes.bundle"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: directory.appendingPathComponent("Vendor/Ads/Res/AdsRes.bundle/strings.txt"))

        _ = try installer(directory).install(InstallOptions())
        // The Finish phase copies bundles, so the project lists none.
        let finish = try generated(directory, "Scripts/App/App/finish.sh")
        XCTAssertTrue(finish.contains(
            #"/usr/bin/rsync -a --delete "${SRCROOT}/"'SwiftPods/SwiftPodsBinaries/Artifacts/Ads/Resources/AdsRes.bundle' "$destination/""#), finish)
        XCTAssertEqual(
            try generated(directory, "Scripts/App/App/finish.outputs.xcfilelist"), "$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/AdsRes.bundle\n")
        let installed = try project(directory)
        XCTAssertFalse(installed.objects.values.contains { $0.string("path")?.hasSuffix(".bundle") == true })
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("SwiftPods/SwiftPodsBinaries/Artifacts/Ads/Resources/AdsRes.bundle/strings.txt").path))

        XCTAssertEqual(try installer(directory).install(InstallOptions()).projects[0].changes, [])
        _ = try installer(directory).deintegrate()
        XCTAssertEqual(try String(contentsOf: installed.file, encoding: .utf8), Fixtures.project)
    }

    func testCocoaPodsIntegrationIsRemovedWithoutCocoaPods() throws {
        let directory = try fixture("target 'App' do\nend\n")
        let workspace = directory.appendingPathComponent("App.xcworkspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let workspaceText = """
            <?xml version="1.0" encoding="UTF-8"?>
            <Workspace
               version = "1.0">
               <FileRef
                  location = "group:App.xcodeproj">
               </FileRef>
            %@</Workspace>

            """
        let podsReference = "   <FileRef\n      location = \"group:Pods/Pods.xcodeproj\">\n   </FileRef>\n"
        let workspaceContents = workspace.appendingPathComponent("contents.xcworkspacedata")
        try String(format: workspaceText, podsReference).write(
            to: workspaceContents, atomically: true, encoding: .utf8)
        XCTAssertEqual(chmod(workspaceContents.path, 0o600), 0)
        var originalWorkspaceStatus = stat()
        XCTAssertEqual(lstat(workspaceContents.path, &originalWorkspaceStatus), 0)

        // What `pod install` (or SwiftPods 0.1) leaves in a user project.
        var project = try project(directory)
        let app = project.nativeTargets[0].id
        project["D00000000000000000000001"] = ["isa": "PBXFileReference", "lastKnownFileType": "text.xcconfig", "name": "Pods-App.debug.xcconfig",
                                               "path": "Target Support Files/Pods-App/Pods-App.debug.xcconfig", "sourceTree": "<group>"]
        project["D00000000000000000000002"] = ["isa": "PBXGroup", "children": ["D00000000000000000000001"], "name": "Pods", "path": "Pods", "sourceTree": "<group>"]
        project.append("D00000000000000000000002", to: "children", of: project.project.string("mainGroup")!)
        project["D00000000000000000000003"] = ["isa": "PBXFileReference", "explicitFileType": "wrapper.framework", "path": "Pods_App.framework", "sourceTree": "BUILT_PRODUCTS_DIR"]
        project["D00000000000000000000004"] = ["isa": "PBXBuildFile", "fileRef": "D00000000000000000000003"]
        project.append("D00000000000000000000004", to: "files", of: "A30000000000000000000001")
        project["D00000000000000000000005"] = ["isa": "PBXShellScriptBuildPhase", "buildActionMask": "2147483647", "files": [],
                                               "name": "[CP] Check Pods Manifest.lock", "runOnlyForDeploymentPostprocessing": "0",
                                               "shellPath": "/bin/sh", "shellScript": "diff Podfile.lock Manifest.lock"]
        project.append("D00000000000000000000005", to: "buildPhases", of: app)
        project["D00000000000000000000006"] = ["isa": "PBXFileReference", "lastKnownFileType": "wrapper.pb-project", "path": "Pods/Pods.xcodeproj", "sourceTree": "SOURCE_ROOT"]
        project["D00000000000000000000007"] = ["isa": "PBXContainerItemProxy", "containerPortal": "D00000000000000000000006", "proxyType": "1",
                                               "remoteGlobalIDString": "E00000000000000000000001", "remoteInfo": "Pods-App"]
        project["D00000000000000000000008"] = ["isa": "PBXTargetDependency", "name": "Pods-App", "targetProxy": "D00000000000000000000007"]
        project.append("D00000000000000000000008", to: "dependencies", of: app)
        for id in project.configurations(of: app).values {
            project[id]!["baseConfigurationReference"] = "D00000000000000000000001"
        }
        project["A80000000000000000000003"]!["buildSettings"] = ["PODS_ROOT": "$(SRCROOT)/Pods", "PRODUCT_NAME": "$(TARGET_NAME)"]
        try project.save()

        let report = try installer(directory).deintegrate(cocoapods: true)
        let subjects = report.projects[0].changes.map(\.description)
        XCTAssertTrue(subjects.contains("Removed script phase [CP] Check Pods Manifest.lock in App"), "\(subjects)")
        XCTAssertTrue(subjects.contains("Removed target dependency Pods-App in App"), "\(subjects)")
        XCTAssertTrue(subjects.contains("Removed Pods/Pods.xcodeproj from App.xcworkspace"), "\(subjects)")
        XCTAssertEqual(try String(contentsOf: project.file, encoding: .utf8), Fixtures.project)
        XCTAssertEqual(
            try String(contentsOf: workspaceContents, encoding: .utf8),
            String(format: workspaceText, ""))
        var workspaceStatus = stat()
        XCTAssertEqual(lstat(workspaceContents.path, &workspaceStatus), 0)
        XCTAssertEqual(workspaceStatus.st_mode & 0o7777, 0o600)
        XCTAssertEqual(workspaceStatus.st_uid, originalWorkspaceStatus.st_uid)
        XCTAssertEqual(workspaceStatus.st_gid, originalWorkspaceStatus.st_gid)
    }

    func testApplicationRuntimeSearchPathIsRestoredAfterCocoaPodsDeintegration() throws {
        let directory = try fixture("platform :ios, '15.0'\ntarget 'App' do\nend\n")
        var cocoapodsProject = try project(directory)
        let app = cocoapodsProject.nativeTargets[0].id
        let configuration = "D00000000000000000000001"
        cocoapodsProject[configuration] = [
            "isa": "PBXFileReference", "lastKnownFileType": "text.xcconfig",
            "name": "Pods-App.debug.xcconfig", "path": "Target Support Files/Pods-App/Pods-App.debug.xcconfig",
            "sourceTree": "<group>",
        ]
        for id in cocoapodsProject.configurations(of: app).values {
            cocoapodsProject[id]!["baseConfigurationReference"] = .string(configuration)
            var settings = cocoapodsProject[id]!["buildSettings"]?.dictionary ?? [:]
            settings["LD_RUNPATH_SEARCH_PATHS"] = "$(inherited)"
            cocoapodsProject[id]!["buildSettings"] = .dictionary(settings)
        }
        try cocoapodsProject.save()

        _ = try installer(directory).deintegrate(cocoapods: true)
        _ = try installer(directory).install(InstallOptions())

        let installed = try project(directory)
        for id in installed.configurations(of: app).values {
            XCTAssertEqual(installed[id]?["buildSettings"]?.dictionary?["LD_RUNPATH_SEARCH_PATHS"]?.string, "$(inherited)")
            let base = try XCTUnwrap(installed[id]?.string("baseConfigurationReference"))
            XCTAssertEqual(installed[base]?.string("path"), "SwiftPods/Settings/App/App.xcconfig")
        }
        XCTAssertEqual(
            try generated(directory, "Settings/App/App.xcconfig"),
            "// Generated by SwiftPods from the Podfile. Do not edit.\n"
                + "LD_RUNPATH_SEARCH_PATHS = $(inherited) @executable_path/Frameworks\n")
    }

    func testMalformedStaticFrameworksAreNormalized() throws {
        let directory = try fixture("platform :ios, '15.4'\ntarget 'App' do\n  binary 'Kit', path: 'Vendor/Kit.xcframework'\nend\n")
        let shell = ProcessRunner()
        // A static archive inside a single-architecture universal binary, in a versioned bundle without Info.plist.
        let work = directory.appendingPathComponent("build")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try "int kit(void) { return 1; }\n".write(to: work.appendingPathComponent("kit.c"), atomically: true, encoding: .utf8)
        _ = try shell.run("/usr/bin/xcrun", ["--sdk", "iphoneos", "clang", "-arch", "arm64", "-c", "kit.c", "-o", "kit.o"], in: work)
        _ = try shell.run("/usr/bin/xcrun", ["libtool", "-static", "-o", "libkit.a", "kit.o"], in: work)
        let framework = directory.appendingPathComponent("Vendor/Kit.xcframework/ios-arm64/Kit.framework")
        let version = framework.appendingPathComponent("Versions/A")
        try FileManager.default.createDirectory(at: version.appendingPathComponent("Headers"), withIntermediateDirectories: true)
        _ = try shell.run("/usr/bin/xcrun", ["lipo", "-create", work.appendingPathComponent("libkit.a").path, "-output", version.appendingPathComponent("Kit").path], in: nil)
        try FileManager.default.createSymbolicLink(atPath: framework.appendingPathComponent("Versions/Current").path, withDestinationPath: "A")
        try FileManager.default.createSymbolicLink(atPath: framework.appendingPathComponent("Kit").path, withDestinationPath: "Versions/Current/Kit")
        try FileManager.default.createSymbolicLink(atPath: framework.appendingPathComponent("Headers").path, withDestinationPath: "Versions/Current/Headers")
        let info: [String: Any] = [
            "AvailableLibraries": [["LibraryIdentifier": "ios-arm64", "LibraryPath": "Kit.framework", "SupportedArchitectures": ["arm64"], "SupportedPlatform": "ios"]],
            "CFBundlePackageType": "XFWK", "XCFrameworkFormatVersion": "1.0",
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: directory.appendingPathComponent("Vendor/Kit.xcframework/Info.plist"))

        let report = try installer(directory).install(InstallOptions())
        XCTAssertEqual(report.notes.count, 3, "\(report.notes)")
        let repaired = directory.appendingPathComponent("SwiftPods/SwiftPodsBinaries/Artifacts/Kit/Kit.xcframework/ios-arm64/Kit.framework")
        XCTAssertFalse(FileManager.default.fileExists(atPath: repaired.appendingPathComponent("Versions").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: repaired.appendingPathComponent("Headers").path))
        let binary = try Data(contentsOf: repaired.appendingPathComponent("Kit"))
        XCTAssertEqual(binary.prefix(8), Data("!<arch>\n".utf8))
        let plist = try XCTUnwrap(NSDictionary(contentsOf: repaired.appendingPathComponent("Info.plist")))
        XCTAssertEqual(plist["CFBundleExecutable"] as? String, "Kit")
        XCTAssertEqual(plist["MinimumOSVersion"] as? String, "15.4")
        // The vendor's copy is untouched.
        XCTAssertTrue(FileManager.default.fileExists(atPath: framework.appendingPathComponent("Versions/A/Kit").path))
    }

    func testCatalogsResolveNamesAndDeploymentDoesNotFollowChanges() throws {
        let directory = try fixture("")
        let shell = ProcessRunner()
        let catalog = directory.appendingPathComponent("catalog")
        try FileManager.default.createDirectory(at: catalog.appendingPathComponent("Packages/ThirdParty"), withIntermediateDirectories: true)
        func publish(_ url: String) throws {
            try "package 'Kit', git: '\(url)', products: ['Kit']\n"
                .write(to: catalog.appendingPathComponent("Packages/ThirdParty/Kit.podfile"), atomically: true, encoding: .utf8)
            _ = try shell.run("/usr/bin/git", ["add", "-A"], in: catalog)
            _ = try shell.run("/usr/bin/git", ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", url], in: catalog)
        }
        _ = try shell.run("/usr/bin/git", ["init", "-q"], in: catalog)
        try publish("https://github.com/a/Kit.git")
        XCTAssertEqual(CatalogTools.lint(catalog), [])

        try "source '\(catalog.path)'\ntarget 'App' do\n  spm 'kit', exact: '1.0.0'\nend\n"
            .write(to: directory.appendingPathComponent("Podfile"), atomically: true, encoding: .utf8)
        let sources = directory.appendingPathComponent(".sources")
        let installRunner = RecordingRunner { executable, arguments, directory in
            if executable == "/usr/bin/xcrun" { return "" }
            return try shell.run(executable, arguments, in: directory)
        }
        func configuredInstaller() -> Installer {
            Installer(
                directory: directory, runner: installRunner, cache: directory.appendingPathComponent(".cache"), sourcesCache: sources)
        }
        func install(_ configure: (inout InstallOptions) -> Void = { _ in }) throws {
            var options = InstallOptions()
            configure(&options)
            _ = try configuredInstaller().install(options)
        }
        func urls() throws -> [String] {
            let installed = try project(directory)
            return installed.project.strings("packageReferences").compactMap { installed[$0]?.string("repositoryURL") }
        }
        try install()
        XCTAssertEqual(try urls(), ["https://github.com/a/Kit.git"])
        let lock = directory.appendingPathComponent(SwiftPodsLock.fileName)
        let lockData = try Data(contentsOf: lock)
        let lockDigest = SHA256.hash(data: lockData).map { String(format: "%02x", $0) }.joined()
        let freshness = try generated(directory, "Scripts/Podfile.sha256")
        XCTAssertTrue(freshness.contains("\(lockDigest)  SwiftPods.lock"), freshness)
        let prepareInputs = try generated(directory, "Scripts/App/App/prepare.inputs.xcfilelist")
        XCTAssertTrue(prepareInputs.contains("$(SRCROOT)/SwiftPods.lock"), prepareInputs)
        let firstLock = try String(contentsOf: lock, encoding: .utf8)
        XCTAssertTrue(firstLock.contains(catalog.path), firstLock)
        try FileManager.default.removeItem(at: lock)
        XCTAssertThrowsError(try install { $0.deployment = true }) {
            XCTAssertTrue("\($0)".contains("SwiftPods.lock"), "\($0)")
        }
        try firstLock.write(to: lock, atomically: true, encoding: .utf8)
        let resolved = directory.appendingPathComponent("App.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
        try FileManager.default.createDirectory(at: resolved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"pins":[{"identity":"kit","kind":"remoteSourceControl","location":"https://github.com/a/Kit.git","state":{"revision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","version":"1.0.0"}}],"version":3}"#
            .write(to: resolved, atomically: true, encoding: .utf8)

        // The catalog moves Kit. An ordinary install also reads the exact locked commit from a clean source cache.
        try publish("https://github.com/b/Kit.git")
        try FileManager.default.removeItem(at: sources)
        XCTAssertEqual(
            try configuredInstaller().manifest().packages.first?.location,
            .remote(url: "https://github.com/a/Kit.git"))
        XCTAssertEqual(try String(contentsOf: lock, encoding: .utf8), firstLock)
        try FileManager.default.removeItem(at: sources)
        XCTAssertEqual(
            try configuredInstaller().manifest(updateSources: true).packages.first?.location,
            .remote(url: "https://github.com/b/Kit.git"))
        XCTAssertEqual(try String(contentsOf: lock, encoding: .utf8), firstLock)
        try FileManager.default.removeItem(at: sources)
        try install()
        XCTAssertEqual(try urls(), ["https://github.com/a/Kit.git"])
        XCTAssertEqual(try String(contentsOf: lock, encoding: .utf8), firstLock)
        try FileManager.default.removeItem(at: sources)

        // Deployment requires the same complete lock and never updates it, even if --update-sources is present.
        try install { $0.deployment = true; $0.updateSources = true }
        XCTAssertEqual(try urls(), ["https://github.com/a/Kit.git"])
        XCTAssertEqual(try String(contentsOf: lock, encoding: .utf8), firstLock)

        // A normal source update accepts the catalog change and rewrites SwiftPods.lock for review.
        try install { $0.updateSources = true }
        XCTAssertEqual(try urls(), ["https://github.com/b/Kit.git"])
        XCTAssertNotEqual(try String(contentsOf: lock, encoding: .utf8), firstLock)

        try "package 'Other', git: 'https://github.com/a/Other.git'\n"
            .write(to: catalog.appendingPathComponent("Packages/Kit2.podfile"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: catalog.appendingPathComponent("Packages/Apple"), withIntermediateDirectories: true)
        try "package 'kit', git: 'https://github.com/c/Kit.git'\n"
            .write(to: catalog.appendingPathComponent("Packages/Apple/kit.podfile"), atomically: true, encoding: .utf8)
        XCTAssertEqual(CatalogTools.lint(catalog), [
            "Kit2.podfile: declares `Other`, expected `Kit2`",
            "ThirdParty/Kit.podfile: `Kit` is already declared by Apple/kit.podfile",
        ])
    }

    func testReadingAManifestDoesNotCreateSwiftPodsLock() throws {
        let directory = try fixture("target 'App' do\nend\n")

        _ = try installer(directory).manifest()

        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(SwiftPodsLock.fileName).path))
    }

    func testExplicitOnlyCommandsIgnoreAMalformedUnusedSwiftPodsLock() throws {
        let directory = try fixture("target 'App' do\nend\n")
        let lock = directory.appendingPathComponent(SwiftPodsLock.fileName)
        let malformed = Data("{ this is not a lock }\n".utf8)
        try malformed.write(to: lock)

        // Read-only inspection and both install modes leave irrelevant evidence untouched.
        _ = try installer(directory).manifest()
        _ = try installer(directory).install(.init())
        var deployment = InstallOptions()
        deployment.deployment = true
        _ = try installer(directory).install(deployment)
        XCTAssertEqual(try Data(contentsOf: lock), malformed)

        // As soon as the Podfile needs a catalog, the same lock must fail before any catalog command or cache I/O.
        try "source '/catalog-is-never-opened'\ntarget 'App' do\n  spm 'Kit', exact: '1.0.0'\nend\n"
            .write(to: directory.appendingPathComponent("Podfile"), atomically: true, encoding: .utf8)
        let runner = RecordingRunner()
        let resolving = Installer(
            directory: directory, runner: runner, cache: directory.appendingPathComponent(".cache"),
            sourcesCache: directory.appendingPathComponent(".sources"))
        XCTAssertThrowsError(try resolving.manifest()) { error in
            XCTAssertTrue("\(error)".contains("SwiftPods.lock is not valid JSON"), "\(error)")
        }
        XCTAssertTrue(runner.invocations.isEmpty, "The catalog was touched before its lock was validated")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(".sources").path))
    }

    func testDeploymentIgnoresAStaleLockWhenNoCatalogMetadataIsUsed() throws {
        let directory = try fixture("target 'App' do\nend\n")
        let lock = directory.appendingPathComponent(SwiftPodsLock.fileName)
        let contents = """
            {"version":1,"catalogs":[{"url":"https://example.com/old.git","revision":"\(String(repeating: "a", count: 40))","entries":[{"name":"Old","sha256":"\(String(repeating: "0", count: 64))"}]}]}
            """
        try contents.write(to: lock, atomically: true, encoding: .utf8)
        var options = InstallOptions()
        options.deployment = true

        _ = try installer(directory).install(options)

        XCTAssertEqual(try String(contentsOf: lock, encoding: .utf8), contents)
    }

    func testDeintegratePreservesUnknownGeneratedEntries() throws {
        let directory = try fixture("target 'App' do\nend\n")
        _ = try installer(directory).install(.init())
        let root = directory.appendingPathComponent("SwiftPods", isDirectory: true)
        let unknown = root.appendingPathComponent("Keep.txt")
        let unknownDirectory = root.appendingPathComponent("UserData", isDirectory: true)
        let stagingPrefix = root.appendingPathComponent(".staging-not-swiftpods", isDirectory: true)
        let unmarkedStaging = root.appendingPathComponent(
            ".swiftpods-staging-00000000-0000-0000-0000-000000000000", isDirectory: true)
        let markedStaging = root.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try "keep\n".write(to: unknown, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: unknownDirectory, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: stagingPrefix, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: unmarkedStaging, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: markedStaging, withIntermediateDirectories: false)
        try Data("SwiftPods generated staging v1\n".utf8).write(to: markedStaging.appendingPathComponent(".swiftpods-staging"))
        try Data("Unrelated data\n".utf8).write(to: unknownDirectory.appendingPathComponent(".swiftpods-staging"))
        try "nested\n".write(
            to: unknownDirectory.appendingPathComponent("value.txt"), atomically: true, encoding: .utf8)

        _ = try installer(directory).deintegrate()

        XCTAssertEqual(try String(contentsOf: unknown, encoding: .utf8), "keep\n")
        XCTAssertEqual(
            try String(contentsOf: unknownDirectory.appendingPathComponent("value.txt"), encoding: .utf8), "nested\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagingPrefix.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unmarkedStaging.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: markedStaging.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Scripts").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("SwiftPodsDependencies").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".swiftpods-owned").path))
    }

    func testInstallLeavesStagingInAnUnownedRootAlone() throws {
        let directory = try fixture("target 'App' do\nend\n")
        let root = directory.appendingPathComponent("SwiftPods")
        let staging = root.appendingPathComponent(".swiftpods-staging-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let marker = staging.appendingPathComponent(".swiftpods-staging")
        let contents = Data("SwiftPods generated staging v1\n".utf8)
        try contents.write(to: marker)
        let journal = directory.appendingPathComponent(".swiftpods-transaction")
        try Data("recovery data\n".utf8).write(to: journal)

        XCTAssertThrowsError(try installer(directory).install(.init())) {
            XCTAssertTrue("\($0)".contains("Refusing to manage non-SwiftPods directory"), "\($0)")
        }
        XCTAssertEqual(try Data(contentsOf: marker), contents)
        XCTAssertEqual(try Data(contentsOf: journal), Data("recovery data\n".utf8))
    }

    func testRemoteBinariesAreVerifiedAndCached() throws {
        let directory = try fixture("target 'App' do\nend\n")
        let source = directory.appendingPathComponent("archive-source")
        let framework = source.appendingPathComponent("SDK/Remote.xcframework")
        try makeXCFramework(framework)
        try FileManager.default.createSymbolicLink(atPath: framework.appendingPathComponent("Metadata").path, withDestinationPath: "Info.plist")
        try FileManager.default.createSymbolicLink(atPath: framework.appendingPathComponent("Current").path, withDestinationPath: "Metadata")
        let archive = directory.appendingPathComponent("Remote.zip")
        _ = try ProcessRunner().run("/usr/bin/ditto", ["-c", "-k", source.path, archive.path], in: nil)
        let digest = try ProcessRunner().run("/usr/bin/shasum", ["-a", "256", archive.path], in: nil).split(separator: " ")[0]

        let wrong = String(repeating: "0", count: 64)
        try "target 'App' do\n  binary 'Remote', url: '\(archive.absoluteString)', sha256: '\(wrong)'\nend\n"
            .write(to: directory.appendingPathComponent("Podfile"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try installer(directory).install(InstallOptions())) { error in
            let message = "\(error)"
            XCTAssertTrue(message.contains("does not match the Podfile SHA-256"), message)
            XCTAssertFalse(message.contains(digest), "Untrusted response digests must not be disclosed: \(message)")
        }
        XCTAssertEqual(try project(directory).serialized(), Fixtures.project, "A failed install changes nothing")

        try "target 'App' do\n  binary 'Remote', url: '\(archive.absoluteString)', sha256: '\(digest)'\nend\n"
            .write(to: directory.appendingPathComponent("Podfile"), atomically: true, encoding: .utf8)
        _ = try installer(directory).install(InstallOptions())
        let generatedFramework = directory.appendingPathComponent("SwiftPods/SwiftPodsBinaries/Artifacts/Remote/Remote.xcframework")
        XCTAssertTrue(FileManager.default.fileExists(atPath: generatedFramework.path))
        XCTAssertEqual(
            try Data(contentsOf: generatedFramework.appendingPathComponent("Current")),
            try Data(contentsOf: generatedFramework.appendingPathComponent("Info.plist")))

        // A matching self-declared fingerprint must not let a modified generated artifact survive another install.
        let generatedInfo = generatedFramework.appendingPathComponent("Info.plist")
        let trustedInfo = try Data(contentsOf: generatedInfo)
        try Data("tampered".utf8).write(to: generatedInfo)
        var offline = InstallOptions()
        offline.offline = true
        _ = try installer(directory).install(offline)
        XCTAssertEqual(try Data(contentsOf: generatedInfo), trustedInfo)

        try FileManager.default.removeItem(at: archive)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("SwiftPods"))
        _ = try installer(directory).install(offline)
    }

    func testDownloadErrorOmitsURLAndCurlOutput() throws {
        let directory = try fixture("""
            target 'App' do
              binary 'Remote', url: 'https://example.com/sdk.zip?signature=test-value', sha256: '\(String(repeating: "0", count: 64))'
            end
            """)
        let runner = RecordingRunner { _, _, _ in throw SwiftPodsError("curl transport diagnostic") }
        let installer = Installer(directory: directory, runner: runner, cache: directory.appendingPathComponent(".cache"))
        XCTAssertThrowsError(try installer.install(.init())) { error in
            let message = "\(error)"
            XCTAssertTrue(message.contains("Cannot download binary"), message)
            XCTAssertFalse(message.contains("test-value"), message)
            XCTAssertFalse(message.contains("curl transport diagnostic"), message)
        }
        XCTAssertEqual(runner.invocations.map(\.executable), ["/usr/bin/curl"])
    }

    func testDuplicateLockRecordsAreRejectedDuringDecoding() throws {
        let file = URL(fileURLWithPath: "/SwiftPods.lock")
        let entry = #"{"name":"Kit","sha256":"0000000000000000000000000000000000000000000000000000000000000000"}"#
        let catalog = #"{"url":"https://example.com/catalog.git","revision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","entries":[\#(entry)]}"#
        let duplicateEntry = catalog.replacingOccurrences(of: entry, with: "\(entry),\(entry.replacingOccurrences(of: "Kit", with: "kit"))")
        let override = #"{"identity":"kit","url":"https://example.com/kit.git","revision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","submodules":true,"sha256":"0000000000000000000000000000000000000000000000000000000000000000","metadataPaths":[]}"#
        let invalidLocks = [
            (#"{"version":1,"catalogs":[\#(catalog),\#(catalog)]}"#, "duplicate catalog URL"),
            (#"{"version":1,"catalogs":[\#(duplicateEntry)]}"#, "duplicate entry"),
            (#"{"version":2,"catalogs":[],"overrides":[\#(override),\#(override)]}"#, "duplicate package override"),
        ]
        for (contents, diagnostic) in invalidLocks {
            XCTAssertThrowsError(try SwiftPodsLock(data: Data(contents.utf8), file: file)) {
                XCTAssertTrue("\($0)".contains(diagnostic), "\($0)")
            }
        }
    }

    func testDeploymentRequiresSatisfyingPins() throws {
        let directory = try fixture("target 'App' do\n  spm 'https://github.com/a/Kit.git', '~> 1.2'\nend\n")
        let deploymentInstaller = Installer(
            directory: directory, runner: RecordingRunner(), cache: directory.appendingPathComponent(".cache"))
        var options = InstallOptions()
        options.deployment = true
        XCTAssertThrowsError(try deploymentInstaller.install(options)) { XCTAssertTrue("\($0)".contains("Package.resolved"), "\($0)") }

        let resolved = directory.appendingPathComponent("App.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
        try FileManager.default.createDirectory(at: resolved.deletingLastPathComponent(), withIntermediateDirectories: true)
        func pin(_ version: String) throws {
            let json = #"{"pins":[{"identity":"kit","kind":"remoteSourceControl","location":"https://github.com/a/Kit","state":{"revision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","version":"\#(version)"}}],"version":3}"#
            try json.write(to: resolved, atomically: true, encoding: .utf8)
        }
        try pin("2.0.0")
        XCTAssertThrowsError(try deploymentInstaller.install(options)) {
            XCTAssertTrue("\($0)".contains("pinned to 2.0.0, the Podfile requires 1.2.0 up to next major"), "\($0)")
        }
        try pin("1.4.1")
        _ = try deploymentInstaller.install(options)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(SwiftPodsLock.fileName).path))
    }

    func testResolveValidationFailureRollsBackCreatedPathAndProject() throws {
        let directory = try fixture(
            "target 'App' do\n  spm 'https://github.com/a/Kit.git', exact: '1.0.0'\nend\n")
        let projectFile = directory.appendingPathComponent("App.xcodeproj/project.pbxproj")
        let originalProject = try Data(contentsOf: projectFile)
        XCTAssertEqual(chmod(projectFile.path, 0o640), 0)
        var originalStatus = stat()
        XCTAssertEqual(lstat(projectFile.path, &originalStatus), 0)

        let resolved = PackageResolved.location(project: directory.appendingPathComponent("App.xcodeproj"))
        let runner = RecordingRunner { _, _, _ in
            try FileManager.default.createDirectory(
                at: resolved.deletingLastPathComponent(), withIntermediateDirectories: true)
            let invalid = #"{"pins":[{"identity":"kit","kind":"remoteSourceControl","location":"https://github.com/a/Kit.git","state":{"revision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","version":"2.0.0"}}],"version":3}"#
            try Data(invalid.utf8).write(to: resolved)
            return ""
        }
        var options = InstallOptions()
        options.resolve = true
        XCTAssertThrowsError(try Installer(
            directory: directory, runner: runner, cache: directory.appendingPathComponent(".cache")
        ).install(options)) { error in
            XCTAssertTrue("\(error)".contains("does not allow"), "\(error)")
        }

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("App.xcodeproj/project.xcworkspace").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("SwiftPods").path))
        XCTAssertEqual(try Data(contentsOf: projectFile), originalProject)
        var restoredStatus = stat()
        XCTAssertEqual(lstat(projectFile.path, &restoredStatus), 0)
        XCTAssertEqual(restoredStatus.st_mode & 0o7777, originalStatus.st_mode & 0o7777)
    }

    private func resolverMetadataFixture() throws -> (directory: URL, resolved: URL, package: URL) {
        let directory = try fixture(
            "target 'App' do\n  spm 'https://github.com/a/Kit.git', exact: '1.0.0', products: ['Kit']\nend\n")
        let resolved = PackageResolved.location(project: directory.appendingPathComponent("App.xcodeproj"))
        try FileManager.default.createDirectory(at: resolved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"pins":[{"identity":"kit","kind":"remoteSourceControl","location":"https://github.com/a/Kit.git","state":{"revision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","version":"1.0.0"}}],"version":3}"#.utf8).write(to: resolved)
        return (directory, resolved, directory.appendingPathComponent("SwiftPods/SwiftPodsDependencies"))
    }

    private func createResolverMetadata(in package: URL) throws {
        for name in [".swiftpm", ".build"] {
            let metadata = package.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
            XCTAssertEqual(chmod(metadata.path, 0o775), 0)
            let file = metadata.appendingPathComponent("workspace-state.json")
            try Data("resolver state".utf8).write(to: file)
            XCTAssertEqual(chmod(file.path, 0o664), 0)
        }
    }

    func testResolveAcceptsDerivedMetadataAndRemainsIdempotent() throws {
        let fixture = try resolverMetadataFixture()
        let runner = RecordingRunner { _, _, _ in
            try self.createResolverMetadata(in: fixture.package)
            return ""
        }
        let installer = Installer(directory: fixture.directory, runner: runner, cache: fixture.directory.appendingPathComponent(".cache"))
        var options = InstallOptions()
        options.resolve = true
        _ = try installer.install(options)
        XCTAssertTrue(try installer.install(InstallOptions()).projects.flatMap(\.changes).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.package.appendingPathComponent(".swiftpm/workspace-state.json").path))
        // Replacement and removal also retain full-tree CAS/cleanup, including Xcode's writable metadata.
        try Data("target 'App' do\n  spm 'https://github.com/a/Kit.git', exact: '2.0.0', products: ['Kit']\nend\n".utf8)
            .write(to: fixture.directory.appendingPathComponent("Podfile"))
        _ = try installer.install(InstallOptions())
        let installed = try project(fixture.directory)
        let kit = installed.project.strings("packageReferences").compactMap { installed[$0] }
            .first { $0.string("repositoryURL") == "https://github.com/a/Kit.git" }
        XCTAssertEqual(kit?["requirement"]?.dictionary?["version"]?.string, "2.0.0")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.package.appendingPathComponent(".swiftpm/workspace-state.json").path))
        let report = try installer.deintegrate()
        XCTAssertEqual(report.notes, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("SwiftPods").path))
    }

    func testResolveFailureWithDerivedMetadataRollsBackCleanly() throws {
        let fixture = try resolverMetadataFixture()
        let project = fixture.directory.appendingPathComponent("App.xcodeproj/project.pbxproj")
        let original = try Data(contentsOf: project)
        let runner = RecordingRunner { _, _, _ in
            try self.createResolverMetadata(in: fixture.package)
            throw SwiftPodsError("intentional resolver failure")
        }
        var options = InstallOptions()
        options.resolve = true
        XCTAssertThrowsError(try Installer(directory: fixture.directory, runner: runner).install(options)) { error in
            XCTAssertTrue("\(error)".contains("intentional resolver failure"), "\(error)")
            XCTAssertFalse("\(error)".contains("rollback was incomplete"), "\(error)")
        }
        XCTAssertEqual(try Data(contentsOf: project), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("SwiftPods").path))
    }

    func testResolveCommandFailureRollsBackItsNewPackageResolvedPath() throws {
        let directory = try fixture(
            "target 'App' do\n  spm 'https://github.com/a/Kit.git', exact: '1.0.0'\nend\n")
        let projectFile = directory.appendingPathComponent("App.xcodeproj/project.pbxproj")
        let originalProject = try Data(contentsOf: projectFile)
        let projectURL = directory.appendingPathComponent("App.xcodeproj")
        let resolved = PackageResolved.location(project: projectURL)
        let runner = RecordingRunner { _, _, _ in
            try FileManager.default.createDirectory(
                at: resolved.deletingLastPathComponent().appendingPathComponent("configuration"),
                withIntermediateDirectories: true)
            try Data(#"{"pins":[],"version":3}"#.utf8).write(to: resolved)
            throw SwiftPodsError("resolver failed after creating Package.resolved")
        }
        var options = InstallOptions()
        options.resolve = true
        XCTAssertThrowsError(try Installer(
            directory: directory, runner: runner, cache: directory.appendingPathComponent(".cache")
        ).install(options)) { error in
            XCTAssertTrue("\(error)".contains("resolver failed after creating"), "\(error)")
            XCTAssertFalse("\(error)".contains("rollback was incomplete"), "\(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: projectURL.appendingPathComponent("project.xcworkspace").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("SwiftPods").path))
        XCTAssertEqual(try Data(contentsOf: projectFile), originalProject)
    }

    func testRollbackFailurePreservesGeneratedBackupsAcrossRetry() throws {
        guard geteuid() != 0 else { throw XCTSkip("Requires directory permissions to apply to the installer") }
        let directory = try fixture("target 'App' do\n  settings 'REVIEW_SETTING' => 'original'\nend\n")
        _ = try installer(directory).install(.init())
        let generated = directory.appendingPathComponent("SwiftPods")
        let settings = "Settings/App/App.xcconfig"
        let original = try Data(contentsOf: generated.appendingPathComponent(settings))
        try Data("target 'App' do\n  settings 'REVIEW_SETTING' => 'updated'\nend\n".utf8)
            .write(to: directory.appendingPathComponent("Podfile"))

        let runner = RecordingRunner { _, _, _ in
            guard chmod(generated.path, 0o555) == 0 else { throw SwiftPodsError("Could not make the generated directory read-only") }
            throw SwiftPodsError("Package resolution failed after publishing settings")
        }
        defer { chmod(generated.path, 0o755) }
        var options = InstallOptions()
        options.resolve = true
        XCTAssertThrowsError(try Installer(directory: directory, runner: runner).install(options)) {
            let message = "\($0)"
            XCTAssertTrue(message.contains("rollback was incomplete"), message)
            XCTAssertTrue(message.contains("Package resolution failed"), message)
            XCTAssertTrue(message.contains(".swiftpods-staging-"), message)
        }
        XCTAssertEqual(chmod(generated.path, 0o755), 0)
        let staging = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: generated.path)
            .first { $0.hasPrefix(".swiftpods-staging-") })
        let backup = generated.appendingPathComponent(staging).appendingPathComponent(".previous-" + settings)
        XCTAssertEqual(try Data(contentsOf: backup), original)

        _ = try installer(directory).install(.init())
        XCTAssertEqual(try Data(contentsOf: backup), original)
        XCTAssertTrue(try String(contentsOf: generated.appendingPathComponent(settings), encoding: .utf8).contains("REVIEW_SETTING = updated"))
        _ = try installer(directory).deintegrate()
        _ = try installer(directory).install(.init())
        XCTAssertEqual(try Data(contentsOf: backup), original)
    }

    func testDeploymentUsesOneFrozenFullGraphResolutionAndPreservesTheLock() throws {
        let directory = try fixture(
            "target 'App' do\n  spm 'https://github.com/a/Kit.git', exact: '1.0.0', products: ['Kit']\nend\n")
        let resolved = directory.appendingPathComponent(
            "App.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
        try FileManager.default.createDirectory(at: resolved.deletingLastPathComponent(), withIntermediateDirectories: true)
        let contents = #"{"pins":[{"identity":"kit","kind":"remoteSourceControl","location":"https://github.com/a/Kit.git","state":{"revision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","version":"1.0.0"}},{"identity":"transitive","kind":"remoteSourceControl","location":"https://github.com/a/Transitive.git","state":{"revision":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","version":"2.0.0"}}],"version":3}"#
        try Data(contents.utf8).write(to: resolved)

        let runner = RecordingRunner()
        var options = InstallOptions()
        options.deployment = true
        options.resolve = true
        _ = try Installer(directory: directory, runner: runner, cache: directory.appendingPathComponent(".cache")).install(options)

        XCTAssertEqual(runner.invocations.count, 1)
        let invocation = try XCTUnwrap(runner.invocations.first)
        XCTAssertEqual(invocation.executable, "/usr/bin/xcrun")
        XCTAssertEqual(invocation.directory?.standardizedFileURL.path, directory.standardizedFileURL.path)
        XCTAssertEqual(Array(invocation.arguments.suffix(2)), ["-project", "App.xcodeproj"])
        XCTAssertTrue(invocation.arguments.contains("-resolvePackageDependencies"), "\(invocation.arguments)")
        XCTAssertTrue(invocation.arguments.contains("-disableAutomaticPackageResolution"), "\(invocation.arguments)")
        XCTAssertTrue(invocation.arguments.contains("-onlyUsePackageVersionsFromResolvedFile"), "\(invocation.arguments)")
        XCTAssertTrue(invocation.arguments.contains("-skipPackageUpdates"), "\(invocation.arguments)")
        XCTAssertEqual(try Data(contentsOf: resolved), Data(contents.utf8))
    }

    func testDeploymentChecksLocalPackagesWithoutAnExistingResolvedFile() throws {
        let directory = try fixture("target 'App' do\n  spm 'Kit', path: 'Modules/Kit'\nend\n")
        let project = directory.appendingPathComponent("App.xcodeproj")
        let resolved = PackageResolved.location(project: project)
        let projectFile = project.appendingPathComponent("project.pbxproj")
        let originalProject = try Data(contentsOf: projectFile)
        var options = InstallOptions()
        options.deployment = true

        let writesPins = RecordingRunner { _, arguments, _ in
            XCTAssertTrue(arguments.contains("-onlyUsePackageVersionsFromResolvedFile"))
            try FileManager.default.createDirectory(at: resolved.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(#"{"version":3,"pins":[]}"#.utf8).write(to: resolved)
            return ""
        }
        XCTAssertThrowsError(try Installer(directory: directory, runner: writesPins).install(options)) {
            XCTAssertTrue("\($0)".contains("modified Package.resolved"), "\($0)")
        }
        XCTAssertEqual(try Data(contentsOf: projectFile), originalProject)
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent("project.xcworkspace").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("SwiftPods").path))

        let localOnly = RecordingRunner()
        _ = try Installer(directory: directory, runner: localOnly).install(options)
        XCTAssertEqual(localOnly.invocations.count, 1)
        XCTAssertTrue(localOnly.invocations.first?.arguments.contains("-onlyUsePackageVersionsFromResolvedFile") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: resolved.path))
    }

    func testDeploymentAlsoChecksLocalPackagesOnlyInXcode() throws {
        let directory = try fixture("target 'App' do\nend\n")
        var before = try project(directory)
        let group = try XCTUnwrap(before.project.string("mainGroup"))
        let app = try XCTUnwrap(before.nativeTargets.first { $0.name == "App" }?.id)
        let localPackage = before.put("hand-added package", [
            "isa": "PBXFileReference", "lastKnownFileType": "wrapper", "path": "Modules/Kit", "sourceTree": "SOURCE_ROOT",
        ])
        let product = before.put("hand-added product", ["isa": "XCSwiftPackageProductDependency", "productName": "Kit"])
        before.append(localPackage, to: "children", of: group)
        before.append(product, to: "packageProductDependencies", of: app)
        try before.save()
        let original = try Data(contentsOf: before.file)
        let runner = RecordingRunner { _, arguments, _ in
            XCTAssertTrue(arguments.contains("-onlyUsePackageVersionsFromResolvedFile"))
            throw SwiftPodsError("Xcode requires a lock for the transitive dependency")
        }
        var options = InstallOptions()
        options.deployment = true
        XCTAssertThrowsError(try Installer(directory: directory, runner: runner).install(options)) {
            XCTAssertTrue("\($0)".contains("Xcode requires a lock"), "\($0)")
        }
        XCTAssertEqual(runner.invocations.count, 1)
        XCTAssertEqual(try Data(contentsOf: before.file), original)
    }

    func testDeploymentFailsIfFrozenResolutionFailsOrMutatesTheLock() throws {
        func setup() throws -> (URL, URL, Data) {
            let directory = try fixture(
                "target 'App' do\n  spm 'https://github.com/a/Kit.git', exact: '1.0.0', products: ['Kit']\nend\n")
            let resolved = directory.appendingPathComponent(
                "App.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
            try FileManager.default.createDirectory(at: resolved.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = Data(#"{"pins":[{"identity":"kit","kind":"remoteSourceControl","location":"https://github.com/a/Kit.git","state":{"revision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","version":"1.0.0"}}],"version":3}"#.utf8)
            try data.write(to: resolved)
            return (directory, resolved, data)
        }
        var options = InstallOptions()
        options.deployment = true

        let (incompleteDirectory, incompleteResolved, original) = try setup()
        let incompleteProject = incompleteDirectory.appendingPathComponent("App.xcodeproj/project.pbxproj")
        let originalProject = try Data(contentsOf: incompleteProject)
        let failing = RecordingRunner { _, arguments, _ in
            XCTAssertTrue(arguments.contains("-onlyUsePackageVersionsFromResolvedFile"))
            throw SwiftPodsError("Frozen resolver rejected an incomplete transitive graph")
        }
        XCTAssertThrowsError(
            try Installer(
                directory: incompleteDirectory, runner: failing,
                cache: incompleteDirectory.appendingPathComponent(".cache")
            ).install(options)
        ) { error in
            XCTAssertTrue("\(error)".contains("incomplete transitive graph"), "\(error)")
        }
        XCTAssertEqual(try Data(contentsOf: incompleteResolved), original)
        XCTAssertEqual(try Data(contentsOf: incompleteProject), originalProject)
        XCTAssertFalse(FileManager.default.fileExists(atPath: incompleteDirectory.appendingPathComponent("SwiftPods").path))

        let (mutatingDirectory, mutatingResolved, mutatingOriginal) = try setup()
        let mutating = RecordingRunner { _, _, _ in
            let changed = #"{"pins":[{"identity":"kit","kind":"remoteSourceControl","location":"https://github.com/a/Kit.git","state":{"revision":"cccccccccccccccccccccccccccccccccccccccc","version":"1.0.0"}}],"version":3}"#
            try Data(changed.utf8).write(to: mutatingResolved)
            return ""
        }
        XCTAssertThrowsError(
            try Installer(
                directory: mutatingDirectory, runner: mutating,
                cache: mutatingDirectory.appendingPathComponent(".cache")
            ).install(options)
        ) { error in
            XCTAssertTrue("\(error)".contains("modified Package.resolved"), "\(error)")
        }
        XCTAssertEqual(try Data(contentsOf: mutatingResolved), mutatingOriginal)
    }

    func testMissingTargetsAndBaseConfigurations() throws {
        let missing = try fixture("target 'Nope' do\nend\n")
        XCTAssertThrowsError(try installer(missing).install(InstallOptions())) {
            XCTAssertTrue("\($0)".contains("has no target `Nope`"), "\($0)")
        }

        let directory = try fixture(
            "target 'App' do\n  settings 'A' => 'B'\nend\n", files: ["Config/App.xcconfig": "SDKROOT = iphoneos\n"])
        var edited = try project(directory)
        edited["C00000000000000000000001"] = ["isa": "PBXFileReference", "path": "Config/App.xcconfig", "sourceTree": "SOURCE_ROOT"]
        for id in edited.configurations(of: edited.nativeTargets[0].id).values {
            edited[id]!["baseConfigurationReference"] = "C00000000000000000000001"
        }
        try edited.save()
        XCTAssertThrowsError(try installer(directory).install(InstallOptions())) {
            XCTAssertTrue("\($0)".contains(#"#include? "../SwiftPods/Settings/App/App.xcconfig""#), "\($0)")
        }
        let config = directory.appendingPathComponent("Config/App.xcconfig")
        try "#include \"Other.xcconfig\" // \"../SwiftPods/Settings/App/App.xcconfig\"\n"
            .write(to: config, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try installer(directory).install(InstallOptions())) {
            XCTAssertTrue("\($0)".contains("already uses"), "\($0)")
        }
        let real = directory.appendingPathComponent("Config/Real.xcconfig")
        try "#include? \"../SwiftPods/Settings/App/App.xcconfig\" /* SwiftPods */\nSDKROOT = iphoneos\n"
            .write(to: real, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: config)
        try FileManager.default.createSymbolicLink(at: config, withDestinationURL: real)
        _ = try installer(directory).install(InstallOptions())
        let after = try project(directory)
        XCTAssertTrue(after.configurations(of: after.nativeTargets[0].id).values.allSatisfy {
            after[$0]?.string("baseConfigurationReference") == "C00000000000000000000001"
        })

        // Application targets always need SwiftPods' platform-specific runtime search path, even without Podfile settings.
        try FileManager.default.removeItem(at: config)
        try "SDKROOT = iphoneos\n".write(to: config, atomically: true, encoding: .utf8)
        try "target 'App' do\nend\n".write(to: directory.appendingPathComponent("Podfile"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try installer(directory).install(InstallOptions())) {
            XCTAssertTrue("\($0)".contains(#"#include? "../SwiftPods/Settings/App/App.xcconfig""#), "\($0)")
        }
        try "#include? \"../SwiftPods/Settings/App/App.xcconfig\"\nSDKROOT = iphoneos\n"
            .write(to: config, atomically: true, encoding: .utf8)
        _ = try installer(directory).install(InstallOptions())
    }

    func testDuplicateNativeTargetNamesAreRejected() throws {
        let directory = try fixture("target 'App' do\nend\n")
        var edited = try project(directory)
        let duplicate = try XCTUnwrap(edited.nativeTargets.first { $0.name == "AppTests" })
        edited[duplicate.id]!["name"] = "App"
        try edited.save()

        XCTAssertThrowsError(try installer(directory).install(.init())) {
            XCTAssertTrue("\($0)".contains("more than one native target named `App`"), "\($0)")
        }
    }

    func testLegacyCrashlyticsPathIsMigratedByTheSafeProjectWriter() throws {
        let directory = try fixture("target 'App' do\nend\n")
        var edited = try project(directory)
        let target = try XCTUnwrap(edited.nativeTargets.first { $0.name == "App" })
        let phase = "D00000000000000000000099"
        let old = "${PROJECT_DIR}/Pods/FirebaseCrashlytics/run"
        edited[phase] = [
            "isa": "PBXShellScriptBuildPhase", "name": "Crashlytics", "shellPath": "/bin/sh", "shellScript": .string(old),
        ]
        edited.append(phase, to: "buildPhases", of: target.id)
        try edited.save()

        _ = try installer(directory).install(.init())
        let installed = try project(directory)
        let script = try XCTUnwrap(installed[phase]?.string("shellScript"))
        XCTAssertFalse(script.contains("/Pods/FirebaseCrashlytics/"), script)
        XCTAssertTrue(script.contains("/SourcePackages/checkouts/firebase-ios-sdk/Crashlytics/"), script)
    }

    func testCRLFScriptFileListsRemainUsable() throws {
        let directory = try fixture(
            "target 'App' do\n  script_phase name: 'Build', script: 'true', input_file_lists: ['Inputs.xcfilelist']\nend\n",
            files: ["Inputs.xcfilelist": "Sources/One.swift\r\n# comment\r\nSources/Two.swift\r\n"])

        _ = try installer(directory).install(.init())

        let inputs = try generated(directory, "Scripts/App/App/finish.inputs.xcfilelist")
        XCTAssertTrue(inputs.contains("Sources/One.swift\n"), inputs)
        XCTAssertTrue(inputs.contains("Sources/Two.swift\n"), inputs)
        XCTAssertFalse(inputs.contains("\r"), inputs)
    }

    func testScriptFileListBytesParticipateInBuildFreshness() throws {
        let contents = "Sources/One.swift\nSources/Two.swift\n"
        let directory = try fixture(
            "target 'App' do\n  script_phase name: 'Build', script: 'true', input_file_lists: ['Inputs.xcfilelist']\nend\n",
            files: ["Inputs.xcfilelist": contents])

        _ = try installer(directory).install(.init())

        let digest = SHA256.hash(data: Data(contents.utf8)).map { String(format: "%02x", $0) }.joined()
        let signature = try generated(directory, "Scripts/Podfile.sha256")
        XCTAssertTrue(signature.contains("\(digest)  Inputs.xcfilelist\n"), signature)
        let prepareInputs = try generated(directory, "Scripts/App/App/prepare.inputs.xcfilelist")
        XCTAssertTrue(prepareInputs.contains("$(SRCROOT)/Inputs.xcfilelist\n"), prepareInputs)
    }

    func testAnInterruptedResolutionRollsTheInstallBack() throws {
        defer { Interruption.reset() }
        let directory = try fixture("target 'App' do\n  spm 'https://github.com/a/Bar.git', exact: '1.0.0', products: ['Bar']\nend\n")
        let projectFile = directory.appendingPathComponent("App.xcodeproj/project.pbxproj")
        let original = try Data(contentsOf: projectFile)
        // SIGINT arrives while Xcode resolves packages, after the generated folders and the project were written.
        let runner = RecordingRunner { _, _, _ in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { Interruption.record(SIGINT) }
            return try ProcessRunner().run("/bin/sleep", ["30"], in: nil)
        }
        var options = InstallOptions()
        options.resolve = true
        let start = Date()
        XCTAssertThrowsError(try Installer(directory: directory, runner: runner, cache: directory.appendingPathComponent(".cache"))
            .install(options)) {
            XCTAssertTrue("\($0)".contains("Interrupted by SIGINT"), "\($0)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        XCTAssertEqual(try Data(contentsOf: projectFile), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("SwiftPods").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(SwiftPodsLock.fileName).path))
    }

    func testAnInterruptionAfterDeintegrationStartsRestoresTheProjects() throws {
        let directory = try fixture("")
        let projects = (0..<64).map { directory.appendingPathComponent("Project-\($0).xcodeproj") }
        let podfile = projects.map { "target 'App' do\n  project '\($0.lastPathComponent)'\nend\n" }.joined(separator: "\n")
        try Data(podfile.utf8).write(to: directory.appendingPathComponent("Podfile"))
        let projectFiles = try projects.map { project in
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
            let file = project.appendingPathComponent("project.pbxproj")
            try Data(Fixtures.project.utf8).write(to: file)
            return file
        }
        let installer = self.installer(directory)
        _ = try installer.install(.init())
        let originals = try projectFiles.map { try Data(contentsOf: $0) }
        let generated = directory.appendingPathComponent("SwiftPods/SwiftPodsDependencies")
        let descriptor = open(generated.path, O_EVTONLY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        let events = DispatchQueue(label: "SwiftPods tests deintegrate")
        let watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .rename, queue: events)
        watcher.setEventHandler { Interruption.record(SIGTERM) }
        watcher.setCancelHandler { close(descriptor) }
        watcher.resume()
        defer {
            watcher.cancel()
            events.sync { Interruption.reset() }
        }

        XCTAssertThrowsError(try installer.deintegrate()) { error in
            XCTAssertTrue("\(error)".contains("Interrupted by SIGTERM"), "\(error)")
        }
        XCTAssertTrue(FileTree.isDirectory(generated))
        XCTAssertEqual(try projectFiles.map { try Data(contentsOf: $0) }, originals)
    }

    func testAFileListThatExistsButCannotBeReadFailsTheInstall() throws {
        let directory = try fixture(
            "target 'App' do\n  script_phase name: 'Build', script: 'true', input_file_lists: ['Inputs.xcfilelist']\nend\n")
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("Inputs.xcfilelist"), withIntermediateDirectories: false)

        XCTAssertThrowsError(try installer(directory).install(.init())) {
            XCTAssertTrue("\($0)".contains("Cannot read file list"), "\($0)")
        }
    }

    func testAFileListBehindAnInaccessibleDirectoryFailsTheInstall() throws {
        guard geteuid() != 0 else { throw XCTSkip("Requires directory permissions to apply to the installer") }
        let directory = try fixture(
            "target 'App' do\n  script_phase name: 'Build', script: 'true', input_file_lists: ['Lists/Inputs.xcfilelist']\nend\n",
            files: ["Lists/Inputs.xcfilelist": "main.swift\n"])
        let lists = directory.appendingPathComponent("Lists")
        XCTAssertEqual(chmod(lists.path, 0o000), 0)
        defer { chmod(lists.path, 0o755) }
        XCTAssertThrowsError(try installer(directory).install(.init())) {
            XCTAssertTrue("\($0)".contains("Cannot read file list"), "\($0)")
        }
    }

    func testMissingInheritedScriptFileListProducesOneBoundedNote() throws {
        let directory = try fixture(
            """
            group :shared_lists do
              script_phase name: 'Build', script: 'true', input_file_lists: ['Missing.xcfilelist']
            end
            target 'App' do
              use :shared_lists
            end
            target 'AppTests' do
              use :shared_lists
            end
            target 'Plugin' do
              use :shared_lists
            end
            """)

        let report = try installer(directory).install(.init())
        let warnings = report.notes.filter { $0.contains("file list") && $0.contains("was not found") }
        XCTAssertEqual(warnings.count, 1, "\(report.notes)")
        XCTAssertTrue(warnings[0].contains("referenced 3 times across targets"), warnings[0])
    }

    func testLegacyGeneratedRootRequiresTheExactManagedLayoutAndHeader() throws {
        let directory = try fixture("target 'App' do\nend\n")
        let root = directory.appendingPathComponent("SwiftPods", isDirectory: true)
        let dependencies = root.appendingPathComponent("SwiftPodsDependencies", isDirectory: true)
        try FileManager.default.createDirectory(at: dependencies, withIntermediateDirectories: true)
        try "// Generated by SwiftPods hidden in attacker-controlled text\n"
            .write(to: dependencies.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try installer(directory).install(.init())) { error in
            XCTAssertTrue("\(error)".contains("Refusing to manage non-SwiftPods directory"), "\(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".swiftpods-owned").path))
    }

    func testGeneratedPackageDisambiguatesSanitizedModuleNames() throws {
        let directory = try fixture("target 'A-B' do\nend\ntarget 'A_B' do\nend\n")
        var edited = try project(directory)
        edited[edited.nativeTargets[0].id]!["name"] = "A-B"
        edited[edited.nativeTargets[1].id]!["name"] = "A_B"
        try edited.save()

        _ = try installer(directory).install(InstallOptions())
        let manifest = try generated(directory, "SwiftPodsDependencies/Package.swift")
        XCTAssertTrue(manifest.contains(#".library(name: "SwiftPods-A-B""#), manifest)
        XCTAssertTrue(manifest.contains(#".library(name: "SwiftPods-A_B""#), manifest)
        let source = directory.appendingPathComponent("SwiftPods/SwiftPodsDependencies/Sources")
        let modules = try FileManager.default.contentsOfDirectory(atPath: source.path).sorted()
        XCTAssertEqual(modules.count, 2)
        XCTAssertNotEqual(modules[0].lowercased(), modules[1].lowercased())
    }
}
