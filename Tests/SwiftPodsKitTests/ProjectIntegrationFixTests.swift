import Foundation
@testable import SwiftPodsKit
import SwiftPodsManifest
import SwiftPodsTestSupport
@testable import SwiftPodsXcode
import XCTest

/// Project integration across renames, user edits, synchronized folders and CocoaPods subprojects.
final class ProjectIntegrationFixTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories = []
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

    private func podfile(_ directory: URL, _ text: String) throws {
        try text.write(to: directory.appendingPathComponent("Podfile"), atomically: true, encoding: .utf8)
    }

    private func target(_ project: XcodeProject, _ name: String) -> PBXObject {
        project[project.nativeTargets.first { $0.name == name }!.id]!
    }

    private func phaseNames(_ project: XcodeProject, _ target: String) -> [String] {
        self.target(project, target).strings("buildPhases").map { project[$0]?.string("name") ?? project[$0]!.isa! }
    }

    private func products(_ project: XcodeProject, _ target: String) -> [String] {
        self.target(project, target).strings("packageProductDependencies").compactMap { project[$0]?.string("productName") }
    }

    /// Every reference property and reference list names an object that exists.
    private func assertNoDanglingReferences(_ project: XcodeProject, file: StaticString = #filePath, line: UInt = #line) {
        let single = ["fileRef", "productRef", "package", "remoteRef", "target", "targetProxy", "containerPortal",
                      "baseConfigurationReference", "buildConfigurationList", "mainGroup", "productRefGroup"]
        let lists = ["files", "children", "buildPhases", "packageProductDependencies", "dependencies", "packageReferences",
                     "targets", "buildConfigurations"]
        for (id, object) in project.objects {
            for key in single {
                if let reference = object.string(key) {
                    XCTAssertNotNil(project[reference], "\(id).\(key) names missing \(reference)", file: file, line: line)
                }
            }
            for key in lists {
                for reference in object.strings(key) {
                    XCTAssertNotNil(project[reference], "\(id).\(key) lists missing \(reference)", file: file, line: line)
                }
            }
        }
    }

    // MARK: - Renamed targets

    func testRenamingATargetKeepsOneSetOfSwiftPodsObjects() throws {
        let directory = try fixture(
            """
            target 'App' do
              spm 'https://github.com/a/Bar.git', exact: '1.0.0', products: ['Bar']
            end
            """)
        _ = try installer(directory).install(InstallOptions())

        // The target is renamed in Xcode and in the Podfile.
        var renamed = try project(directory)
        let app = renamed.nativeTargets.first { $0.name == "App" }!.id
        renamed[app]!["name"] = "MyApp"
        try renamed.save()
        try podfile(directory, "target 'MyApp' do\n  spm 'https://github.com/a/Bar.git', exact: '1.0.0', products: ['Bar']\nend\n")
        _ = try installer(directory).install(InstallOptions())

        let installed = try project(directory)
        let phases = phaseNames(installed, "MyApp")
        XCTAssertEqual(phases.filter { $0 == "[SwiftPods] Prepare" }.count, 1, "\(phases)")
        XCTAssertEqual(phases.filter { $0 == "[SwiftPods] Finish" }.count, 1, "\(phases)")
        XCTAssertEqual(products(installed, "MyApp"), ["SwiftPods-MyApp", "Bar"])
        XCTAssertEqual(try installer(directory).install(InstallOptions()).projects[0].changes, [])
        assertNoDanglingReferences(installed)

        _ = try installer(directory).deintegrate()
        let clean = try project(directory)
        XCTAssertEqual(phaseNames(clean, "MyApp"), ["PBXSourcesBuildPhase", "PBXFrameworksBuildPhase"])
        XCTAssertEqual(products(clean, "MyApp"), [])
        XCTAssertTrue(clean.objects.values.allSatisfy { $0.isa != "XCSwiftPackageProductDependency" })
        assertNoDanglingReferences(clean)
    }

    func testObjectsOfALegacyInstallationAreRecognizedAfterARename() throws {
        var project = try XcodeProject(path: URL(fileURLWithPath: "/tmp/App.xcodeproj"), text: Fixtures.project)
        let app = "A50000000000000000000001"
        // SwiftPods 0.3.17 derived these from the target's old name, App.
        let packageKey = "package:local:SwiftPods/SwiftPodsDependencies"
        let package = XcodeProject.identifier(packageKey)
        project[package] = [
            "isa": "PBXFileReference", "lastKnownFileType": "wrapper", "name": "SwiftPodsDependencies",
            "path": "SwiftPods/SwiftPodsDependencies", "sourceTree": "SOURCE_ROOT",
        ]
        let container = XcodeProject.identifier(
            ProjectIntegration.legacyProductKey(target: "App", package: packageKey, product: "SwiftPods-App"))
        project[container] = ["isa": "XCSwiftPackageProductDependency", "productName": "SwiftPods-App"]
        project.append(container, to: "packageProductDependencies", of: app)
        let buildFile = XcodeProject.identifier("build-file:" + container)
        project[buildFile] = ["isa": "PBXBuildFile", "productRef": .string(container)]
        project.append(buildFile, to: "files", of: "A30000000000000000000001")
        let prepare = XcodeProject.identifier(ProjectIntegration.legacyScriptKey(target: "App", name: "Prepare"))
        project[prepare] = ["isa": "PBXShellScriptBuildPhase", "name": "[SwiftPods] Prepare", "shellScript": "exit 0"]
        project.append(prepare, to: "buildPhases", of: app)
        // A Finish phase someone duplicated with a target keeps SwiftPods' generated runner.
        let finish = "B00000000000000000000001"
        project[finish] = [
            "isa": "PBXShellScriptBuildPhase", "name": "[SwiftPods] Finish",
            "shellScript": .string("echo \"error: \(TargetScripts.notInstalledMessage)\" >&2"),
        ]
        project.append(finish, to: "buildPhases", of: app)
        // A user phase that merely shares the prefix is not SwiftPods'.
        let user = "B00000000000000000000002"
        project[user] = ["isa": "PBXShellScriptBuildPhase", "name": "[SwiftPods] Finish", "shellScript": "echo mine"]
        project.append(user, to: "buildPhases", of: app)
        project[app]!["name"] = "MyApp"

        let owned = try ProjectIntegration.ownedIdentifiers(project)
        XCTAssertTrue(owned.isSuperset(of: [package, container, buildFile, prepare, finish]), "\(owned)")
        XCTAssertFalse(owned.contains(user))

        _ = try ProjectIntegration.apply(ProjectPlan(), to: &project, adopt: false)
        XCTAssertEqual(project[app]!.strings("buildPhases"), ["A60000000000000000000001", "A30000000000000000000001", user])
        XCTAssertNil(project[container])
        assertNoDanglingReferences(project)
    }

    func testUpgradingALegacyInstallationKeepsTheUsersEntriesForItsProducts() throws {
        let url = "https://github.com/a/Bar.git"
        let directory = try fixture("target 'App' do\n  spm '\(url)', exact: '1.0.0', products: ['Bar']\nend\n")
        _ = try installer(directory).install(InstallOptions())

        // Turn the installation into what SwiftPods 0.3.17 wrote: Bar's product and build file derive from "App".
        var legacy = try project(directory)
        let app = legacy.nativeTargets.first { $0.name == "App" }!.id
        let appTests = legacy.nativeTargets.first { $0.name == "AppTests" }!.id
        let packageKey = "package:" + PackageLocation.canonical(url)
        let current = XcodeProject.identifier(ProjectIntegration.productKey(targetID: app, package: packageKey, product: "Bar"))
        let old = XcodeProject.identifier(ProjectIntegration.legacyProductKey(target: "App", package: packageKey, product: "Bar"))
        let renames = [current: old, XcodeProject.identifier("build-file:" + current): XcodeProject.identifier("build-file:" + old)]
        XCTAssertNotNil(legacy[current])
        for (from, to) in renames {
            legacy[to] = legacy[from]
            legacy[from] = nil
        }
        for (id, object) in legacy.objects {
            var updated = object
            for (key, value) in object {
                if let reference = value.string, let renamed = renames[reference] { updated[key] = .string(renamed) }
                if let array = value.array {
                    updated[key] = .array(array.map { $0.string.flatMap { renames[$0] }.map(PBXValue.string) ?? $0 })
                }
            }
            legacy[id] = updated
        }
        // Someone embeds Bar in a phase of their own.
        let embed = "B00000000000000000000001"
        let file = "B00000000000000000000002"
        legacy[file] = ["isa": "PBXBuildFile", "productRef": .string(old)]
        legacy[embed] = [
            "isa": "PBXCopyFilesBuildPhase", "buildActionMask": "2147483647", "dstPath": "", "dstSubfolderSpec": "10",
            "files": [.string(file)], "name": "Embed Frameworks", "runOnlyForDeploymentPostprocessing": "0",
        ]
        legacy.append(embed, to: "buildPhases", of: app)
        legacy.append(old, to: "packageProductDependencies", of: appTests)
        try legacy.save()
        XCTAssertTrue(try ProjectIntegration.ownedIdentifiers(project(directory)).contains(old))

        let report = try installer(directory).install(InstallOptions())
        let installed = try project(directory)
        XCTAssertNil(installed[old])
        XCTAssertEqual(installed[file]?.string("productRef"), current)
        XCTAssertEqual(installed[embed]?.strings("files"), [file])
        XCTAssertEqual(products(installed, "App"), ["SwiftPods-App", "Bar"])
        XCTAssertEqual(installed[appTests]?.strings("packageProductDependencies"), [current])
        XCTAssertFalse(report.notes.contains { $0.contains(file) }, "\(report.notes)")
        assertNoDanglingReferences(installed)
        XCTAssertEqual(try installer(directory).install(InstallOptions()).projects[0].changes, [])
    }

    // MARK: - References from objects SwiftPods does not own

    func testAPackageStillUsedByTheUserIsKeptAndReported() throws {
        let url = "https://github.com/a/Bar.git"
        let directory = try fixture("target 'App' do\n  spm '\(url)', exact: '1.0.0', products: ['Bar']\nend\n")
        _ = try installer(directory).install(InstallOptions())
        let package = XcodeProject.identifier("package:" + PackageLocation.canonical(url))

        // Someone links another product of that package to AppTests in Xcode.
        var edited = try project(directory)
        let tests = edited.nativeTargets.first { $0.name == "AppTests" }!.id
        let extra = "B00000000000000000000001"
        edited[extra] = ["isa": "XCSwiftPackageProductDependency", "package": .string(package), "productName": "BarExtra"]
        edited.append(extra, to: "packageProductDependencies", of: tests)
        try edited.save()

        try podfile(directory, "target 'App' do\nend\n")
        let report = try installer(directory).install(InstallOptions())
        XCTAssertTrue(report.notes.contains { $0.contains("Kept package \(url)") && $0.contains("BarExtra in AppTests") }, "\(report.notes)")
        var installed = try project(directory)
        XCTAssertEqual(installed[extra]?.string("package"), package)
        XCTAssertNotNil(installed[package])
        XCTAssertTrue(installed.project.strings("packageReferences").contains(package))
        XCTAssertEqual(products(installed, "App"), ["SwiftPods-App"])
        assertNoDanglingReferences(installed)

        let deintegrated = try installer(directory).deintegrate()
        XCTAssertTrue(deintegrated.notes.contains { $0.contains("Kept package \(url)") }, "\(deintegrated.notes)")
        installed = try project(directory)
        XCTAssertNotNil(installed[package])
        XCTAssertNotNil(installed[extra])
        assertNoDanglingReferences(installed)

        // Once nothing of theirs uses it, the package goes too.
        installed.remove(extra)
        installed[tests]!["packageProductDependencies"] = []
        try installed.save()
        _ = try installer(directory).deintegrate()
        XCTAssertNil(try project(directory)[package])
    }

    func testAUserEntryForAProductSwiftPodsRemovesGoesWithIt() throws {
        let directory = try fixture("target 'App' do\n  spm 'https://github.com/a/Bar.git', exact: '1.0.0', products: ['Bar']\nend\n")
        _ = try installer(directory).install(InstallOptions())

        // Someone adds SwiftPods' Bar product to an Embed Frameworks phase of their own.
        var edited = try project(directory)
        let app = edited.nativeTargets.first { $0.name == "App" }!.id
        let product = target(edited, "App").strings("packageProductDependencies").first { edited[$0]?.string("productName") == "Bar" }!
        let embed = "B00000000000000000000001"
        let file = "B00000000000000000000002"
        edited[file] = ["isa": "PBXBuildFile", "productRef": .string(product)]
        edited[embed] = [
            "isa": "PBXCopyFilesBuildPhase", "buildActionMask": "2147483647", "dstPath": "", "dstSubfolderSpec": "10",
            "files": [.string(file)], "name": "Embed Frameworks", "runOnlyForDeploymentPostprocessing": "0",
        ]
        edited.append(embed, to: "buildPhases", of: app)
        try edited.save()

        let report = try installer(directory).deintegrate()
        XCTAssertTrue(report.notes.contains { $0.contains("PBXBuildFile \(file)") }, "\(report.notes)")
        let clean = try project(directory)
        XCTAssertNil(clean[file])
        XCTAssertEqual(clean[embed]?.strings("files"), [])
        assertNoDanglingReferences(clean)
    }

    func testAFrameworksPhaseWithTheUsersFilesIsKept() throws {
        let directory = try fixture("target 'Plugin' do\n  spm 'https://github.com/a/Bar.git', exact: '1.0.0', products: ['Bar']\nend\n")
        _ = try installer(directory).install(InstallOptions())

        // Plugin had no Frameworks phase, so SwiftPods created one; someone then adds a library of their own to it.
        var edited = try project(directory)
        let phase = target(edited, "Plugin").strings("buildPhases").first { edited[$0]?.isa == "PBXFrameworksBuildPhase" }!
        XCTAssertTrue(try ProjectIntegration.ownedIdentifiers(edited).contains(phase))
        let library = "B00000000000000000000001"
        let file = "B00000000000000000000002"
        edited[library] = ["isa": "PBXFileReference", "lastKnownFileType": "sourcecode.text-based-dylib-definition",
                           "name": "libz.tbd", "path": "usr/lib/libz.tbd", "sourceTree": "SDKROOT"]
        edited[file] = ["isa": "PBXBuildFile", "fileRef": .string(library)]
        edited.append(file, to: "files", of: phase)
        try edited.save()

        _ = try installer(directory).install(InstallOptions())
        var installed = try project(directory)
        XCTAssertEqual(target(installed, "Plugin").strings("buildPhases").filter { installed[$0]?.isa == "PBXFrameworksBuildPhase" }, [phase])
        XCTAssertTrue(installed[phase]!.strings("files").contains(file))
        XCTAssertEqual(installed[phase]!.strings("files").count, 3, "SwiftPods-Plugin, Bar and the user's library")

        _ = try installer(directory).deintegrate()
        installed = try project(directory)
        XCTAssertTrue(target(installed, "Plugin").strings("buildPhases").contains(phase))
        XCTAssertEqual(installed[phase]?.strings("files"), [file])
        assertNoDanglingReferences(installed)
    }

    // MARK: - Synchronized-folder base configurations

    func testAnXcconfigInASynchronizedFolderIsTheBaseConfiguration() throws {
        let directory = try fixture(
            "target 'App' do\n  settings 'FOO' => 'bar'\nend\n", files: ["Sources/Config/App.xcconfig": "BAR = 1\n"])
        var edited = try project(directory)
        let folder = "B00000000000000000000001"
        edited[folder] = ["isa": "PBXFileSystemSynchronizedRootGroup", "path": "Sources", "sourceTree": "<group>"]
        edited.append(folder, to: "children", of: edited.project.string("mainGroup")!)
        let debug = edited.configurations(of: edited.nativeTargets.first { $0.name == "App" }!.id)["Debug"]!
        edited[debug]!["baseConfigurationReferenceAnchor"] = .string(folder)
        edited[debug]!["baseConfigurationReferenceRelativePath"] = "Config/App.xcconfig"
        try edited.save()

        XCTAssertThrowsError(try installer(directory).install(InstallOptions())) { error in
            let text = "\(error)"
            XCTAssertTrue(text.contains("already uses Config/App.xcconfig as its Debug base configuration"), text)
            XCTAssertTrue(text.contains("#include? \"../../SwiftPods/Settings/App/App.xcconfig\""), text)
        }
        let config = directory.appendingPathComponent("Sources/Config/App.xcconfig")
        let configDirectory = config.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: configDirectory.appendingPathComponent("Other/Nested"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: configDirectory.appendingPathComponent("Alias").path,
                                                 withDestinationPath: "Other/Nested")
        for include in ["../../SwiftPods/Settings/App/App.xcconfig/",
                        "Missing/../../../SwiftPods/Settings/App/App.xcconfig",
                        "Alias/../../../SwiftPods/Settings/App/App.xcconfig"] {
            try "#include? \"\(include)\"\n".write(to: config, atomically: true, encoding: .utf8)
            XCTAssertThrowsError(try installer(directory).install(InstallOptions()), include)
        }

        try "BAR = 1\n#include? \"./Other/../../../SwiftPods/Settings/./App/App.xcconfig\"\n"
            .write(to: config, atomically: true, encoding: .utf8)
        _ = try installer(directory).install(InstallOptions())

        let installed = try project(directory)
        let configurations = installed.configurations(of: installed.nativeTargets.first { $0.name == "App" }!.id)
        XCTAssertNil(installed[configurations["Debug"]!]?.string("baseConfigurationReference"))
        XCTAssertEqual(installed[configurations["Debug"]!]?.string("baseConfigurationReferenceAnchor"), folder)
        XCTAssertNotNil(installed[configurations["Release"]!]?.string("baseConfigurationReference"))
    }

    func testABaseConfigurationThatCannotBeLocatedGetsNoWrongIncludePath() throws {
        let directory = try fixture("target 'App' do\n  settings 'FOO' => 'bar'\nend\n")
        var edited = try project(directory)
        let debug = edited.configurations(of: edited.nativeTargets.first { $0.name == "App" }!.id)["Debug"]!
        // Xcode always writes the relative path; without it the synchronized folder names no file.
        edited[debug]!["baseConfigurationReferenceAnchor"] = "B00000000000000000000001"
        try edited.save()

        XCTAssertThrowsError(try installer(directory).install(InstallOptions())) { error in
            let text = "\(error)"
            XCTAssertTrue(text.contains("SwiftPods cannot tell where that file is"), text)
            XCTAssertTrue(text.contains("to SwiftPods/Settings/App/App.xcconfig in the project folder"), text)
            XCTAssertFalse(text.contains("#include? \"SwiftPods/"), text)
        }
    }

    // MARK: - CocoaPods

    func testCocoaPodsSubprojectProductsAreRemoved() throws {
        var project = try XcodeProject(path: URL(fileURLWithPath: "/tmp/App.xcodeproj"), text: Fixtures.project)
        let pods = "C00000000000000000000001"
        let products = "C00000000000000000000002"
        let library = "C00000000000000000000003"
        let proxy = "C00000000000000000000004"
        let file = "C00000000000000000000005"
        project[pods] = ["isa": "PBXFileReference", "lastKnownFileType": "wrapper.pb-project", "name": "Pods.xcodeproj",
                         "path": "Pods/Pods.xcodeproj", "sourceTree": "<group>"]
        project[products] = ["isa": "PBXGroup", "children": [.string(library)], "name": "Products", "sourceTree": "<group>"]
        project[library] = ["isa": "PBXReferenceProxy", "fileType": "archive.ar", "path": "libPods-App.a",
                            "remoteRef": .string(proxy), "sourceTree": "BUILT_PRODUCTS_DIR"]
        project[proxy] = ["isa": "PBXContainerItemProxy", "containerPortal": .string(pods), "proxyType": "2",
                          "remoteGlobalIDString": "D00000000000000000000001", "remoteInfo": "Pods-App"]
        project[file] = ["isa": "PBXBuildFile", "fileRef": .string(library)]
        project.append(file, to: "files", of: "A30000000000000000000001")
        project.append(pods, to: "children", of: project.project.string("mainGroup")!)
        project.project["projectReferences"] = [["ProductGroup": .string(products), "ProjectRef": .string(pods)]]

        let changes = try CocoaPodsIntegration.remove(from: &project).map(\.description)
        for id in [pods, products, library, proxy, file] { XCTAssertNil(project[id], id) }
        XCTAssertNil(project.project["projectReferences"])
        XCTAssertEqual(project["A30000000000000000000001"]?.strings("files"), [])
        XCTAssertTrue(changes.contains("Removed file libPods-App.a"), "\(changes)")
        assertNoDanglingReferences(project)
        // The edited text is a project Foundation reads back.
        XCTAssertNoThrow(try XcodeProject(path: project.path, text: project.serialized()))
    }

    // MARK: - Generated scripts

    func testStaticLibraryModuleMapsComeFromObjectRootAlsoDuringArchive() throws {
        let directory = try fixture(
            "target 'Plugin' do\n  spm 'Interop', path: 'Modules/Interop'\nend\n",
            files: ["Modules/Interop/Package.swift": "// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(name: \"Interop\")\n"])
        _ = try installer(directory).install(InstallOptions())
        let scripts = directory.appendingPathComponent("SwiftPods/Scripts/App/Plugin")
        let prepare = try String(contentsOf: scripts.appendingPathComponent("prepare.sh"), encoding: .utf8)
        XCTAssertTrue(prepare.contains(#"swiftpods_module_maps="${OBJROOT}/GeneratedModuleMaps${EFFECTIVE_PLATFORM_NAME}""#), prepare)
        XCTAssertFalse(prepare.contains("Intermediates.noindex"), prepare)
        let inputs = try String(contentsOf: scripts.appendingPathComponent("prepare.inputs.xcfilelist"), encoding: .utf8)
        XCTAssertTrue(inputs.contains("$(OBJROOT)/GeneratedModuleMaps$(EFFECTIVE_PLATFORM_NAME)\n"), inputs)
    }
}
