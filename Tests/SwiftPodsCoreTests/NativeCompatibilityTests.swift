import XCTest
@testable import SwiftPodsCore

final class NativeCompatibilityTests: XCTestCase {
    private func directory() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: path) }
        return path
    }
    func testWarningAndConfigurationOptionsDoNotAllowPrereleases() throws {
        let stable = try NativeSpec(data: ["name": "Kit", "version": "1.0"])
        let preview = try NativeSpec(data: ["name": "Kit", "version": "2.0.pre"])
        for options: [String: Any] in [[:], ["inhibit_warnings": true], ["modular_headers": true], ["configurations": ["Debug"]], ["source": "repo"]] {
            let resolved = try NativeResolver(candidates: { _ in [preview, stable] }).resolve([NativeDependency(["name": "Kit", "options": options])])
            XCTAssertEqual(resolved.specs["Kit"]?.version, stable.version)
        }
        let external = try NativeResolver(candidates: { _ in [preview] }).resolve([NativeDependency(["name": "Kit", "options": ["path": "Kit"]])])
        XCTAssertEqual(external.specs["Kit"]?.version, preview.version)
    }
    func testPrereleaseRequirementAppliesAcrossTheWholeRoot() throws {
        let kit = try NativeSpec(data: ["name": "Kit", "version": "2.0.pre", "subspecs": [["name": "Core"]]])
        let feature = try NativeSpec(data: ["name": "Feature", "version": "1.0", "dependencies": ["Kit/Core": ["= 2.0.pre"]]])
        let result = try NativeResolver(candidates: { $0.root == "Kit" ? [kit] : [feature] }).resolve([NativeDependency(["name": "Kit"]), NativeDependency(["name": "Feature"])])
        XCTAssertEqual(result.specs["Kit"]?.version.description, "2.0.pre")
    }
    func testLockPinDoesNotAuthorizeAPrereleaseWithoutAnExplicitRequirement() throws {
        let stable = try NativeSpec(data: ["name": "Kit", "version": "1.0"])
        let preview = try NativeSpec(data: ["name": "Kit", "version": "2.0.pre"])
        let candidates: (NativeDependency) throws -> [NativeSpec] = { _ in [preview, stable] }
        let generic = try NativeDependency(["name": "Kit"])
        XCTAssertThrowsError(try NativeResolver(candidates: candidates, locked: ["Kit": "2.0.pre"]).resolve([generic]))
        let update = try NativeResolver(candidates: candidates, locked: ["Kit": "2.0.pre"], update: ["Kit"]).resolve([generic])
        XCTAssertEqual(update.specs["Kit"]?.version.description, "1.0")
    }
    func testLockedVersionsAreConstraintsUntilExplicitlyUnlocked() throws {
        let first = try NativeSpec(data: ["name": "Kit", "version": "1.0"]), second = try NativeSpec(data: ["name": "Kit", "version": "2.0"])
        let feature = try NativeSpec(data: ["name": "Feature", "version": "1.0", "dependencies": ["Kit": [">= 2"]]])
        let candidates: (NativeDependency) throws -> [NativeSpec] = { $0.root == "Kit" ? [second, first] : [feature] }
        let requests = try [NativeDependency(["name": "Kit"]), NativeDependency(["name": "Feature"])]
        XCTAssertThrowsError(try NativeResolver(candidates: candidates, locked: ["Kit": "1.0"]).resolve(requests)) { error in
            XCTAssertFalse((error as? Diagnostic)?.dependencyChain.isEmpty ?? true)
        }
        let updated = try NativeResolver(candidates: candidates, locked: ["Kit": "1.0"], update: ["Kit"]).resolve(requests)
        XCTAssertEqual(updated.specs["Kit"]?.version.description, "2.0")
    }
    func testSharedPodUsesSmallestCompatibleDependencyVariant() throws {
        let dep = try NativeSpec(data: ["name": "Dep", "version": "1.0", "default_subspecs": ["Core"], "subspecs": [["name": "Core"], ["name": "X"], ["name": "Y"], ["name": "Z"]]])
        let foo = try NativeSpec(data: ["name": "Foo", "version": "1.0", "dependencies": ["Dep/Core": [] as [String]]])
        let targets: [[String: Any]] = [("First", ["Dep/X", "Dep/Z"]), ("Second", ["Dep/Y"])].map { name, dependencies in
            ["name": name, "platform": ["name": "osx", "deployment_target": "13.0"], "frameworks": "dynamic", "dependencies": (["Foo"] + dependencies).map { ["name": $0] }]
        }
        let plan = try NativeVariantPlan(manifest: ["targets": targets], resolution: NativeResolution(specs: ["Dep": dep, "Foo": foo], requests: []))
        let shared = try XCTUnwrap(plan.variants.values.first { $0.root == "Foo" })
        XCTAssertEqual(shared.bindings["Dep"], plan.consumers["Second"]?["Dep"])
        XCTAssertNotEqual(shared.bindings["Dep"], plan.consumers["First"]?["Dep"])
    }
    func testStructuredLockReadsRepositoriesSourcesAndExtensions() throws {
        let path = try directory().appendingPathComponent("Podfile.lock")
        try Data("""
        PODS:
          - 'Kit/Core (1.2.3.4)':
            - Helper (~> 1.0)
          - Helper (1.1)
        DEPENDENCIES:
          - Kit/Core (~> 1.2)
        SPEC REPOS:
          'https://host.invalid:8443/specs.git':
            - Kit
        EXTERNAL SOURCES:
          Helper:
            :git: 'https://host.invalid/helper.git'
            :submodules: true
        CHECKOUT OPTIONS:
          Helper:
            :commit: 'abc123'
            :git: 'https://host.invalid/helper.git'
        SPEC CHECKSUMS: {Kit: 'abc'}
        PODFILE CHECKSUM: 'checksum'
        FUTURE METADATA:
          values: ['one', 'two']
        """.utf8).write(to: path)
        let lock = try NativeLock(path)
        XCTAssertEqual(lock.repositories["Kit"], "https://host.invalid:8443/specs.git")
        XCTAssertEqual(lock.externalSources["Helper"]?["submodules"] as? Bool, true)
        XCTAssertEqual(lock.checkoutOptions["Helper"]?["commit"], "abc123")
        XCTAssertEqual(lock.unlocked(["Kit"]), ["Kit", "Helper"])
        XCTAssertEqual((lock.raw["FUTURE METADATA"] as? [String: Any])?["values"] as? [String], ["one", "two"])
        XCTAssertEqual(lock.specChecksums["Kit"], "abc")
    }
    func testLockDetectsChangedDeclarationsWithoutUnlockingDuplicateConsumers() throws {
        let path = try directory().appendingPathComponent("Podfile.lock")
        try Data("PODS:\n  - Kit (1.0)\nDEPENDENCIES:\n  - Kit (~> 1.0)\n".utf8).write(to: path)
        let lock = try NativeLock(path), dependency = try NativeDependency(["name": "Kit", "requirements": ["~>1.0"]])
        XCTAssertEqual(try lock.changedRoots([dependency, dependency]), [])
        XCTAssertEqual(try lock.changedRoots([NativeDependency(["name": "Kit"])]), [])
        XCTAssertEqual(try lock.changedRoots([NativeDependency(["name": "Kit", "requirements": [">= 2"]])]), ["Kit"])
    }
    func testTargetedUpdateRetainsSharedDependencyPins() throws {
        let path = try directory().appendingPathComponent("Podfile.lock")
        try Data("PODS:\n  - A (1.0):\n    - Shared (>= 1)\n  - B (1.0):\n    - Shared (>= 0.5)\n  - Shared (1.0)\nDEPENDENCIES:\n  - A\n  - B\n".utf8).write(to: path)
        let lock = try NativeLock(path)
        XCTAssertEqual(lock.unlocked(["A"]), ["A"])
        XCTAssertEqual(lock.unlocked(["A", "B"]), ["A", "B", "Shared"])
        XCTAssertEqual(lock.unlocked(["A", "Shared"]), ["A", "Shared"])
        let direct = try [NativeDependency(["name": "A"]), NativeDependency(["name": "B"]), NativeDependency(["name": "Shared", "requirements": [">= 2"]])]
        XCTAssertEqual(try lock.changedRoots(direct), [])
    }
    func testReferenceLockGraphDeduplicatesIdenticalDependencyStrings() throws {
        let path = try directory().appendingPathComponent("Podfile.lock")
        try Data("PODS:\n  - A (1.0):\n    - Shared\n  - B (1.0):\n    - Shared\n  - Shared (1.0)\nDEPENDENCIES:\n  - A\n  - B\n".utf8).write(to: path)
        let lock = try NativeLock(path)
        XCTAssertEqual(lock.dependencies["B"], ["Shared"])
        XCTAssertEqual(lock.unlocked(["A"]), ["A", "Shared"])
        XCTAssertEqual(lock.unlocked(["B"]), ["B"])
    }
    func testLockedRepositoryDoesNotSwitchWhenEarlierSourceGainsTheVersion() throws {
        let root = try directory(), first = root.appendingPathComponent("first"), second = root.appendingPathComponent("second")
        for repository in [first, second] {
            try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
            try jsonData(["name": "Kit", "version": "1.0"]).write(to: repository.appendingPathComponent("Kit.podspec.json"))
        }
        let sources = try NativeSources(project: root, cache: root.appendingPathComponent("cache"), sources: [first.path, second.path], dsl: nil, offline: false, refresh: false, hardened: true)
        sources.lockedRepositories = ["Kit": second.path]
        let found = try sources.candidates(NativeDependency(["name": "Kit"]))
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.repository, second.path)
    }
    func testEmptyPublicPatternsUseAllHeadersExceptPrivateAndProjectHeaders() throws {
        let root = try directory()
        let files = ["Public.h", "Private.hpp", "Project.hxx"].map { root.appendingPathComponent($0) }
        for file in files { try Data().write(to: file) }
        for publicValue: Any? in [nil, [String]()] {
            var attributes: [String: Any] = ["private_header_files": "Private.hpp", "project_header_files": "Project.hxx"]
            attributes["public_header_files"] = publicValue
            let rules = try NativeFileRules(attributes, root: root, files: files)
            XCTAssertEqual(rules.publicHeaders, [files[0]])
        }
    }
    func testMalformedAndExecutableYAMLIsRejected() {
        for text in ["PODS: [broken", "PODS: !ruby/object:Exploit {}", "PODS: *alias", "PODS: []\nPODS: []", "PODS:\n\t- Kit (1.0)"] {
            XCTAssertThrowsError(try NativeYAML.object(text), text)
        }
    }
    func testConditionalXCConfigIncludesAndInheritance() throws {
        let root = try directory(), base = root.appendingPathComponent("Base.xcconfig"), child = root.appendingPathComponent("Child.xcconfig")
        try Data("FLAGS = base\nSDKROOT = macosx\n".utf8).write(to: child)
        try Data("#include \"Child.xcconfig\"\n#include? \"Absent.xcconfig\"\nFLAGS += more\nMINIMUM[config=Debug][sdk=macosx*] = 13.0\nMINIMUM[config=Release] = 14.0\n".utf8).write(to: base)
        var inputs = Set<String>()
        let debug = try NativeBuildSettings.xcconfig(base, context: ["config": "Debug"], inputs: &inputs)
        XCTAssertEqual(debug["FLAGS"] as? String, "base more")
        XCTAssertEqual(debug["MINIMUM"] as? String, "13.0")
        XCTAssertEqual(inputs.count, 2)
        try Data("#include \"Base.xcconfig\"\n".utf8).write(to: child)
        XCTAssertThrowsError(try NativeBuildSettings.xcconfig(base, inputs: &inputs))
    }
    func testConfigurationFileResolvesRelativePBXGroups() throws {
        let root = try directory(), graph = try NativePBX(root.appendingPathComponent("App.xcodeproj/project.pbxproj"))
        let main = graph.add("main", ["isa": "PBXGroup", "sourceTree": "<group>", "children": []])
        let group = graph.add("config", ["isa": "PBXGroup", "path": "Config", "sourceTree": "<group>", "children": []])
        let file = graph.add("file", ["isa": "PBXFileReference", "path": "App.xcconfig", "sourceTree": "<group>"])
        graph.objects[main]?["children"] = [group]; graph.objects[group]?["children"] = [file]
        XCTAssertEqual(try NativeBuildSettings.file(file, graph: graph).path, root.appendingPathComponent("Config/App.xcconfig").path)
        let merged = NativeBuildSettings.merge(["FLAGS": ["base"]], ["FLAGS": ["$(inherited)", "target"]])
        XCTAssertEqual(merged["FLAGS"] as? [String], ["base", "target"])
    }
    func testExplicitExternalProjectIsJournaledAndRecovered() throws {
        let root = try directory(), outside = try directory().appendingPathComponent("Outside.xcodeproj/project.pbxproj")
        try FileManager.default.createDirectory(at: outside.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("original".utf8).write(to: outside)
        let state = ProjectState(directory: root)
        try state.acquire(); try state.begin(command: ["install"], profile: "test")
        try state.registerProject(outside)
        try Data("generated".utf8).write(to: outside)
        try state.finish(result: HostResult(status: 1, events: [["kind": "managed_write", "path": outside.path]]), command: ["install"], profile: "test")
        _ = try state.recover()
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "original")
    }
}
