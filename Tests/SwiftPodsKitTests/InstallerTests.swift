import Foundation
@testable import SwiftPodsKit
import SwiftPodsManifest
import SwiftPodsTestSupport
import SwiftPodsXcode
import XCTest

final class InstallerTests: XCTestCase {
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
        XCTAssertTrue(prepare.contains("/usr/bin/shasum -a 256 --check --status"), prepare)
        XCTAssertTrue(prepare.contains(#"'/bin/sh' "${SRCROOT}/SwiftPods/Scripts/App/App/2.sh""#), prepare)
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
            #"/usr/bin/rsync -a --delete "${SRCROOT}/SwiftPods/SwiftPodsBinaries/Artifacts/Ads/Resources/AdsRes.bundle" "$destination/""#), finish)
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
        try String(format: workspaceText, podsReference).write(
            to: workspace.appendingPathComponent("contents.xcworkspacedata"), atomically: true, encoding: .utf8)

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
            try String(contentsOf: workspace.appendingPathComponent("contents.xcworkspacedata"), encoding: .utf8),
            String(format: workspaceText, ""))
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
        func install(_ configure: (inout InstallOptions) -> Void = { _ in }) throws {
            var options = InstallOptions()
            configure(&options)
            _ = try Installer(directory: directory, cache: directory.appendingPathComponent(".cache"), sourcesCache: sources).install(options)
        }
        func urls() throws -> [String] {
            let manifest = try generated(directory, "SwiftPodsDependencies/Package.swift")
            return ["https://github.com/a/Kit.git", "https://github.com/b/Kit.git"].filter(manifest.contains)
        }
        try install()
        XCTAssertEqual(try urls(), ["https://github.com/a/Kit.git"])
        let resolved = directory.appendingPathComponent("App.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
        try FileManager.default.createDirectory(at: resolved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"pins":[{"identity":"kit","kind":"remoteSourceControl","location":"https://github.com/a/Kit.git","state":{"revision":"abc","version":"1.0.0"}}],"version":3}"#
            .write(to: resolved, atomically: true, encoding: .utf8)

        // The catalog moves Kit; the cached catalog keeps installs repeatable until sources are updated.
        try publish("https://github.com/b/Kit.git")
        try install()
        XCTAssertEqual(try urls(), ["https://github.com/a/Kit.git"])
        try install { $0.deployment = true }
        XCTAssertThrowsError(try install { $0.deployment = true; $0.updateSources = true }) { error in
            XCTAssertTrue("\(error)".contains("https://github.com/b/Kit.git) has no pin"), "\(error)")
        }
        try install { $0.updateSources = true }
        XCTAssertEqual(try urls(), ["https://github.com/b/Kit.git"])

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
            XCTAssertTrue("\(error)".contains("SHA-256 is \(digest)"), "\(error)")
        }
        XCTAssertEqual(try project(directory).serialized(), Fixtures.project, "A failed install changes nothing")

        try "target 'App' do\n  binary 'Remote', url: '\(archive.absoluteString)', sha256: '\(digest)'\nend\n"
            .write(to: directory.appendingPathComponent("Podfile"), atomically: true, encoding: .utf8)
        _ = try installer(directory).install(InstallOptions())
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("SwiftPods/SwiftPodsBinaries/Artifacts/Remote/Remote.xcframework").path))

        try FileManager.default.removeItem(at: archive)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("SwiftPods"))
        var offline = InstallOptions()
        offline.offline = true
        _ = try installer(directory).install(offline)
    }

    func testDeploymentRequiresSatisfyingPins() throws {
        let directory = try fixture("target 'App' do\n  spm 'https://github.com/a/Kit.git', '~> 1.2'\nend\n")
        var options = InstallOptions()
        options.deployment = true
        XCTAssertThrowsError(try installer(directory).install(options)) { XCTAssertTrue("\($0)".contains("Package.resolved"), "\($0)") }

        let resolved = directory.appendingPathComponent("App.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
        try FileManager.default.createDirectory(at: resolved.deletingLastPathComponent(), withIntermediateDirectories: true)
        func pin(_ version: String) throws {
            let json = #"{"pins":[{"identity":"kit","kind":"remoteSourceControl","location":"https://github.com/a/Kit","state":{"revision":"abc","version":"\#(version)"}}],"version":3}"#
            try json.write(to: resolved, atomically: true, encoding: .utf8)
        }
        try pin("2.0.0")
        XCTAssertThrowsError(try installer(directory).install(options)) {
            XCTAssertTrue("\($0)".contains("pinned to 2.0.0, the Podfile requires 1.2.0 up to next major"), "\($0)")
        }
        try pin("1.4.1")
        _ = try installer(directory).install(options)
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
        try "#include? \"../SwiftPods/Settings/App/App.xcconfig\"\nSDKROOT = iphoneos\n"
            .write(to: directory.appendingPathComponent("Config/App.xcconfig"), atomically: true, encoding: .utf8)
        _ = try installer(directory).install(InstallOptions())
        let after = try project(directory)
        XCTAssertTrue(after.configurations(of: after.nativeTargets[0].id).values.allSatisfy {
            after[$0]?.string("baseConfigurationReference") == "C00000000000000000000001"
        })

        // Without settings, a base configuration of the target's own need not include SwiftPods'.
        try "SDKROOT = iphoneos\n".write(to: directory.appendingPathComponent("Config/App.xcconfig"), atomically: true, encoding: .utf8)
        try "target 'App' do\nend\n".write(to: directory.appendingPathComponent("Podfile"), atomically: true, encoding: .utf8)
        _ = try installer(directory).install(InstallOptions())
    }
}
