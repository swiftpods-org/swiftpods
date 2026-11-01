import CryptoKit
import Darwin
import Foundation
@testable import SwiftPodsKit
import SwiftPodsManifest
import SwiftPodsTestSupport
import SwiftPodsXcode
import XCTest

final class InstallerTests: XCTestCase {
    private final class RecordingRunner: DescriptorWorkingDirectoryCommandRunner, @unchecked Sendable {
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

        func run(
            _ executable: String, _ arguments: [String], in directory: URL?, timeout: TimeInterval
        ) throws -> String {
            try run(executable, arguments, in: directory)
        }

        func runDescriptorBacked(
            _ executable: String, _ arguments: [String], workingDirectoryDescriptor: Int32,
            timeout: TimeInterval
        ) throws -> String {
            try run(executable, arguments, in: nil)
        }

        func runData(
            _ executable: String, _ arguments: [String], in directory: URL?, timeout: TimeInterval,
            maximumOutputBytes: Int
        ) throws -> Data {
            let data = Data(try run(executable, arguments, in: directory).utf8)
            guard data.count <= maximumOutputBytes else { throw SwiftPodsError("Test command output exceeded its limit") }
            return data
        }
    }

    private final class DescriptorRunner: DescriptorWorkingDirectoryCommandRunner, @unchecked Sendable {
        private let handler: (String, [String], Int32) throws -> String

        init(_ handler: @escaping (String, [String], Int32) throws -> String) {
            self.handler = handler
        }

        func run(_ executable: String, _ arguments: [String], in directory: URL?) throws -> String {
            throw SwiftPodsError("Resolver unexpectedly used a pathname-backed test runner")
        }

        func runDescriptorBacked(
            _ executable: String, _ arguments: [String], workingDirectoryDescriptor: Int32,
            timeout: TimeInterval
        ) throws -> String {
            try handler(executable, arguments, workingDirectoryDescriptor)
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

        // The project references one generated package and links one of its products per target.
        let installed = try project(directory)
        XCTAssertEqual(installed.project.strings("packageReferences"), [])
        XCTAssertEqual(localPackages(installed), ["SwiftPods/SwiftPodsDependencies"])
        XCTAssertEqual(products(installed, "App"), ["SwiftPods-App"])
        XCTAssertEqual(linked(installed, "App"), ["SwiftPods-App"])
        XCTAssertNil(installed[target(installed, "App").strings("packageProductDependencies")[0]]?["package"], "Local products name no package")
        XCTAssertEqual(phaseNames(installed, "App"), ["[SwiftPods] Prepare", "PBXSourcesBuildPhase", "PBXFrameworksBuildPhase", "[SwiftPods] Finish"])
        XCTAssertEqual(products(installed, "AppTests"), ["SwiftPods-AppTests"])
        XCTAssertEqual(products(installed, "Plugin"), ["SwiftPods-Plugin", "SwiftPods-Plugin-Unlinked"])
        XCTAssertEqual(linked(installed, "Plugin"), ["SwiftPods-Plugin"], "link: false adds a build dependency only")

        // The generated package carries the requirements and products.
        let manifest = try generated(directory, "SwiftPodsDependencies/Package.swift")
        XCTAssertTrue(manifest.contains(#"platforms: [.iOS("15.0")]"#), manifest)
        XCTAssertTrue(manifest.contains(#".package(url: "https://github.com/firebase/firebase-ios-sdk.git", from: "13.0.0")"#), manifest)
        XCTAssertTrue(manifest.contains(#".package(url: "https://github.com/pointfreeco/swift-snapshot-testing.git", exact: "1.18.0")"#), manifest)
        XCTAssertTrue(manifest.contains(#".package(path: "../../Modules/Networking")"#), manifest)
        XCTAssertTrue(manifest.contains(#".product(name: "FirebaseAnalytics", package: "firebase-ios-sdk")"#), manifest)
        XCTAssertTrue(manifest.contains(#".product(name: "Networking", package: "networking")"#), manifest)
        XCTAssertTrue(manifest.contains(#".library(name: "SwiftPods-Plugin-Unlinked", targets: ["SwiftPods_Plugin_Unlinked"])"#), manifest)

        // Script phases run generated scripts; groups' scripts come first.
        let prepare = try generated(directory, "Scripts/App/App/prepare.sh")
        XCTAssertTrue(prepare.contains("/usr/bin/shasum -a 256 --check --strict --status"), prepare)
        XCTAssertTrue(prepare.contains(#"'/bin/sh' "${SRCROOT}/"'SwiftPods/Scripts/App/App/2.sh'"#), prepare)
        XCTAssertEqual(try generated(directory, "Scripts/App/App/2.sh"), "gen\n")
        XCTAssertTrue(try generated(directory, "Scripts/App/App/finish.sh").contains("/App/App/1.sh"))
        XCTAssertTrue(try generated(directory, "Scripts/Podfile.sha256").hasSuffix("  Podfile\n"))

        let settings = directory.appendingPathComponent("SwiftPods/Settings/App/App.xcconfig")
        XCTAssertEqual(try String(contentsOf: settings, encoding: .utf8), "// Generated by SwiftPods from the Podfile. Do not edit.\nOTHER_LDFLAGS = $(inherited) -ObjC\n")
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

    func testChangingThePodfileLeavesTheProjectAlone() throws {
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
        XCTAssertEqual(report.projects[0].changes, [])
        XCTAssertEqual(try String(contentsOf: try project(directory).file, encoding: .utf8), text)

        let manifest = try generated(directory, "SwiftPodsDependencies/Package.swift")
        XCTAssertTrue(manifest.contains(#"exact: "13.1.0""#) && manifest.contains("dd-sdk-ios") && manifest.contains(#"from: "5.10.0""#), manifest)
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
        let current = try String(contentsOf: try project(directory).file, encoding: .utf8)

        // What SwiftPods 0.2 kept in the project, under identifiers derived from what the objects describe.
        var old = try project(directory)
        let app = old.nativeTargets.first { $0.name == "App" }!.id
        let remote = "package:" + PackageLocation.canonical("https://github.com/firebase/firebase-ios-sdk.git")
        let local = "package:local:Modules/Networking"
        old[XcodeProject.identifier(remote)] = [
            "isa": "XCRemoteSwiftPackageReference", "repositoryURL": "https://github.com/firebase/firebase-ios-sdk.git",
            "requirement": ["kind": "upToNextMajorVersion", "minimumVersion": "13.0.0"],
        ]
        old[XcodeProject.identifier(local)] = ["isa": "XCLocalSwiftPackageReference", "relativePath": "Modules/Networking"]
        for key in [remote, local] { old.append(XcodeProject.identifier(key), to: "packageReferences", of: old.rootID) }
        for (key, product) in [(remote, "FirebaseCore"), (local, "Networking")] {
            let dependency = XcodeProject.identifier(ProjectIntegration.productKey(target: "App", package: key, product: product))
            old[dependency] = ["isa": "XCSwiftPackageProductDependency", "package": .string(XcodeProject.identifier(key)), "productName": .string(product)]
            old.append(dependency, to: "packageProductDependencies", of: app)
            let file = XcodeProject.identifier("build-file:" + dependency)
            old[file] = ["isa": "PBXBuildFile", "productRef": .string(dependency)]
            old.append(file, to: "files", of: "A30000000000000000000001")
        }
        let script = XcodeProject.identifier(ProjectIntegration.scriptKey(target: "App", name: "Upload"))
        old[script] = [
            "isa": "PBXShellScriptBuildPhase", "buildActionMask": "2147483647", "files": [], "name": "[SwiftPods] Upload",
            "runOnlyForDeploymentPostprocessing": "0", "shellPath": "/bin/sh", "shellScript": "upload",
        ]
        old.append(script, to: "buildPhases", of: app)
        try old.save()

        let changes = try installer(directory).install(InstallOptions()).projects[0].changes.map(\.description)
        XCTAssertTrue(changes.contains("Removed package https://github.com/firebase/firebase-ios-sdk.git"), "\(changes)")
        XCTAssertTrue(changes.contains("Removed local package Modules/Networking"), "\(changes)")
        XCTAssertTrue(changes.contains("Removed product FirebaseCore in App"), "\(changes)")
        XCTAssertTrue(changes.contains { $0.contains("script phase [SwiftPods] Upload") }, "\(changes)")
        XCTAssertEqual(try String(contentsOf: try project(directory).file, encoding: .utf8), current)
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
        XCTAssertEqual(urls, ["https://github.com/user/Own.git"])
        XCTAssertEqual(products(after, "App"), ["SwiftPods-App"])
        XCTAssertEqual(report.projects[0].changes, [])
        let manifest = try generated(directory, "SwiftPodsDependencies/Package.swift")
        XCTAssertTrue(manifest.contains(#"exact: "1.1.0""#) && !manifest.contains("Extra"), manifest)
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
        XCTAssertEqual(after.project.strings("packageReferences"), [])
        XCTAssertEqual(products(after, "App"), ["SwiftPods-App"])
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
        XCTAssertEqual(localPackages(installed), ["SwiftPods/SwiftPodsDependencies"])
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
    }

    func testInstallReadsLocalBinaryThroughLockedWorkspaceAfterPathRebind() throws {
        let podfile = "target 'App' do\n  binary 'Kit', path: 'Vendor/Kit.xcframework'\nend\n"
        let directory = try fixture(podfile)
        let decoy = try fixture(podfile)
        let trusted = directory.appendingPathComponent("Vendor/Kit.xcframework", isDirectory: true)
        let replacement = decoy.appendingPathComponent("Vendor/Kit.xcframework", isDirectory: true)
        try makeXCFramework(trusted)
        try makeXCFramework(replacement)
        try "trusted".write(
            to: trusted.appendingPathComponent("payload.txt"), atomically: true, encoding: .utf8)
        try "decoy".write(
            to: replacement.appendingPathComponent("payload.txt"), atomically: true, encoding: .utf8)

        let raced = Installer(
            directory: directory, cache: directory.appendingPathComponent(".cache"),
            generatedMutationHook: { point in
                switch point {
                case .beforeBinaryRead("Kit"), .afterBinaryRead("Kit"):
                    precondition(renameatx_np(
                        AT_FDCWD, directory.path, AT_FDCWD, decoy.path, UInt32(RENAME_SWAP)) == 0)
                default: break
                }
            })
        _ = try raced.install(.init())

        XCTAssertEqual(
            try String(
                contentsOf: directory.appendingPathComponent(
                    "SwiftPods/SwiftPodsBinaries/Artifacts/Kit/Kit.xcframework/payload.txt"),
                encoding: .utf8),
            "trusted")
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
        XCTAssertNil(installed[installed.configurations(of: installed.nativeTargets[0].id)["Debug"]!]?.string("baseConfigurationReference"))
        XCTAssertTrue(try generated(directory, "Scripts/App/App/finish.sh").contains(TargetScripts.embedFrameworks))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("SwiftPods/Scripts/App/App/prepare.sh").path))
        XCTAssertFalse(try generated(directory, "Scripts/App/Plugin/finish.sh").contains(TargetScripts.embedFrameworks))
        let text = try String(contentsOf: installed.file, encoding: .utf8)

        try "target 'Plugin' do\n  spm 'https://github.com/Alamofire/Alamofire.git', '~> 5.10'\n  binary 'Ads', path: 'Vendor/Ads.xcframework'\nend\n"
            .write(to: directory.appendingPathComponent("Podfile"), atomically: true, encoding: .utf8)
        try makeXCFramework(directory.appendingPathComponent("Vendor/Ads.xcframework"))
        XCTAssertEqual(try installer(directory).install(InstallOptions()).projects[0].changes, [])
        XCTAssertEqual(try String(contentsOf: installed.file, encoding: .utf8), text)

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
        XCTAssertEqual(products(installed, "App"), ["SwiftPods-App"])
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
        let workspaceAttributeName = "com.swiftpods.tests.metadata"
        let workspaceAttribute = Data("preserve-me".utf8)
        XCTAssertEqual(workspaceAttribute.withUnsafeBytes {
            setxattr(workspaceContents.path, workspaceAttributeName, $0.baseAddress, $0.count, 0, 0)
        }, 0)
        _ = try ProcessRunner().run(
            "/bin/chmod", ["+a", "everyone allow read", workspaceContents.path], in: directory)
        let originalWorkspaceDescriptor = open(
            workspaceContents.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(originalWorkspaceDescriptor, 0)
        let originalWorkspaceMetadata = try FileSecurityMetadata(descriptor: originalWorkspaceDescriptor)
        close(originalWorkspaceDescriptor)
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
        XCTAssertEqual(workspaceStatus.st_flags, originalWorkspaceStatus.st_flags)
        let workspaceAttributeSize = getxattr(
            workspaceContents.path, workspaceAttributeName, nil, 0, 0, 0)
        XCTAssertEqual(workspaceAttributeSize, workspaceAttribute.count)
        var restoredWorkspaceAttribute = Data(count: max(0, workspaceAttributeSize))
        let restoredWorkspaceAttributeSize = restoredWorkspaceAttribute.withUnsafeMutableBytes {
            getxattr(workspaceContents.path, workspaceAttributeName, $0.baseAddress, $0.count, 0, 0)
        }
        XCTAssertEqual(restoredWorkspaceAttributeSize, workspaceAttribute.count)
        XCTAssertEqual(restoredWorkspaceAttribute, workspaceAttribute)
        let restoredWorkspaceDescriptor = open(
            workspaceContents.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(restoredWorkspaceDescriptor, 0)
        let restoredWorkspaceMetadata = try FileSecurityMetadata(descriptor: restoredWorkspaceDescriptor)
        close(restoredWorkspaceDescriptor)
        XCTAssertEqual(restoredWorkspaceMetadata, originalWorkspaceMetadata)
    }

    func testCocoaPodsWorkspaceReaderRejectsSpecialFilesWithoutBlocking() throws {
        let directory = try fixture("target 'App' do\nend\n")
        let workspace = directory.appendingPathComponent("App.xcworkspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let contents = workspace.appendingPathComponent("contents.xcworkspacedata")
        XCTAssertEqual(contents.path.withCString { mkfifo($0, S_IRUSR | S_IWUSR) }, 0)

        XCTAssertThrowsError(try installer(directory).deintegrate(cocoapods: true)) {
            XCTAssertTrue("\($0)".contains("regular file"), "\($0)")
        }
    }

    func testCocoaPodsWorkspaceDirectorySymlinkCannotRedirectAWrite() throws {
        let directory = try fixture("target 'App' do\nend\n")
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftpods-outside-workspace-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let contents = outside.appendingPathComponent("contents.xcworkspacedata")
        let original = "<Workspace><FileRef location=\"group:Pods/Pods.xcodeproj\"></FileRef>\n</Workspace>\n"
        try original.write(to: contents, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("App.xcworkspace"), withDestinationURL: outside)

        XCTAssertThrowsError(try installer(directory).deintegrate(cocoapods: true)) {
            XCTAssertTrue("\($0)".contains("workspace directory"), "\($0)")
        }
        XCTAssertEqual(try String(contentsOf: contents, encoding: .utf8), original)
    }

    func testCocoaPodsWorkspaceAncestorSymlinkRaceRollsBackTheAnchoredWorkspace() throws {
        let directory = try fixture("target 'App' do\nend\n")
        let container = directory.appendingPathComponent("Container", isDirectory: true)
        let movedContainer = directory.appendingPathComponent("Container-original", isDirectory: true)
        let workspace = container.appendingPathComponent("App.xcworkspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let contents = workspace.appendingPathComponent("contents.xcworkspacedata")
        let original = "<Workspace><FileRef location=\"group:Pods/Pods.xcodeproj\"></FileRef>\n</Workspace>\n"
        try original.write(to: contents, atomically: true, encoding: .utf8)

        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftpods-workspace-ancestor-race-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        let outsideWorkspace = outside.appendingPathComponent("App.xcworkspace", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideWorkspace, withIntermediateDirectories: true)
        let outsideContents = outsideWorkspace.appendingPathComponent("contents.xcworkspacedata")
        let outsideData = "<Workspace><FileRef location=\"group:Outside.xcodeproj\"></FileRef>\n</Workspace>\n"
        try outsideData.write(to: outsideContents, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try CocoaPodsIntegration.removePodsProject(fromWorkspace: workspace) {
            try! FileManager.default.moveItem(at: container, to: movedContainer)
            try! FileManager.default.createSymbolicLink(at: container, withDestinationURL: outside)
        }) { error in
            XCTAssertTrue("\(error)".contains("directory changed"), "\(error)")
        }
        XCTAssertEqual(
            try String(
                contentsOf: movedContainer.appendingPathComponent("App.xcworkspace/contents.xcworkspacedata"),
                encoding: .utf8),
            original)
        XCTAssertEqual(try String(contentsOf: outsideContents, encoding: .utf8), outsideData)
    }

    func testCocoaPodsWorkspaceRelativeAnchorRejectsAReplacedAncestor() throws {
        let directory = try fixture("target 'App' do\nend\n")
        let container = directory.appendingPathComponent("Container", isDirectory: true)
        let movedContainer = directory.appendingPathComponent("Container-original", isDirectory: true)
        let workspace = container.appendingPathComponent("App.xcworkspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let contents = workspace.appendingPathComponent("contents.xcworkspacedata")
        let original = "<Workspace><FileRef location=\"group:Pods/Pods.xcodeproj\"></FileRef>\n</Workspace>\n"
        try original.write(to: contents, atomically: true, encoding: .utf8)

        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftpods-relative-workspace-race-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        let outsideWorkspace = outside.appendingPathComponent("App.xcworkspace", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideWorkspace, withIntermediateDirectories: true)
        let outsideContents = outsideWorkspace.appendingPathComponent("contents.xcworkspacedata")
        let outsideData = "<Workspace><FileRef location=\"group:Outside.xcodeproj\"></FileRef>\n</Workspace>\n"
        try outsideData.write(to: outsideContents, atomically: true, encoding: .utf8)

        let root = directory.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        XCTAssertGreaterThanOrEqual(root, 0)
        defer { close(root) }
        XCTAssertThrowsError(
            try CocoaPodsIntegration.removePodsProjectRecoverably(
                fromWorkspace: workspace, relativeToWorkspaceRoot: root,
                relativeWorkspacePath: "Container/App.xcworkspace",
                beforeAtomicReplacement: {
                    try! FileManager.default.moveItem(at: container, to: movedContainer)
                    try! FileManager.default.createSymbolicLink(at: container, withDestinationURL: outside)
                })
        ) { error in
            XCTAssertTrue("\(error)".contains("directory changed"), "\(error)")
        }
        XCTAssertEqual(
            try String(
                contentsOf: movedContainer.appendingPathComponent("App.xcworkspace/contents.xcworkspacedata"),
                encoding: .utf8),
            original)
        XCTAssertEqual(try String(contentsOf: outsideContents, encoding: .utf8), outsideData)
    }

    func testCocoaPodsWorkspaceWriterRollsBackAChangeAfterFinalValidation() throws {
        let directory = try fixture("target 'App' do\nend\n")
        let workspace = directory.appendingPathComponent("App.xcworkspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let contents = workspace.appendingPathComponent("contents.xcworkspacedata")
        let original = "<Workspace><FileRef location=\"group:Pods/Pods.xcodeproj\"></FileRef>\n</Workspace>\n"
        try original.write(to: contents, atomically: true, encoding: .utf8)
        let external = "<Workspace><FileRef location=\"group:Concurrent.xcodeproj\"></FileRef>\n</Workspace>\n"

        XCTAssertThrowsError(try CocoaPodsIntegration.removePodsProject(fromWorkspace: workspace) {
            try! external.write(to: contents, atomically: true, encoding: .utf8)
        }) { error in
            XCTAssertTrue("\(error)".contains("atomic replacement"), "\(error)")
        }
        XCTAssertEqual(try String(contentsOf: contents, encoding: .utf8), external)
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: workspace.path)
                .contains(where: { $0.hasPrefix(".contents.xcworkspacedata.swiftpods-") }))
    }

    func testDeintegrateRollsBackProjectsWorkspaceAndGeneratedTreesOnLateFailure() throws {
        let directory = try fixture(
            "target 'App' do\n  settings 'SWIFT_VERSION' => '5.10'\nend\n")
        _ = try installer(directory).install(.init())
        let appProject = directory.appendingPathComponent("App.xcodeproj", isDirectory: true)
        let otherProject = directory.appendingPathComponent("Other.xcodeproj", isDirectory: true)
        try FileManager.default.copyItem(at: appProject, to: otherProject)
        let appFile = appProject.appendingPathComponent("project.pbxproj")
        let otherFile = otherProject.appendingPathComponent("project.pbxproj")
        let originalApp = try Data(contentsOf: appFile)
        let originalOther = try String(contentsOf: otherFile, encoding: .utf8)
        let concurrentOther = originalOther.replacingOccurrences(
            of: "archiveVersion = 1;", with: "archiveVersion = 2;")

        let workspace = directory.appendingPathComponent("App.xcworkspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let workspaceFile = workspace.appendingPathComponent("contents.xcworkspacedata")
        let originalWorkspace =
            "<Workspace><FileRef location=\"group:Pods/Pods.xcodeproj\"></FileRef>\n</Workspace>\n"
        try originalWorkspace.write(to: workspaceFile, atomically: true, encoding: .utf8)
        let generatedSettings = directory.appendingPathComponent("SwiftPods/Settings/App/App.xcconfig")
        let originalGenerated = try Data(contentsOf: generatedSettings)

        let raced = Installer(
            directory: directory, cache: directory.appendingPathComponent(".cache"),
            generatedMutationHook: { point in
                guard point == .afterDeintegratedProjectSave("App.xcodeproj") else { return }
                try! concurrentOther.write(to: otherFile, atomically: true, encoding: .utf8)
            })
        XCTAssertThrowsError(try raced.deintegrate(cocoapods: true)) { error in
            XCTAssertTrue("\(error)".contains("changed since SwiftPods read it"), "\(error)")
        }

        XCTAssertEqual(try Data(contentsOf: appFile), originalApp)
        XCTAssertEqual(try String(contentsOf: otherFile, encoding: .utf8), concurrentOther)
        XCTAssertEqual(try String(contentsOf: workspaceFile, encoding: .utf8), originalWorkspace)
        XCTAssertEqual(try Data(contentsOf: generatedSettings), originalGenerated)
    }

    func testDeintegrateAuthenticatesManifestBeforeMutationAndCommit() throws {
        for racePoint in [
            Installer.GeneratedMutationPoint.beforeDeintegrationMutation,
            .beforeDeintegrationCommit,
        ] {
            let directory = try fixture(
                "target 'App' do\n  settings 'SWIFT_VERSION' => '5.10'\nend\n")
            _ = try installer(directory).install(.init())
            let podfile = directory.appendingPathComponent("Podfile")
            let projectFile = directory.appendingPathComponent("App.xcodeproj/project.pbxproj")
            let generatedSettings = directory.appendingPathComponent("SwiftPods/Settings/App/App.xcconfig")
            let originalProject = try Data(contentsOf: projectFile)
            let originalGenerated = try Data(contentsOf: generatedSettings)
            let raced = Installer(
                directory: directory, cache: directory.appendingPathComponent(".cache"),
                generatedMutationHook: { point in
                    guard point == racePoint else { return }
                    try! "target 'Other' do\nend\n".write(
                        to: podfile, atomically: true, encoding: .utf8)
                })

            XCTAssertThrowsError(try raced.deintegrate()) { error in
                XCTAssertTrue("\(error)".contains("changed after the manifest was read"), "\(error)")
            }
            XCTAssertEqual(try Data(contentsOf: projectFile), originalProject)
            XCTAssertEqual(try Data(contentsOf: generatedSettings), originalGenerated)
        }
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
            let manifest = try generated(directory, "SwiftPodsDependencies/Package.swift")
            return ["https://github.com/a/Kit.git", "https://github.com/b/Kit.git"].filter(manifest.contains)
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

    func testExplicitOnlyInstallNeverInspectsUnsafeIrrelevantSwiftPodsLock() throws {
        let directory = try fixture("target 'App' do\nend\n")
        let lock = directory.appendingPathComponent(SwiftPodsLock.fileName)

        XCTAssertEqual(lock.path.withCString { mkfifo($0, 0o600) }, 0)
        _ = try installer(directory).install(.init())
        var status = stat()
        XCTAssertEqual(lstat(lock.path, &status), 0)
        XCTAssertEqual(status.st_mode & S_IFMT, S_IFIFO)
        XCTAssertEqual(lock.path.withCString { unlink($0) }, 0)

        let target = directory.appendingPathComponent("unrelated-lock-target")
        try Data("do not read\n".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: lock, withDestinationURL: target)
        _ = try installer(directory).install(.init())
        XCTAssertEqual(lstat(lock.path, &status), 0)
        XCTAssertEqual(status.st_mode & S_IFMT, S_IFLNK)
        try FileManager.default.removeItem(at: lock)

        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)
        _ = try installer(directory).install(.init())
        XCTAssertEqual(lstat(lock.path, &status), 0)
        XCTAssertEqual(status.st_mode & S_IFMT, S_IFDIR)
        try FileManager.default.removeItem(at: lock)

        XCTAssertTrue(FileManager.default.createFile(atPath: lock.path, contents: Data()))
        let handle = try FileHandle(forWritingTo: lock)
        try handle.truncate(atOffset: UInt64(16 * 1_024 * 1_024 + 1))
        try handle.close()
        _ = try installer(directory).install(.init())
        XCTAssertEqual(lstat(lock.path, &status), 0)
        XCTAssertEqual(status.st_size, 16 * 1_024 * 1_024 + 1)
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

    func testDeploymentRejectsAConcurrentSwiftPodsLockChange() throws {
        let directory = try fixture("")
        let shell = ProcessRunner()
        let catalog = directory.appendingPathComponent("catalog", isDirectory: true)
        try FileManager.default.createDirectory(
            at: catalog.appendingPathComponent("Packages", isDirectory: true), withIntermediateDirectories: true)
        try "package 'Kit', git: 'https://github.com/example/Kit.git', products: ['Kit']\n"
            .write(to: catalog.appendingPathComponent("Packages/Kit.podfile"), atomically: true, encoding: .utf8)
        _ = try shell.run("/usr/bin/git", ["init", "-q"], in: catalog)
        _ = try shell.run("/usr/bin/git", ["add", "-A"], in: catalog)
        _ = try shell.run(
            "/usr/bin/git", ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "Kit"],
            in: catalog)
        try "source '\(catalog.path)'\ntarget 'App' do\n  spm 'Kit', exact: '1.0.0'\nend\n"
            .write(to: directory.appendingPathComponent("Podfile"), atomically: true, encoding: .utf8)
        let cache = directory.appendingPathComponent(".cache")
        let sources = directory.appendingPathComponent(".sources")
        let forwardingRunner = RecordingRunner { executable, arguments, workingDirectory in
            if executable == "/usr/bin/xcrun" { return "" }
            return try shell.run(executable, arguments, in: workingDirectory)
        }
        _ = try Installer(directory: directory, runner: forwardingRunner, cache: cache, sourcesCache: sources)
            .install(.init())

        let lock = directory.appendingPathComponent(SwiftPodsLock.fileName)
        let originalLock = try String(contentsOf: lock, encoding: .utf8)
        let resolved = directory.appendingPathComponent(
            "App.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
        try FileManager.default.createDirectory(at: resolved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"pins":[{"identity":"kit","kind":"remoteSourceControl","location":"https://github.com/example/Kit.git","state":{"revision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","version":"1.0.0"}}],"version":3}"#
            .write(to: resolved, atomically: true, encoding: .utf8)
        let concurrentLock = originalLock + " "
        let mutatingRunner = RecordingRunner { executable, arguments, workingDirectory in
            if executable == "/usr/bin/xcrun" {
                try concurrentLock.write(to: lock, atomically: true, encoding: .utf8)
                return ""
            }
            return try shell.run(executable, arguments, in: workingDirectory)
        }
        var options = InstallOptions()
        options.deployment = true

        XCTAssertThrowsError(
            try Installer(directory: directory, runner: mutatingRunner, cache: cache, sourcesCache: sources)
                .install(options)
        ) { error in
            XCTAssertTrue("\(error)".contains("SwiftPods.lock changed after it was read"), "\(error)")
        }
        XCTAssertEqual(try String(contentsOf: lock, encoding: .utf8), concurrentLock)
    }

    func testDeintegratePreservesUnknownGeneratedEntries() throws {
        let directory = try fixture("target 'App' do\nend\n")
        _ = try installer(directory).install(.init())
        let root = directory.appendingPathComponent("SwiftPods", isDirectory: true)
        let unknown = root.appendingPathComponent("Keep.txt")
        let unknownDirectory = root.appendingPathComponent("UserData", isDirectory: true)
        let stagingPrefix = root.appendingPathComponent(".staging-not-swiftpods", isDirectory: true)
        let unmarkedStaging = root.appendingPathComponent(
            ".staging-00000000-0000-0000-0000-000000000000", isDirectory: true)
        try "keep\n".write(to: unknown, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: unknownDirectory, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: stagingPrefix, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: unmarkedStaging, withIntermediateDirectories: false)
        try "nested\n".write(
            to: unknownDirectory.appendingPathComponent("value.txt"), atomically: true, encoding: .utf8)

        _ = try installer(directory).deintegrate()

        XCTAssertEqual(try String(contentsOf: unknown, encoding: .utf8), "keep\n")
        XCTAssertEqual(
            try String(contentsOf: unknownDirectory.appendingPathComponent("value.txt"), encoding: .utf8), "nested\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagingPrefix.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unmarkedStaging.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Scripts").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("SwiftPodsDependencies").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".swiftpods-owned").path))
    }

    func testRemoteBinariesAreVerifiedAndCached() throws {
        let directory = try fixture("target 'App' do\nend\n")
        let source = directory.appendingPathComponent("archive-source")
        try makeXCFramework(source.appendingPathComponent("SDK/Remote.xcframework"))
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

    func testResolveValidationFailureRollsBackCreatedPathAndProjectMetadata() throws {
        let directory = try fixture(
            "target 'App' do\n  spm 'https://github.com/a/Kit.git', exact: '1.0.0'\nend\n")
        let projectFile = directory.appendingPathComponent("App.xcodeproj/project.pbxproj")
        let originalProject = try Data(contentsOf: projectFile)
        XCTAssertEqual(chmod(projectFile.path, 0o640), 0)
        let attributeName = "com.swiftpods.tests.project-rollback"
        let originalAttribute = Data("original-project-metadata".utf8)
        XCTAssertEqual(originalAttribute.withUnsafeBytes {
            setxattr(projectFile.path, attributeName, $0.baseAddress, $0.count, 0, 0)
        }, 0)
        var originalTimes = [
            timespec(tv_sec: 1_700_000_011, tv_nsec: 123_456_789),
            timespec(tv_sec: 1_700_000_012, tv_nsec: 987_654_321),
        ]
        XCTAssertEqual(utimensat(AT_FDCWD, projectFile.path, &originalTimes, 0), 0)
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
        XCTAssertEqual(restoredStatus.st_mtimespec.tv_sec, originalStatus.st_mtimespec.tv_sec)
        XCTAssertEqual(restoredStatus.st_mtimespec.tv_nsec, originalStatus.st_mtimespec.tv_nsec)
        var restoredAttribute = Data(count: originalAttribute.count)
        let restoredAttributeCount = restoredAttribute.withUnsafeMutableBytes {
            getxattr(projectFile.path, attributeName, $0.baseAddress, $0.count, 0, 0)
        }
        XCTAssertEqual(restoredAttributeCount, originalAttribute.count)
        XCTAssertEqual(restoredAttribute, originalAttribute)
    }

    func testProjectTransactionSnapshotsCannotBePoisonedByTemporaryProjectPathRebind() throws {
        let directory = try fixture("target 'App' do\n  settings 'SWIFT_VERSION' => '5.10'\nend\n")
        let project = directory.appendingPathComponent("App.xcodeproj", isDirectory: true)
        let retained = directory.appendingPathComponent(".trusted-project", isDirectory: true)
        let decoy = directory.appendingPathComponent(".decoy-project", isDirectory: true)
        let displacedDecoy = directory.appendingPathComponent(".displaced-decoy", isDirectory: true)
        try FileManager.default.copyItem(at: project, to: decoy)
        let decoyFile = decoy.appendingPathComponent("project.pbxproj")
        let attackerMarker = "// attacker-controlled rollback source\n"
        let decoyBytes = attackerMarker + (try String(contentsOf: decoyFile, encoding: .utf8))
        try decoyBytes.write(to: decoyFile, atomically: false, encoding: .utf8)

        let raced = Installer(
            directory: directory, cache: directory.appendingPathComponent(".cache"),
            generatedMutationHook: { point in
                switch point {
                case .beforeProjectTransactionSnapshot("App.xcodeproj"):
                    precondition(rename(project.path, retained.path) == 0)
                    precondition(rename(decoy.path, project.path) == 0)
                case .beforeProjectSave("App.xcodeproj"):
                    precondition(rename(project.path, displacedDecoy.path) == 0)
                    precondition(rename(retained.path, project.path) == 0)
                default:
                    break
                }
            })

        _ = try raced.install(.init())

        let installed = try String(
            contentsOf: project.appendingPathComponent("project.pbxproj"), encoding: .utf8)
        XCTAssertFalse(installed.contains(attackerMarker), installed)
        _ = try XcodeProject(path: project)
        XCTAssertTrue(try String(
            contentsOf: displacedDecoy.appendingPathComponent("project.pbxproj"), encoding: .utf8
        ).contains(attackerMarker))
    }

    func testResolveRunsAgainstRetainedProjectDescriptorDuringPathRebind() throws {
        let directory = try fixture(
            "target 'App' do\n  spm 'https://github.com/a/Kit.git', exact: '1.0.0'\nend\n")
        let project = directory.appendingPathComponent("App.xcodeproj", isDirectory: true)
        let movedProject = directory.appendingPathComponent(".moved-project", isDirectory: true)
        let decoy = directory.appendingPathComponent(".resolver-decoy", isDirectory: true)
        let displacedDecoy = directory.appendingPathComponent(".resolver-displaced-decoy", isDirectory: true)
        try FileManager.default.copyItem(at: project, to: decoy)

        let runner = DescriptorRunner { executable, arguments, descriptor in
            XCTAssertEqual(executable, "/usr/bin/xcrun")
            XCTAssertEqual(Array(arguments.suffix(2)), ["-project", "."])
            precondition(rename(project.path, movedProject.path) == 0)
            precondition(rename(decoy.path, project.path) == 0)

            var anchored = stat()
            var moved = stat()
            var replacement = stat()
            XCTAssertEqual(fstat(descriptor, &anchored), 0)
            XCTAssertEqual(lstat(movedProject.path, &moved), 0)
            XCTAssertEqual(lstat(project.path, &replacement), 0)
            XCTAssertEqual(anchored.st_dev, moved.st_dev)
            XCTAssertEqual(anchored.st_ino, moved.st_ino)
            XCTAssertNotEqual(anchored.st_ino, replacement.st_ino)

            let resolved = PackageResolved.location(project: movedProject)
            try FileManager.default.createDirectory(
                at: resolved.deletingLastPathComponent(), withIntermediateDirectories: true)
            let bytes = Data(#"{"pins":[{"identity":"kit","kind":"remoteSourceControl","location":"https://github.com/a/Kit.git","state":{"revision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","version":"1.0.0"}}],"version":3}"#.utf8)
            try bytes.write(to: resolved)

            precondition(rename(project.path, displacedDecoy.path) == 0)
            precondition(rename(movedProject.path, project.path) == 0)
            return ""
        }
        var options = InstallOptions()
        options.resolve = true
        _ = try Installer(
            directory: directory, runner: runner,
            cache: directory.appendingPathComponent(".cache")
        ).install(options)

        let resolved = try PackageResolved.snapshot(project: project)
        XCTAssertNotNil(resolved.data)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: PackageResolved.location(project: displacedDecoy).path))
    }

    func testResolveRejectsAPathOnlyCommandRunner() throws {
        struct PathOnlyRunner: CommandRunner {
            func run(_ executable: String, _ arguments: [String], in directory: URL?) throws -> String { "" }
        }
        let directory = try fixture(
            "target 'App' do\n  spm 'https://github.com/a/Kit.git', exact: '1.0.0'\nend\n")
        let projectFile = directory.appendingPathComponent("App.xcodeproj/project.pbxproj")
        let original = try Data(contentsOf: projectFile)
        var options = InstallOptions()
        options.resolve = true

        XCTAssertThrowsError(try Installer(
            directory: directory, runner: PathOnlyRunner(),
            cache: directory.appendingPathComponent(".cache")
        ).install(options)) { error in
            XCTAssertTrue("\(error)".contains("authenticated project directory"), "\(error)")
        }
        XCTAssertEqual(try Data(contentsOf: projectFile), original)
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
        XCTAssertTrue(try String(contentsOf: fixture.package.appendingPathComponent("Package.swift"), encoding: .utf8).contains("2.0.0"))
        _ = try installer.deintegrate()
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

    func testResolveMetadataDoesNotAuthorizeManagedPayloadChanges() throws {
        let fixture = try resolverMetadataFixture()
        let manifest = fixture.package.appendingPathComponent("Package.swift")
        let tampered = Data("concurrent managed edit".utf8)
        let runner = RecordingRunner { _, _, _ in
            try self.createResolverMetadata(in: fixture.package)
            try tampered.write(to: manifest)
            return ""
        }
        var options = InstallOptions()
        options.resolve = true
        XCTAssertThrowsError(try Installer(directory: fixture.directory, runner: runner).install(options)) { error in
            XCTAssertTrue("\(error)".contains("Resolver changed managed generated package contents"), "\(error)")
        }
        XCTAssertEqual(try Data(contentsOf: manifest), tampered)
    }

    func testResolveRejectsSymlinkMetadataRootWithoutTouchingItsTarget() throws {
        let fixture = try resolverMetadataFixture()
        let outside = fixture.directory.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let sentinel = outside.appendingPathComponent("keep")
        try Data("keep".utf8).write(to: sentinel)
        let runner = RecordingRunner { _, _, _ in
            try FileManager.default.createSymbolicLink(at: fixture.package.appendingPathComponent(".swiftpm"), withDestinationURL: outside)
            return ""
        }
        var options = InstallOptions()
        options.resolve = true
        XCTAssertThrowsError(try Installer(directory: fixture.directory, runner: runner).install(options))
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
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
                at: resolved.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(#"{"pins":[],"version":3}"#.utf8).write(to: resolved)
            throw SwiftPodsError("resolver failed after creating Package.resolved")
        }
        var options = InstallOptions()
        options.resolve = true
        XCTAssertThrowsError(try Installer(
            directory: directory, runner: runner, cache: directory.appendingPathComponent(".cache")
        ).install(options)) { error in
            XCTAssertTrue("\(error)".contains("resolver failed after creating"), "\(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: projectURL.appendingPathComponent("project.xcworkspace").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("SwiftPods").path))
        XCTAssertEqual(try Data(contentsOf: projectFile), originalProject)
    }

    func testProjectRollbackRefusesConcurrentMetadataOnlyEdit() throws {
        let directory = try fixture(
            "target 'App' do\n  spm 'https://github.com/a/Kit.git', exact: '1.0.0'\nend\n")
        let projectFile = directory.appendingPathComponent("App.xcodeproj/project.pbxproj")
        let attributeName = "com.swiftpods.tests.concurrent-project-metadata"
        let concurrentAttribute = Data("keep-concurrent-metadata".utf8)
        let runner = RecordingRunner { _, _, _ in
            let result = concurrentAttribute.withUnsafeBytes {
                setxattr(projectFile.path, attributeName, $0.baseAddress, $0.count, 0, 0)
            }
            XCTAssertEqual(result, 0)
            throw SwiftPodsError("resolver failed after concurrent metadata edit")
        }
        var options = InstallOptions()
        options.resolve = true
        XCTAssertThrowsError(try Installer(
            directory: directory, runner: runner, cache: directory.appendingPathComponent(".cache")
        ).install(options)) { error in
            XCTAssertTrue("\(error)".contains("rollback was incomplete"), "\(error)")
            XCTAssertTrue("\(error)".contains("concurrent edit"), "\(error)")
        }
        var preservedAttribute = Data(count: concurrentAttribute.count)
        let preservedAttributeCount = preservedAttribute.withUnsafeMutableBytes {
            getxattr(projectFile.path, attributeName, $0.baseAddress, $0.count, 0, 0)
        }
        XCTAssertEqual(preservedAttributeCount, concurrentAttribute.count)
        XCTAssertEqual(preservedAttribute, concurrentAttribute)
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
        XCTAssertNil(invocation.directory)
        XCTAssertEqual(Array(invocation.arguments.suffix(2)), ["-project", "."])
        XCTAssertTrue(invocation.arguments.contains("-resolvePackageDependencies"), "\(invocation.arguments)")
        XCTAssertTrue(invocation.arguments.contains("-disableAutomaticPackageResolution"), "\(invocation.arguments)")
        XCTAssertTrue(invocation.arguments.contains("-onlyUsePackageVersionsFromResolvedFile"), "\(invocation.arguments)")
        XCTAssertTrue(invocation.arguments.contains("-skipPackageUpdates"), "\(invocation.arguments)")
        XCTAssertEqual(try Data(contentsOf: resolved), Data(contents.utf8))
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

        // Without settings, a base configuration of the target's own need not include SwiftPods'.
        try FileManager.default.removeItem(at: config)
        try "SDKROOT = iphoneos\n".write(to: config, atomically: true, encoding: .utf8)
        try "target 'App' do\nend\n".write(to: directory.appendingPathComponent("Podfile"), atomically: true, encoding: .utf8)
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

    func testGeneratedTextInspectionHasPerFileAndAggregateBudgets() throws {
        let directory = try fixture("target 'App' do\nend\n")
        _ = try installer(directory).install(.init())
        let oversized = directory.appendingPathComponent("SwiftPods/Scripts/oversized")
        XCTAssertTrue(FileManager.default.createFile(atPath: oversized.path, contents: Data()))
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(atOffset: UInt64(8 * 1_024 * 1_024 + 1))
        try handle.close()

        XCTAssertThrowsError(try installer(directory).install(.init())) {
            XCTAssertTrue("\($0)".contains("8388608 bytes"), "\($0)")
        }
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

    func testScriptFileListChangeBeforeCommitAbortsAndRollsBack() throws {
        let directory = try fixture(
            "target 'App' do\n  script_phase name: 'Build', script: 'true', input_file_lists: ['Inputs.xcfilelist']\nend\n",
            files: ["Inputs.xcfilelist": "Sources/One.swift\n"])
        let list = directory.appendingPathComponent("Inputs.xcfilelist")
        let raced = Installer(
            directory: directory, cache: directory.appendingPathComponent(".cache"),
            generatedMutationHook: { point in
                guard point == .afterPublish("Scripts") else { return }
                try! "Sources/Two.swift\n".write(to: list, atomically: true, encoding: .utf8)
            })

        XCTAssertThrowsError(try raced.install(.init())) { error in
            XCTAssertTrue("\(error)".contains("Script file list changed after it was read"), "\(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("SwiftPods/Scripts").path))
    }

    func testManifestChangeBeforeGeneratedMutationIsRejected() throws {
        let directory = try fixture("target 'App' do\nend\n")
        let podfile = directory.appendingPathComponent("Podfile")
        let raced = Installer(
            directory: directory, cache: directory.appendingPathComponent(".cache"),
            generatedMutationHook: { point in
                guard point == .beforeGeneratedRootOpen else { return }
                try! "target 'Other' do\nend\n".write(to: podfile, atomically: true, encoding: .utf8)
            })

        XCTAssertThrowsError(try raced.install(.init())) { error in
            XCTAssertTrue("\(error)".contains("changed after the manifest was read"), "\(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("SwiftPods").path))
    }

    func testScriptFileListEntryAndExpansionBudgetsBoundWork() throws {
        let entries = String(repeating: "Sources/A.swift\n", count: 25_001)
        let oversized = try fixture(
            "target 'App' do\n  script_phase name: 'Build', script: 'true', input_file_lists: ['Inputs.xcfilelist']\nend\n",
            files: ["Inputs.xcfilelist": entries])
        XCTAssertThrowsError(try installer(oversized).install(.init())) { error in
            XCTAssertTrue("\(error)".contains("more than 25000 entries"), "\(error)")
        }

        let bounded = String(repeating: "A\n", count: 25_000)
        let references = Array(repeating: "'Inputs.xcfilelist'", count: 9).joined(separator: ", ")
        let amplified = try fixture(
            "target 'App' do\n  script_phase name: 'Build', script: 'true', input_file_lists: [\(references)]\nend\n",
            files: ["Inputs.xcfilelist": bounded])
        XCTAssertThrowsError(try installer(amplified).install(.init())) { error in
            XCTAssertTrue("\(error)".contains("Expanded script file lists exceed the install work budget"), "\(error)")
        }
    }

    func testScriptFileListPhysicalLineBudgetCountsBlankAndCommentLines() throws {
        for contents in [
            String(repeating: "\n", count: 50_001),
            String(repeating: "# comment\n", count: 50_001),
        ] {
            let directory = try fixture(
                "target 'App' do\n  script_phase name: 'Build', script: 'true', input_file_lists: ['Inputs.xcfilelist']\nend\n",
                files: ["Inputs.xcfilelist": contents])
            XCTAssertThrowsError(try installer(directory).install(.init())) { error in
                XCTAssertTrue("\(error)".contains("more than 50000 physical lines"), "\(error)")
            }
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

    func testGeneratedAndProjectSymlinksCannotRedirectWrites() throws {
        let victim = try fixture("")
        let victimProject = victim.appendingPathComponent("App.xcodeproj")
        let victimText = try String(contentsOf: victimProject.appendingPathComponent("project.pbxproj"), encoding: .utf8)

        let projectAttack = try fixture("project 'Linked.xcodeproj'\ntarget 'App' do\nend\n")
        try FileManager.default.createSymbolicLink(
            at: projectAttack.appendingPathComponent("Linked.xcodeproj"), withDestinationURL: victimProject)
        XCTAssertThrowsError(try installer(projectAttack).install(InstallOptions())) {
            XCTAssertTrue("\($0)".contains("outside the Podfile directory"), "\($0)")
        }
        XCTAssertEqual(try String(contentsOf: victimProject.appendingPathComponent("project.pbxproj"), encoding: .utf8), victimText)

        let generatedAttack = try fixture("target 'App' do\nend\n")
        try FileManager.default.createSymbolicLink(
            at: generatedAttack.appendingPathComponent("SwiftPods"), withDestinationURL: victim)
        XCTAssertThrowsError(try installer(generatedAttack).install(InstallOptions())) {
            XCTAssertTrue("\($0)".contains("symbolic link"), "\($0)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: victim.appendingPathComponent(".swiftpods-owned").path))

        let nestedAttack = try fixture("target 'App' do\nend\n")
        _ = try installer(nestedAttack).install(InstallOptions())
        let generatedScript = nestedAttack.appendingPathComponent("SwiftPods/Scripts/App/App/prepare.sh")
        let outsideScript = nestedAttack.appendingPathComponent("redirected-prepare.sh")
        try FileManager.default.copyItem(at: generatedScript, to: outsideScript)
        try FileManager.default.removeItem(at: generatedScript)
        try FileManager.default.createSymbolicLink(at: generatedScript, withDestinationURL: outsideScript)
        XCTAssertThrowsError(try installer(nestedAttack).install(InstallOptions())) {
            XCTAssertTrue("\($0)".contains("symbolic link or special file"), "\($0)")
        }
    }

    func testGeneratedRootRejectsWritableModesAndExtendedACLs() throws {
        let directory = try fixture("target 'App' do\nend\n")
        _ = try installer(directory).install(InstallOptions())
        let root = directory.appendingPathComponent("SwiftPods", isDirectory: true)

        XCTAssertEqual(chmod(root.path, 0o777), 0)
        XCTAssertThrowsError(try installer(directory).install(InstallOptions())) {
            XCTAssertTrue("\($0)".contains("not writable by group or others"), "\($0)")
        }
        XCTAssertEqual(chmod(root.path, 0o755), 0)

        _ = try ProcessRunner().run("/bin/chmod", ["+a", "everyone allow write", root.path], in: nil)
        XCTAssertTrue(try SecureFileTree.hasExtendedACL(root))
        XCTAssertThrowsError(try installer(directory).install(InstallOptions())) {
            XCTAssertTrue("\($0)".contains("extended ACL"), "\($0)")
        }
        _ = try ProcessRunner().run("/bin/chmod", ["-N", root.path], in: nil)

        let scripts = root.appendingPathComponent("Scripts", isDirectory: true)
        XCTAssertEqual(chmod(scripts.path, 0o777), 0)
        XCTAssertThrowsError(try installer(directory).install(InstallOptions())) {
            XCTAssertTrue("\($0)".contains("not writable by group or others"), "\($0)")
        }
        XCTAssertEqual(chmod(scripts.path, 0o755), 0)

        let script = scripts.appendingPathComponent("App/App/prepare.sh")
        _ = try ProcessRunner().run("/bin/chmod", ["+a", "everyone allow write", script.path], in: nil)
        XCTAssertThrowsError(try installer(directory).install(InstallOptions())) {
            XCTAssertTrue("\($0)".contains("extended ACL"), "\($0)")
        }
        _ = try ProcessRunner().run("/bin/chmod", ["-N", script.path], in: nil)
    }

    func testGeneratedPublicationPreservesOldTreeAndANonCooperatingReplacement() throws {
        let directory = try fixture("target 'App' do\n  settings 'SWIFT_VERSION' => '5.9'\nend\n")
        _ = try installer(directory).install(.init())
        let oldSettings = try generated(directory, "Settings/App/App.xcconfig")
        try "target 'App' do\n  settings 'SWIFT_VERSION' => '5.10'\nend\n"
            .write(to: directory.appendingPathComponent("Podfile"), atomically: true, encoding: .utf8)

        let concurrent = directory.appendingPathComponent("ConcurrentSettings", isDirectory: true)
        try FileManager.default.createDirectory(at: concurrent, withIntermediateDirectories: false)
        try "preserve me\n".write(
            to: concurrent.appendingPathComponent("concurrent.txt"), atomically: false, encoding: .utf8)
        let generatedSettings = directory.appendingPathComponent("SwiftPods/Settings", isDirectory: true)
        let raced = Installer(
            directory: directory, cache: directory.appendingPathComponent(".cache"),
            generatedMutationHook: { point in
                guard point == .afterPublish("Settings") else { return }
                precondition(renamex_np(concurrent.path, generatedSettings.path, UInt32(RENAME_SWAP)) == 0)
            })

        XCTAssertThrowsError(try raced.install(.init())) { error in
            XCTAssertTrue("\(error)".contains("raced with another writer"), "\(error)")
        }
        let staging = try preservedGeneratedStaging(directory)
        let visibleOld = try? generated(directory, "Settings/App/App.xcconfig")
        let stagedOld = try? String(
            contentsOf: staging.appendingPathComponent("Settings/App/App.xcconfig"), encoding: .utf8)
        XCTAssertTrue(visibleOld == oldSettings || stagedOld == oldSettings, "The displaced tree was not preserved")
        let visibleConcurrent = try? String(
            contentsOf: generatedSettings.appendingPathComponent("concurrent.txt"), encoding: .utf8)
        let stagedConcurrent = try? String(
            contentsOf: staging.appendingPathComponent("Settings/concurrent.txt"), encoding: .utf8)
        XCTAssertTrue(
            visibleConcurrent == "preserve me\n" || stagedConcurrent == "preserve me\n",
            "The concurrent replacement was not preserved")
        XCTAssertTrue(
            try String(contentsOf: concurrent.appendingPathComponent("App/App.xcconfig"), encoding: .utf8)
                .contains("5.10"))
    }

    func testGeneratedWithdrawalPreservesAConcurrentReplacementAndTheWithdrawnTree() throws {
        let directory = try fixture(
            "target 'App' do\n  binary 'Kit', path: 'Vendor/Kit.xcframework'\nend\n")
        try makeXCFramework(directory.appendingPathComponent("Vendor/Kit.xcframework"))
        _ = try installer(directory).install(.init())
        try "target 'App' do\nend\n".write(
            to: directory.appendingPathComponent("Podfile"), atomically: true, encoding: .utf8)

        let concurrent = directory.appendingPathComponent("ConcurrentBinaries", isDirectory: true)
        try FileManager.default.createDirectory(at: concurrent, withIntermediateDirectories: false)
        try "preserve me\n".write(
            to: concurrent.appendingPathComponent("concurrent.txt"), atomically: false, encoding: .utf8)
        let generatedBinaries = directory.appendingPathComponent(
            "SwiftPods/SwiftPodsBinaries", isDirectory: true)
        let raced = Installer(
            directory: directory, cache: directory.appendingPathComponent(".cache"),
            generatedMutationHook: { point in
                guard point == .afterWithdraw("SwiftPodsBinaries") else { return }
                precondition(rename(concurrent.path, generatedBinaries.path) == 0)
            })

        XCTAssertThrowsError(try raced.install(.init())) { error in
            XCTAssertTrue("\(error)".contains("withdrawal raced with another writer"), "\(error)")
        }
        XCTAssertEqual(
            try String(contentsOf: generatedBinaries.appendingPathComponent("concurrent.txt"), encoding: .utf8),
            "preserve me\n")
        let staging = try preservedGeneratedStaging(directory)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: staging.appendingPathComponent("SwiftPodsBinaries/Package.swift").path))
    }

    func testGeneratedRollbackRefusesToOverwriteANonCooperatingReplacement() throws {
        let directory = try fixture("target 'App' do\n  settings 'SWIFT_VERSION' => '5.9'\nend\n")
        _ = try installer(directory).install(.init())
        try "target 'App' do\n  settings 'SWIFT_VERSION' => '5.10'\nend\n"
            .write(to: directory.appendingPathComponent("Podfile"), atomically: true, encoding: .utf8)

        let concurrent = directory.appendingPathComponent("ConcurrentSettings", isDirectory: true)
        try FileManager.default.createDirectory(at: concurrent, withIntermediateDirectories: false)
        try "preserve me\n".write(
            to: concurrent.appendingPathComponent("concurrent.txt"), atomically: false, encoding: .utf8)
        let generatedSettings = directory.appendingPathComponent("SwiftPods/Settings", isDirectory: true)
        let runner = RecordingRunner { executable, arguments, _ in
            guard executable == "/usr/bin/xcrun", arguments.first == "xcodebuild" else { return "" }
            precondition(renamex_np(concurrent.path, generatedSettings.path, UInt32(RENAME_SWAP)) == 0)
            throw SwiftPodsError("forced late failure")
        }
        var options = InstallOptions()
        options.resolve = true

        XCTAssertThrowsError(try Installer(
            directory: directory, runner: runner, cache: directory.appendingPathComponent(".cache")
        ).install(options)) { error in
            XCTAssertTrue("\(error)".contains("rollback was incomplete"), "\(error)")
            XCTAssertTrue("\(error)".contains("concurrent replacement"), "\(error)")
        }
        XCTAssertEqual(
            try String(contentsOf: generatedSettings.appendingPathComponent("concurrent.txt"), encoding: .utf8),
            "preserve me\n")
        let staging = try preservedGeneratedStaging(directory)
        XCTAssertTrue(
            try String(contentsOf: staging.appendingPathComponent("Settings/App/App.xcconfig"), encoding: .utf8)
                .contains("5.9"))
        XCTAssertTrue(
            try String(contentsOf: concurrent.appendingPathComponent("App/App.xcconfig"), encoding: .utf8)
                .contains("5.10"))
    }

    func testGeneratedRootCannotRebindAwayFromTheLockedWorkspaceDescriptor() throws {
        let directory = try fixture("target 'App' do\nend\n")
        let moved = directory.deletingLastPathComponent().appendingPathComponent(
            "moved-workspace-" + UUID().uuidString, isDirectory: true)
        directories.append(moved)
        let replacementSentinel = directory.appendingPathComponent("replacement.txt")
        let raced = Installer(
            directory: directory, cache: directory.appendingPathComponent(".cache"),
            generatedMutationHook: { point in
                guard point == .beforeGeneratedRootOpen else { return }
                precondition(rename(directory.path, moved.path) == 0)
                precondition(mkdir(directory.path, 0o755) == 0)
                precondition(FileManager.default.createFile(
                    atPath: replacementSentinel.path, contents: Data("replacement\n".utf8)))
            })

        XCTAssertThrowsError(try raced.install(.init())) { error in
            XCTAssertTrue("\(error)".contains("Podfile directory changed while the workspace was locked"), "\(error)")
        }
        XCTAssertEqual(try String(contentsOf: replacementSentinel, encoding: .utf8), "replacement\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("SwiftPods").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: moved.appendingPathComponent("SwiftPods").path))
    }

    func testGeneratedStagingCleanupPreservesAChildAddedAfterVerification() throws {
        let directory = try fixture("target 'App' do\n  settings 'SWIFT_VERSION' => '5.10'\nend\n")
        let root = directory.appendingPathComponent("SwiftPods", isDirectory: true)
        let raced = Installer(
            directory: directory, cache: directory.appendingPathComponent(".cache"),
            generatedMutationHook: { point in
                guard point == .afterStagingCleanupVerification else { return }
                let stagingNames = try! FileManager.default.contentsOfDirectory(atPath: root.path)
                    .filter { $0.hasPrefix(".staging-") }
                precondition(stagingNames.count == 1)
                let unknown = root.appendingPathComponent(stagingNames[0], isDirectory: true)
                    .appendingPathComponent("concurrent.txt")
                precondition(FileManager.default.createFile(
                    atPath: unknown.path, contents: Data("preserve me\n".utf8)))
            })

        let report = try raced.install(.init())

        XCTAssertTrue(report.notes.contains { $0.contains("could not remove a completed transaction staging") })
        let staging = try preservedGeneratedStaging(directory)
        XCTAssertEqual(
            try String(contentsOf: staging.appendingPathComponent("concurrent.txt"), encoding: .utf8),
            "preserve me\n")
        XCTAssertEqual(
            try String(
                contentsOf: staging.appendingPathComponent(".swiftpods-staging"), encoding: .utf8),
            "SwiftPods generated staging v1\n")
        XCTAssertTrue(try generated(directory, "Settings/App/App.xcconfig").contains("5.10"))
    }

    func testGeneratedMutationFingerprintRejectsAnAdversarialDeepTree() throws {
        let directory = try fixture("target 'App' do\n  settings 'SWIFT_VERSION' => '5.9'\nend\n")
        _ = try installer(directory).install(.init())
        try "target 'App' do\n  settings 'SWIFT_VERSION' => '5.10'\nend\n".write(
            to: directory.appendingPathComponent("Podfile"), atomically: true, encoding: .utf8)
        let settings = directory.appendingPathComponent("SwiftPods/Settings", isDirectory: true)
        let raced = Installer(
            directory: directory, cache: directory.appendingPathComponent(".cache"),
            generatedMutationHook: { point in
                guard point == .afterPublish("Settings") else { return }
                var nested = settings
                for index in 0..<66 {
                    nested.appendPathComponent("deep-\(index)", isDirectory: true)
                    precondition(mkdir(nested.path, 0o700) == 0)
                }
            })

        XCTAssertThrowsError(try raced.install(.init())) { error in
            XCTAssertTrue("\(error)".contains("changed immediately after publication"), "\(error)")
        }
        _ = try preservedGeneratedStaging(directory)
    }

    func testScriptFileListSymlinkCannotRedirectReads() throws {
        let directory = try fixture(
            "target 'App' do\n  script_phase name: 'Build', script: 'true', input_file_lists: ['Inputs.xcfilelist']\nend\n")
        let outside = directory.appendingPathComponent("outside.xcfilelist")
        try "$(SRCROOT)/Secret\n".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("Inputs.xcfilelist"), withDestinationURL: outside)

        XCTAssertThrowsError(try installer(directory).install(InstallOptions())) {
            XCTAssertTrue("\($0)".contains("Cannot safely read file list"), "\($0)")
        }
    }

    func testScriptFileListOutsideThePodfileDirectoryRequiresExplicitTrust() throws {
        let outsideDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "swiftpods-external-file-list-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: false)
        directories.append(outsideDirectory)
        let outside = outsideDirectory.appendingPathComponent("Inputs.xcfilelist")
        try "$(SRCROOT)/External.swift\n".write(to: outside, atomically: true, encoding: .utf8)
        let directory = try fixture(
            "target 'App' do\n  script_phase name: 'Build', script: 'true', input_file_lists: ['\(outside.path)']\nend\n")

        XCTAssertThrowsError(try installer(directory).install(InstallOptions())) {
            XCTAssertTrue("\($0)".contains("outside the Podfile directory"), "\($0)")
        }

        var trusted = InstallOptions()
        trusted.allowExternalFileLists = true
        _ = try installer(directory).install(trusted)
        let inputs = try generated(directory, "Scripts/App/App/finish.inputs.xcfilelist")
        XCTAssertTrue(inputs.contains("$(SRCROOT)/External.swift\n"), inputs)
    }

    func testScriptFileListCannotTraverseThroughASymlinkedDirectory() throws {
        let directory = try fixture(
            "target 'App' do\n  script_phase name: 'Build', script: 'true', input_file_lists: ['Lists/Inputs.xcfilelist']\nend\n")
        let real = directory.appendingPathComponent("RealLists", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false)
        try "Sources/One.swift\n".write(
            to: real.appendingPathComponent("Inputs.xcfilelist"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("Lists", isDirectory: true), withDestinationURL: real)

        XCTAssertThrowsError(try installer(directory).install(InstallOptions())) {
            XCTAssertTrue("\($0)".contains("Cannot safely read file list"), "\($0)")
        }
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
