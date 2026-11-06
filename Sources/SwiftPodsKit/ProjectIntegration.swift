import Darwin
import Foundation
import SwiftPodsManifest
import SwiftPodsXcode

/// What one Xcode project should contain according to the Podfile.
struct ProjectPlan {
    struct PackageReference: Equatable {
        /// Identifies the reference; derived from the location so it is the same on every machine.
        let key: String
        let object: PBXObject
    }

    struct Product: Equatable {
        let package: PackageReference
        let name: String
        let link: Bool
    }

    /// A Run Script phase whose project entry stays the same; its script runs generated files.
    struct PhasePlan {
        let name: String
        let script: String
        let inputFileLists: [String]
        let outputFileLists: [String]
        let position: ScriptPhase.Position
    }

    struct TargetPlan {
        let name: String
        let products: [Product]
        let phases: [PhasePlan]
        /// The generated settings file, relative to the project directory.
        let settingsFile: String?
        /// Whether the generated file contains effective build settings, which a base configuration of its own must include.
        var hasSettings = true
        /// Resource bundles copied into the target's product, relative to the project directory.
        var resources: [String] = []
    }

    var packages: [PackageReference] = []
    var targets: [TargetPlan] = []
    /// Keys of every package the Podfile declares; the project must not reference them itself.
    var managedPackageKeys: Set<String> = []
    /// Products of the Podfile's local packages, which a project may name without a package.
    var managedLocalProducts: Set<String> = []
}

/// A change made to a project, for the command's report.
public struct ProjectChange: Sendable, Equatable, Codable, CustomStringConvertible {
    public enum Kind: String, Sendable, Codable { case added, removed, updated, reordered }
    public let kind: Kind
    public let subject: String

    public init(kind: Kind, subject: String) {
        self.kind = kind
        self.subject = subject
    }

    public var description: String { kind.rawValue.capitalized + " " + subject }
}

enum ProjectIntegration {
    static let scriptPrefix = "[SwiftPods] "
    static let groupKey = "group:SwiftPods"
    private static let maximumSemanticWork = 1_000_000

    private struct SemanticWorkBudget {
        private var remaining = ProjectIntegration.maximumSemanticWork

        mutating func consume(_ amount: Int, file: String) throws {
            guard amount >= 0, amount <= remaining else {
                throw SwiftPodsError(
                    "Xcode project exceeds the semantic integration work budget",
                    file: file,
                    hint: "Reduce duplicated targets, package products, build phases, or local package references")
            }
            remaining -= amount
        }
    }

    static func packageKey(_ object: PBXObject) -> String? {
        switch object.isa {
        case "XCRemoteSwiftPackageReference": object.string("repositoryURL").map { "package:" + PackageLocation.canonical($0) }
        // SwiftPods 0.2.2 and Xcode's Add Local button; SwiftPods now writes a file reference instead.
        case "XCLocalSwiftPackageReference": object.string("relativePath").map { "package:local:" + $0 }
        case "PBXFileReference" where object.string("lastKnownFileType") == "wrapper": object.string("path").map { "package:local:" + $0 }
        default: nil
        }
    }

    /// Local packages are file references to their folders; products of a package referenced that way name no package.
    static func isLocalPackage(_ object: PBXObject) -> Bool { object.isa == "PBXFileReference" }

    /// Targets that copy the product of one of `frameworks` into their Frameworks folder, as Unity's app embeds UnityFramework.
    static func embeddingTargets(_ project: XcodeProject, of frameworks: Set<String>) -> [String] {
        let targets = project.nativeTargets
        let products = Set(targets.filter { frameworks.contains($0.name) }.compactMap {
            project[$0.id]?.string("productReference")
        })
        guard !products.isEmpty else { return [] }
        let productBuildFiles: Set<String> = Set(project.objects.compactMap { id, object -> String? in
            guard object.isa == "PBXBuildFile",
                products.contains(object.string("fileRef") ?? "")
            else { return nil }
            return id
        })
        var embeddingPhase: [String: Bool] = [:]
        func embedsProduct(_ id: String) -> Bool {
            if let cached = embeddingPhase[id] { return cached }
            let result = project[id].map { phase in
                phase.isa == "PBXCopyFilesBuildPhase" && phase.string("dstSubfolderSpec") == "10"
                    && phase.strings("files").contains(where: productBuildFiles.contains)
            } ?? false
            embeddingPhase[id] = result
            return result
        }
        return targets.filter { target in
            (project[target.id]?.strings("buildPhases") ?? []).contains { id in
                embedsProduct(id)
            }
        }.map(\.name)
    }

    static func productKey(target: String, package: String, product: String) -> String {
        "product:\(target)|\(package)|\(product)"
    }

    static func dependencyKey(product: String) -> String { "build-dependency:" + product }

    static func scriptKey(target: String, name: String) -> String { "script:\(target)|\(name)" }
    static func frameworksKey(target: String) -> String { "frameworks-phase:\(target)" }
    static func settingsKey(path: String) -> String { "xcconfig:" + path }
    static func resourceKey(path: String) -> String { "resource:" + path }
    static func resourcesKey(target: String) -> String { "resources-phase:\(target)" }
    static func resourceFileKey(target: String, file: String) -> String { "resource-file:\(target)|\(file)" }

    /// Objects SwiftPods created, recognized because their identifiers match what they describe.
    static func ownedIdentifiers(_ project: XcodeProject) throws -> Set<String> {
        var budget = SemanticWorkBudget()
        var owned = Set<String>()
        func check(_ id: String, _ key: String?) {
            if let key, XcodeProject.identifier(key) == id { owned.insert(id) }
        }
        var localPackages: [String] = []
        for (id, object) in project.objects {
            switch object.isa {
            case "XCRemoteSwiftPackageReference", "XCLocalSwiftPackageReference": check(id, packageKey(object))
            case "PBXFileReference":
                check(id, object.string("path").map(settingsKey))
                check(id, object.string("path").map(resourceKey))
                if let key = packageKey(object), XcodeProject.identifier(key) == id {
                    owned.insert(id)
                    localPackages.append(key)
                }
            case "PBXGroup": check(id, groupKey)
            default: break
            }
        }
        for target in project.nativeTargets {
            let object = project[target.id] ?? [:]
            try budget.consume(
                object.strings("packageProductDependencies").count + object.strings("dependencies").count
                    + object.strings("buildPhases").count,
                file: project.file.path)
            let buildProducts = object.strings("dependencies").compactMap { id -> String? in
                guard project[id]?.isa == "PBXTargetDependency" else { return nil }
                return project[id]?.string("productRef")
            }
            for id in object.strings("packageProductDependencies") + buildProducts {
                guard let dependency = project[id], let product = dependency.string("productName") else { continue }
                if let package = dependency.string("package") {
                    check(id, project[package].flatMap(packageKey).map { productKey(target: target.name, package: $0, product: product) })
                } else {
                    try budget.consume(localPackages.count, file: project.file.path)
                    for package in localPackages {
                        check(id, productKey(target: target.name, package: package, product: product))
                    }
                }
            }
            for id in object.strings("buildPhases") {
                guard let phase = project[id] else { continue }
                if phase.isa == "PBXShellScriptBuildPhase", let name = phase.string("name"), name.hasPrefix(scriptPrefix) {
                    check(id, scriptKey(target: target.name, name: String(name.dropFirst(scriptPrefix.count))))
                } else if phase.isa == "PBXFrameworksBuildPhase" {
                    check(id, frameworksKey(target: target.name))
                } else if phase.isa == "PBXResourcesBuildPhase" {
                    check(id, resourcesKey(target: target.name))
                    try budget.consume(phase.strings("files").count, file: project.file.path)
                    for file in phase.strings("files") {
                        guard let reference = project[file]?.string("fileRef"), owned.contains(reference) else { continue }
                        check(file, resourceFileKey(target: target.name, file: reference))
                    }
                }
            }
        }
        for (id, object) in project.objects {
            guard let product = object.string("productRef"), owned.contains(product) else { continue }
            if object.isa == "PBXBuildFile" { check(id, "build-file:" + product) }
            if object.isa == "PBXTargetDependency" { check(id, dependencyKey(product: product)) }
        }
        return owned
    }

    /// Package references and product links SwiftPods did not create but would now manage.
    static func adoptable(_ project: XcodeProject, plan: ProjectPlan, owned: Set<String>) -> [String] {
        let keys = Set(plan.packages.map(\.key)).union(plan.managedPackageKeys)
        let references = project.objects.filter { id, object in
            !owned.contains(id) && packageKey(object).map(keys.contains) == true
        }.keys
        var result = Set(references)
        // Products of a local package referenced by its folder name no package; match them by name.
        let localProducts = references.contains { project[$0].map(isLocalPackage) == true } ? plan.managedLocalProducts : []
        var buildFilesByProduct: [String: [String]] = [:]
        for (file, object) in project.objects {
            if let product = object.string("productRef") { buildFilesByProduct[product, default: []].append(file) }
        }
        for (id, object) in project.objects where object.isa == "XCSwiftPackageProductDependency" && !owned.contains(id) {
            if let package = object.string("package") {
                guard references.contains(package) else { continue }
            } else {
                guard let name = object.string("productName"), localProducts.contains(name) else { continue }
            }
            result.insert(id)
            for file in buildFilesByProduct[id] ?? [] { result.insert(file) }
        }
        return result.sorted()
    }

    static func apply(
        _ plan: ProjectPlan, to project: inout XcodeProject, adopt: Bool,
        migrateLegacyCrashlyticsPaths: Bool = false
    ) throws -> [ProjectChange] {
        var owned = try ownedIdentifiers(project)
        let foreign = adoptable(project, plan: plan, owned: owned)
        if !foreign.isEmpty {
            let names = foreign.compactMap { project[$0] }.filter { packageKey($0) != nil }
                .compactMap { $0.string("repositoryURL") ?? $0.string("relativePath") ?? $0.string("path") }
            guard adopt else {
                throw SwiftPodsError(
                    "\(project.path.lastPathComponent) already references \(names.joined(separator: ", ")) without SwiftPods",
                    file: project.file.path,
                    hint: "Remove the package in Xcode, or run `swiftpods install --adopt` to let SwiftPods manage it; "
                        + "products of that package the Podfile does not declare are then unlinked")
            }
            owned.formUnion(foreign)
        }

        let nativeTargets = project.nativeTargets
        if let duplicate = Dictionary(grouping: nativeTargets, by: \.name).first(where: { $0.value.count > 1 }) {
            throw SwiftPodsError(
                "\(project.path.lastPathComponent) has more than one native target named `\(duplicate.key)`",
                file: project.file.path,
                hint: "Give each native target a unique name before running SwiftPods (IDs: "
                    + duplicate.value.map(\.id).sorted().joined(separator: ", ") + ")")
        }
        let targets = Dictionary(uniqueKeysWithValues: nativeTargets.map { ($0.name, $0) })
        for target in plan.targets where targets[target.name] == nil {
            throw SwiftPodsError(
                "\(project.path.lastPathComponent) has no target `\(target.name)`", file: project.file.path,
                hint: "Targets: " + project.nativeTargets.map(\.name).joined(separator: ", "))
        }

        var desired: [String: PBXObject] = [:]
        var desiredKeys: [String: String] = [:]
        var desiredIdentifierCollisions: [(String, String, String)] = []
        func put(_ key: String, _ object: PBXObject) -> String {
            let id = XcodeProject.identifier(key)
            if let previous = desiredKeys[id], previous != key {
                desiredIdentifierCollisions.append((id, previous, key))
            } else {
                desiredKeys[id] = key
            }
            desired[id] = object
            return id
        }
        let packageIDs = plan.packages.filter { !isLocalPackage($0.object) }.map { put($0.key, $0.object) }
        let localPackageIDs = plan.packages.filter { isLocalPackage($0.object) }.map { put($0.key, $0.object) }

        struct TargetEdits {
            var products: [String] = []
            var dependencies: [String] = []
            var buildFiles: [String] = []
            var scripts: [(String, ScriptPhase.Position)] = []
            var settings: String?
            var resources: [String] = []
        }
        var edits: [String: TargetEdits] = [:]
        var settingsFiles: [String] = []
        var resourceFiles: [String] = []
        var resourceFileSet = Set<String>()
        for target in plan.targets {
            var edit = TargetEdits()
            for product in target.products {
                var object: PBXObject = ["isa": "XCSwiftPackageProductDependency", "productName": .string(product.name)]
                if !isLocalPackage(product.package.object) { object["package"] = .string(XcodeProject.identifier(product.package.key)) }
                let id = put(productKey(target: target.name, package: product.package.key, product: product.name), object)
                if product.link {
                    edit.products.append(id)
                    edit.buildFiles.append(put("build-file:" + id, ["isa": "PBXBuildFile", "productRef": .string(id)]))
                } else {
                    // Xcode archives packageProductDependencies into native static libraries even without a
                    // Frameworks entry. A productRef target dependency schedules the SDK without archiving it.
                    edit.dependencies.append(put(dependencyKey(product: id), ["isa": "PBXTargetDependency", "productRef": .string(id)]))
                }
            }
            for phase in target.phases {
                let object: PBXObject = [
                    "isa": "PBXShellScriptBuildPhase", "alwaysOutOfDate": "1", "buildActionMask": "2147483647", "files": [],
                    "inputFileListPaths": .array(phase.inputFileLists.map(PBXValue.string)), "inputPaths": [],
                    "name": .string(scriptPrefix + phase.name),
                    "outputFileListPaths": .array(phase.outputFileLists.map(PBXValue.string)), "outputPaths": [],
                    "runOnlyForDeploymentPostprocessing": "0", "shellPath": "/bin/sh", "shellScript": .string(phase.script),
                    "showEnvVarsInLog": "0",
                ]
                edit.scripts.append((put(scriptKey(target: target.name, name: phase.name), object), phase.position))
            }
            if let path = target.settingsFile {
                edit.settings = put(
                    settingsKey(path: path),
                    [
                        "isa": "PBXFileReference", "lastKnownFileType": "text.xcconfig",
                        "name": .string((path as NSString).lastPathComponent), "path": .string(path),
                        "sourceTree": "SOURCE_ROOT",
                    ])
                settingsFiles.append(edit.settings!)
            }
            for path in target.resources {
                let file = put(resourceKey(path: path), [
                    "isa": "PBXFileReference", "lastKnownFileType": "wrapper.plug-in",
                    "name": .string((path as NSString).lastPathComponent), "path": .string(path), "sourceTree": "SOURCE_ROOT",
                ])
                if resourceFileSet.insert(file).inserted { resourceFiles.append(file) }
                edit.resources.append(put(resourceFileKey(target: target.name, file: file), ["isa": "PBXBuildFile", "fileRef": .string(file)]))
            }
            edits[target.name] = edit
        }
        let groupFiles = localPackageIDs + settingsFiles + resourceFiles
        let groupID = groupFiles.isEmpty ? nil : put(groupKey, [
            "isa": "PBXGroup", "children": .array(groupFiles.map(PBXValue.string)), "name": "SwiftPods",
            "sourceTree": "<group>",
        ])

        // Frameworks phases: reuse the target's own, otherwise SwiftPods owns one for its links.
        var frameworksPhases: [String: String] = [:]
        for (name, edit) in edits where !edit.buildFiles.isEmpty {
            let target = targets[name]!.id
            let existing = (project[target]?.strings("buildPhases") ?? []).first {
                project[$0]?.isa == "PBXFrameworksBuildPhase" && !owned.contains($0)
            }
            frameworksPhases[name] = existing ?? put(frameworksKey(target: name), [
                "isa": "PBXFrameworksBuildPhase", "buildActionMask": "2147483647", "files": [],
                "runOnlyForDeploymentPostprocessing": "0",
            ])
        }

        // Resource bundles go into the target's own resources phase when it has one.
        var resourcesPhases: [String: String] = [:]
        for (name, edit) in edits where !edit.resources.isEmpty {
            let target = targets[name]!.id
            let existing = (project[target]?.strings("buildPhases") ?? []).first {
                project[$0]?.isa == "PBXResourcesBuildPhase" && !owned.contains($0)
            }
            resourcesPhases[name] = existing ?? put(resourcesKey(target: name), [
                "isa": "PBXResourcesBuildPhase", "buildActionMask": "2147483647", "files": [],
                "runOnlyForDeploymentPostprocessing": "0",
            ])
        }

        // Settings files need the base configuration slot, or an include from the file already there.
        let groupParents = groupParentIndex(project)
        for (name, edit) in edits {
            guard let settings = edit.settings, let targetPlan = plan.targets.first(where: { $0.name == name }), targetPlan.hasSettings,
                let path = targetPlan.settingsFile
            else { continue }
            for (configuration, id) in project.configurations(of: targets[name]!.id) {
                guard let base = project[id]?.string("baseConfigurationReference"), base != settings, !owned.contains(base) else { continue }
                if !includes(project, base: base, settings: path, parents: groupParents) {
                    let include = relativeInclude(project, base: base, settings: path, parents: groupParents)
                    throw SwiftPodsError(
                        "Target `\(name)` already uses \(project[base]?.string("path") ?? base) as its \(configuration) base configuration",
                        file: project.file.path,
                        hint: "Add this line to that file: #include? \"\(include)\"")
                }
            }
        }

        guard desiredIdentifierCollisions.isEmpty else {
            let details = desiredIdentifierCollisions.map { "\($0.0) (`\($0.1)` and `\($0.2)`)" }.joined(separator: ", ")
            throw SwiftPodsError(
                "SwiftPods-generated project objects have colliding identifiers: " + details,
                file: project.file.path,
                hint: "Rename one of the colliding declarations; SwiftPods left the project unchanged")
        }

        // Deterministic identifiers are part of SwiftPods' ownership contract, but they are still only 96-bit PBX
        // identifiers. Never overwrite an unrelated object if a hand-edited or hostile project already uses one of
        // them. Adopted objects have explicitly joined `owned`; all other collisions must fail before any mutation.
        let collisions = desired.keys.sorted().compactMap { id -> String? in
            guard let existing = project[id], !owned.contains(id) else { return nil }
            return "\(id) (\(existing.isa ?? "unknown object"))"
        }
        guard collisions.isEmpty else {
            throw SwiftPodsError(
                "\(project.path.lastPathComponent) contains project objects whose identifiers collide with SwiftPods: "
                    + collisions.joined(separator: ", "),
                file: project.file.path,
                hint: "Give the listed non-SwiftPods objects new identifiers before running install; SwiftPods left the project unchanged")
        }

        let before = project.objects
        if migrateLegacyCrashlyticsPaths {
            let old = "${PROJECT_DIR}/Pods/FirebaseCrashlytics/"
            let replacement = "${BUILD_DIR%/Build/*}/SourcePackages/checkouts/firebase-ios-sdk/Crashlytics/"
            for (id, object) in project.objects where object.isa == "PBXShellScriptBuildPhase" {
                guard let script = object.string("shellScript"), script.contains(old) else { continue }
                var migrated = object
                migrated["shellScript"] = .string(script.replacingOccurrences(of: old, with: replacement))
                project[id] = migrated
            }
        }
        project.remove(Set(owned.filter { desired[$0] == nil }))
        for (id, object) in desired { project[id] = object }

        var root = project.project
        root["packageReferences"] = .array(
            (root["packageReferences"]?.array ?? []).filter { !owned.contains($0.string ?? "") && !packageIDs.contains($0.string ?? "") }
                + packageIDs.map(PBXValue.string))
        if root["packageReferences"]?.array?.isEmpty == true { root["packageReferences"] = nil }
        if let mainGroup = root.string("mainGroup"), var main = project[mainGroup] {
            var children = main.strings("children").filter { !owned.contains($0) && $0 != groupID }
            if let groupID { children.append(groupID) }
            main["children"] = .array(children.map(PBXValue.string))
            project[mainGroup] = main
        }
        project.project = root

        for target in project.nativeTargets {
            guard var object = project[target.id] else { continue }
            let edit = edits[target.name] ?? TargetEdits()
            let existing = before[target.id]?.strings("packageProductDependencies") ?? []
            let products = existing.filter { !owned.contains($0) } + edit.products
            // Leave no empty list behind where SwiftPods created the only entries.
            let keep = !products.isEmpty || (object["packageProductDependencies"] != nil && existing.allSatisfy { !owned.contains($0) })
            object["packageProductDependencies"] = keep ? .array(products.map(PBXValue.string)) : nil

            let existingDependencies = before[target.id]?.strings("dependencies") ?? []
            let dependencies = existingDependencies.filter { !owned.contains($0) } + edit.dependencies
            let keepDependencies = !dependencies.isEmpty || before[target.id]?["dependencies"] != nil
            object["dependencies"] = keepDependencies ? .array(dependencies.map(PBXValue.string)) : nil

            var phases = object.strings("buildPhases").filter {
                !owned.contains($0) || $0 == frameworksPhases[target.name] || $0 == resourcesPhases[target.name]
            }
            if let frameworks = frameworksPhases[target.name], !phases.contains(frameworks) {
                let index = phases.firstIndex { project[$0]?.isa == "PBXSourcesBuildPhase" }.map { $0 + 1 } ?? phases.endIndex
                phases.insert(frameworks, at: index)
            }
            if let resources = resourcesPhases[target.name], !phases.contains(resources) {
                let index = phases.firstIndex { project[$0]?.isa == "PBXFrameworksBuildPhase" }.map { $0 + 1 } ?? phases.endIndex
                phases.insert(resources, at: index)
            }
            let sources = phases.firstIndex { project[$0]?.isa == "PBXSourcesBuildPhase" }
            let before = edit.scripts.filter { $0.1 == .beforeCompile }.map(\.0)
            let after = edit.scripts.filter { $0.1 == .afterCompile }.map(\.0)
            let any = edit.scripts.filter { $0.1 == .any }.map(\.0)
            if let sources {
                phases.insert(contentsOf: after, at: sources + 1)
                phases.insert(contentsOf: before, at: sources)
            } else {
                phases += before + after
            }
            phases += any
            object["buildPhases"] = .array(phases.map(PBXValue.string))
            project[target.id] = object

            if let frameworks = frameworksPhases[target.name], var phase = project[frameworks] {
                let files = phase.strings("files").filter { !owned.contains($0) } + edit.buildFiles
                phase["files"] = .array(files.map(PBXValue.string))
                project[frameworks] = phase
            }
            if let resources = resourcesPhases[target.name], var phase = project[resources] {
                let files = phase.strings("files").filter { !owned.contains($0) } + edit.resources
                phase["files"] = .array(files.map(PBXValue.string))
                project[resources] = phase
            }
            for id in project.configurations(of: target.id).values {
                guard var configuration = project[id] else { continue }
                let base = configuration.string("baseConfigurationReference")
                if let settings = edit.settings, base == nil || owned.contains(base!) || base == settings {
                    configuration["baseConfigurationReference"] = .string(settings)
                } else if let base, owned.contains(base), project[base] == nil {
                    configuration["baseConfigurationReference"] = nil
                }
                project[id] = configuration
            }
        }
        let result = changes(before: before, after: project.objects)
        // An empty report must mean an unchanged file, whatever else was rewritten.
        return result.isEmpty && project.hasChanges ? [ProjectChange(kind: .updated, subject: "project file")] : result
    }

    private struct ChangeOwners {
        var productTargets: [String: String] = [:]
        var buildPhaseTargets: [String: String] = [:]

        init(_ objects: [String: PBXObject]) {
            for object in objects.values {
                guard let name = object.string("name") else { continue }
                if object.isa == "PBXNativeTarget" {
                    let buildProducts = object.strings("dependencies").compactMap { objects[$0]?.string("productRef") }
                    for product in object.strings("packageProductDependencies") + buildProducts where productTargets[product] == nil {
                        productTargets[product] = name
                    }
                }
                for phase in object.strings("buildPhases") where buildPhaseTargets[phase] == nil {
                    buildPhaseTargets[phase] = name
                }
            }
        }
    }

    private static func describe(_ id: String, in objects: [String: PBXObject], owners: ChangeOwners) -> String? {
        guard let object = objects[id] else { return nil }
        switch object.isa {
        case "XCRemoteSwiftPackageReference": return object.string("repositoryURL").map { "package " + $0 }
        case "XCLocalSwiftPackageReference": return object.string("relativePath").map { "local package " + $0 }
        case "XCSwiftPackageProductDependency":
            return object.string("productName").map {
                "product \($0)" + (owners.productTargets[id].map { " in " + $0 } ?? "")
            }
        case "PBXShellScriptBuildPhase": return object.string("name").map { "script phase " + $0 }
        case "PBXFileReference":
            let kind = ["text.xcconfig": "settings file ", "wrapper.plug-in": "resource ", "wrapper": "local package "][object.string("lastKnownFileType") ?? ""] ?? "file "
            return object.string("path").map { kind + $0 }
        default: return nil
        }
    }

    private static func changes(before: [String: PBXObject], after: [String: PBXObject]) -> [ProjectChange] {
        var added: [String] = []
        var removed: [String] = []
        var updated: [String] = []
        var reordered: [String] = []
        let beforeOwners = ChangeOwners(before)
        let afterOwners = ChangeOwners(after)
        let replaced = Set(before.keys).symmetricDifference(after.keys)
        for id in Set(before.keys).union(after.keys) {
            switch (before[id], after[id]) {
            case (nil, _?): describe(id, in: after, owners: afterOwners).map { added.append($0) }
            case (_?, nil): describe(id, in: before, owners: beforeOwners).map { removed.append($0) }
            case (let old?, let new?) where old != new:
                if let subject = describe(id, in: after, owners: afterOwners) {
                    updated.append(subject)
                } else {
                    reordered += reorderedLists(id, old, new, ignoring: replaced, owners: afterOwners)
                }
            default: break
            }
        }
        // An object replaced under SwiftPods' identifier (adoption) is one update, not a removal and an addition.
        let adopted = Set(added).intersection(removed)
        if !adopted.isEmpty {
            added.removeAll { adopted.contains($0) }
            removed.removeAll { adopted.contains($0) }
            updated.append(contentsOf: adopted)
        }
        let result = added.map { ProjectChange(kind: .added, subject: $0) } + removed.map { ProjectChange(kind: .removed, subject: $0) }
            + Set(updated).map { ProjectChange(kind: .updated, subject: $0) } + reordered.map { ProjectChange(kind: .reordered, subject: $0) }
        return result.sorted { ($0.kind.rawValue, $0.subject) < ($1.kind.rawValue, $1.subject) }
    }

    /// Lists of a container, such as a target's products, whose entries only moved. Entries added or removed are set aside:
    /// they are reported with their own objects.
    private static func reorderedLists(
        _ id: String, _ old: PBXObject, _ new: PBXObject, ignoring replaced: Set<String>, owners: ChangeOwners
    ) -> [String] {
        old.keys.sorted().compactMap { key in
            guard let before = old[key]?.strings?.filter({ !replaced.contains($0) }),
                let after = new[key]?.strings?.filter({ !replaced.contains($0) }),
                before != after, before.sorted() == after.sorted()
            else { return nil }
            var noun = ["packageReferences": "packages", "packageProductDependencies": "products", "buildPhases": "build phases", "children": "files"][key] ?? key
            var owner = new.string("name") ?? new.string("path") ?? "the project"
            if let isa = new.isa, isa.hasSuffix("BuildPhase") {
                noun = ["PBXFrameworksBuildPhase": "frameworks", "PBXResourcesBuildPhase": "resources"][isa] ?? "files"
                owner = owners.buildPhaseTargets[id] ?? owner
            }
            return noun + " in " + owner
        }
    }

    /// Builds group ownership once. Ambiguous parents are kept as such and fail closed only when their path is used.
    private static func groupParentIndex(_ project: XcodeProject) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for (id, object) in project.objects where object.isa == "PBXGroup" {
            for child in object.strings("children") { result[child, default: []].append(id) }
        }
        return result
    }

    /// The directory a file reference's path is relative to.
    private static func location(_ project: XcodeProject, of id: String, parents: [String: [String]]) -> URL? {
        var visited: Set<String> = []
        return location(project, of: id, parents: parents, visited: &visited, depth: 0)
    }

    private static func location(
        _ project: XcodeProject, of id: String, parents: [String: [String]], visited: inout Set<String>, depth: Int
    ) -> URL? {
        guard depth <= 256, visited.insert(id).inserted,
            let object = project[id], let path = object.string("path")
        else { return nil }
        switch object.string("sourceTree") {
        case "SOURCE_ROOT": return project.sourceRoot.appendingPathComponent(path)
        case "<absolute>": return URL(fileURLWithPath: path)
        case "<group>", nil:
            let owners = parents[id] ?? []
            guard owners.count <= 1 else { return nil }
            guard let parent = owners.first else { return project.sourceRoot.appendingPathComponent(path) }
            let directory = groupDirectory(
                project, parent, parents: parents, visited: &visited, depth: depth + 1)
            return directory?.appendingPathComponent(path)
        default: return nil
        }
    }

    private static func groupDirectory(
        _ project: XcodeProject, _ id: String, parents: [String: [String]], visited: inout Set<String>, depth: Int
    ) -> URL? {
        guard depth <= 256, visited.insert(id).inserted, let object = project[id] else { return nil }
        let owners = parents[id] ?? []
        guard owners.count <= 1 else { return nil }
        let parent = owners.first
        let parentDirectory: URL?
        if let parent {
            parentDirectory = groupDirectory(
                project, parent, parents: parents, visited: &visited, depth: depth + 1)
        } else {
            parentDirectory = project.sourceRoot
        }
        guard let path = object.string("path") else { return parentDirectory }
        switch object.string("sourceTree") {
        case "SOURCE_ROOT": return project.sourceRoot.appendingPathComponent(path)
        case "<absolute>": return URL(fileURLWithPath: path)
        case "<group>", nil: return parentDirectory?.appendingPathComponent(path)
        default: return nil
        }
    }

    private static func relativeInclude(
        _ project: XcodeProject, base: String, settings: String, parents: [String: [String]]
    ) -> String {
        guard let file = location(project, of: base, parents: parents) else { return settings }
        return Paths.relative(from: file.deletingLastPathComponent(), to: project.sourceRoot.appendingPathComponent(settings))
    }

    private static func includes(
        _ project: XcodeProject, base: String, settings: String, parents: [String: [String]]
    ) -> Bool {
        guard let file = location(project, of: base, parents: parents), let text = readConfiguration(file) else { return false }
        let expected = relativeInclude(project, base: base, settings: settings, parents: parents)
        return text.split(separator: "\n").contains { includedPath(in: $0) == expected }
    }

    /// Parses exactly one xcconfig include directive. Comments may follow the operand, but cannot supply it.
    private static func includedPath(in line: Substring) -> String? {
        var remainder = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
        guard remainder.hasPrefix("#include") else { return nil }
        remainder.removeFirst("#include".count)
        if remainder.first == "?" { remainder.removeFirst() }
        remainder = remainder.trimmingCharacters(in: .whitespaces)
        guard remainder.first == "\"" else { return nil }
        remainder.removeFirst()

        var path = ""
        var escaped = false
        var closing: String.Index?
        for index in remainder.indices {
            let character = remainder[index]
            if escaped {
                path.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                closing = index
                break
            } else {
                path.append(character)
            }
        }
        guard !escaped, let closing else { return nil }
        let suffix = remainder[remainder.index(after: closing)...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard suffix.isEmpty || suffix.hasPrefix("//")
            || (suffix.hasPrefix("/*") && suffix.hasSuffix("*/") && suffix.dropFirst(2).dropLast(2).range(of: "*/") == nil)
        else { return nil }
        return path
    }

    /// Base configurations are project-controlled input too. Resolve a legitimate symlink once, then open the
    /// resulting regular file without following another final link or blocking on a special file.
    private static func readConfiguration(_ file: URL) -> String? {
        let maximumBytes = 8 * 1_024 * 1_024
        var source = stat()
        guard file.path.withCString({ lstat($0, &source) }) == 0 else { return nil }
        let resolved: URL
        if source.st_mode & S_IFMT == S_IFLNK {
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
            let result = buffer.withUnsafeMutableBufferPointer { output in
                file.path.withCString { realpath($0, output.baseAddress) }
            }
            guard result != nil else { return nil }
            let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            resolved = URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self))
            var current = stat()
            guard file.path.withCString({ lstat($0, &current) }) == 0,
                current.st_dev == source.st_dev, current.st_ino == source.st_ino,
                current.st_mode == source.st_mode, current.st_size == source.st_size,
                current.st_mtimespec.tv_sec == source.st_mtimespec.tv_sec,
                current.st_mtimespec.tv_nsec == source.st_mtimespec.tv_nsec,
                current.st_ctimespec.tv_sec == source.st_ctimespec.tv_sec,
                current.st_ctimespec.tv_nsec == source.st_ctimespec.tv_nsec
            else { return nil }
        } else {
            guard source.st_mode & S_IFMT == S_IFREG else { return nil }
            resolved = file
        }
        let descriptor = resolved.path.withCString { open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK) }
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var initial = stat()
        guard fstat(descriptor, &initial) == 0, initial.st_mode & S_IFMT == S_IFREG,
            initial.st_size >= 0, initial.st_size <= maximumBytes
        else { return nil }
        var data = Data()
        do {
            while let chunk = try handle.read(upToCount: min(1 << 20, maximumBytes + 1 - data.count)), !chunk.isEmpty {
                data.append(chunk)
                guard data.count <= maximumBytes else { return nil }
            }
        } catch {
            return nil
        }
        var final = stat()
        guard fstat(descriptor, &final) == 0, final.st_dev == initial.st_dev,
            final.st_ino == initial.st_ino, final.st_mode == initial.st_mode,
            final.st_nlink == initial.st_nlink, final.st_size == initial.st_size,
            final.st_mtimespec.tv_sec == initial.st_mtimespec.tv_sec,
            final.st_mtimespec.tv_nsec == initial.st_mtimespec.tv_nsec,
            final.st_ctimespec.tv_sec == initial.st_ctimespec.tv_sec,
            final.st_ctimespec.tv_nsec == initial.st_ctimespec.tv_nsec,
            data.count == Int(initial.st_size)
        else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

enum Paths {
    /// A relative path from directory `from` to `to`, both absolute.
    static func relative(from: URL, to: URL) -> String {
        let base = from.standardizedFileURL.pathComponents
        let target = to.standardizedFileURL.pathComponents
        var common = 0
        while common < base.count && common < target.count && base[common] == target[common] { common += 1 }
        let parts = Array(repeating: "..", count: base.count - common) + target[common...]
        return parts.isEmpty ? "." : parts.joined(separator: "/")
    }
}
