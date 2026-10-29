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

    struct TargetPlan {
        let name: String
        let products: [Product]
        let scripts: [ScriptPhase]
        /// The generated settings file, relative to the project directory.
        let settingsFile: String?
        /// Resource bundles copied into the target's product, relative to the project directory.
        let resources: [String]
    }

    var packages: [PackageReference] = []
    var targets: [TargetPlan] = []
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

    static func packageKey(_ object: PBXObject) -> String? {
        switch object.isa {
        case "XCRemoteSwiftPackageReference": object.string("repositoryURL").map { "package:" + PackageLocation.canonical($0) }
        case "XCLocalSwiftPackageReference": object.string("relativePath").map { "package:local:" + $0 }
        default: nil
        }
    }

    static func productKey(target: String, package: String, product: String) -> String {
        "product:\(target)|\(package)|\(product)"
    }

    static func scriptKey(target: String, name: String) -> String { "script:\(target)|\(name)" }
    static func frameworksKey(target: String) -> String { "frameworks-phase:\(target)" }
    static func settingsKey(path: String) -> String { "xcconfig:" + path }
    static func resourceKey(path: String) -> String { "resource:" + path }
    static func resourcesKey(target: String) -> String { "resources-phase:\(target)" }
    static func resourceFileKey(target: String, file: String) -> String { "resource-file:\(target)|\(file)" }

    /// Objects SwiftPods created, recognized because their identifiers match what they describe.
    static func ownedIdentifiers(_ project: XcodeProject) -> Set<String> {
        var owned = Set<String>()
        func check(_ id: String, _ key: String?) {
            if let key, XcodeProject.identifier(key) == id { owned.insert(id) }
        }
        for (id, object) in project.objects {
            switch object.isa {
            case "XCRemoteSwiftPackageReference", "XCLocalSwiftPackageReference": check(id, packageKey(object))
            case "PBXFileReference":
                check(id, object.string("path").map(settingsKey))
                check(id, object.string("path").map(resourceKey))
            case "PBXGroup": check(id, groupKey)
            default: break
            }
        }
        for target in project.nativeTargets {
            let object = project[target.id] ?? [:]
            for id in object.strings("packageProductDependencies") {
                guard let dependency = project[id], let product = dependency.string("productName"),
                    let package = dependency.string("package").flatMap({ project[$0] }).flatMap(packageKey)
                else { continue }
                check(id, productKey(target: target.name, package: package, product: product))
            }
            for id in object.strings("buildPhases") {
                guard let phase = project[id] else { continue }
                if phase.isa == "PBXShellScriptBuildPhase", let name = phase.string("name"), name.hasPrefix(scriptPrefix) {
                    check(id, scriptKey(target: target.name, name: String(name.dropFirst(scriptPrefix.count))))
                } else if phase.isa == "PBXFrameworksBuildPhase" {
                    check(id, frameworksKey(target: target.name))
                } else if phase.isa == "PBXResourcesBuildPhase" {
                    check(id, resourcesKey(target: target.name))
                    for file in phase.strings("files") {
                        guard let reference = project[file]?.string("fileRef"), owned.contains(reference) else { continue }
                        check(file, resourceFileKey(target: target.name, file: reference))
                    }
                }
            }
        }
        for (id, object) in project.objects where object.isa == "PBXBuildFile" {
            if let product = object.string("productRef"), owned.contains(product) { check(id, "build-file:" + product) }
        }
        return owned
    }

    /// Package references and product links SwiftPods did not create but would now manage.
    static func adoptable(_ project: XcodeProject, plan: ProjectPlan, owned: Set<String>) -> [String] {
        let keys = Set(plan.packages.map(\.key))
        let references = project.objects.filter { id, object in
            !owned.contains(id) && packageKey(object).map(keys.contains) == true
        }.keys
        var result = Set(references)
        for (id, object) in project.objects where object.isa == "XCSwiftPackageProductDependency" {
            guard let package = object.string("package"), references.contains(package) else { continue }
            result.insert(id)
            for (file, fileObject) in project.objects where fileObject.string("productRef") == id { result.insert(file) }
        }
        return result.sorted()
    }

    static func apply(_ plan: ProjectPlan, to project: inout XcodeProject, adopt: Bool) throws -> [ProjectChange] {
        var owned = ownedIdentifiers(project)
        let foreign = adoptable(project, plan: plan, owned: owned)
        if !foreign.isEmpty {
            let names = foreign.compactMap { project[$0] }.compactMap { $0.string("repositoryURL") ?? $0.string("relativePath") }
            guard adopt else {
                throw SwiftPodsError(
                    "\(project.path.lastPathComponent) already references \(names.joined(separator: ", ")) without SwiftPods",
                    file: project.file.path,
                    hint: "Remove the package in Xcode, or run `swiftpods install --adopt` to let SwiftPods manage it; "
                        + "products of that package the Podfile does not declare are then unlinked")
            }
            owned.formUnion(foreign)
        }

        let targets = Dictionary(project.nativeTargets.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        for target in plan.targets where targets[target.name] == nil {
            throw SwiftPodsError(
                "\(project.path.lastPathComponent) has no target `\(target.name)`", file: project.file.path,
                hint: "Targets: " + project.nativeTargets.map(\.name).joined(separator: ", "))
        }

        var desired: [String: PBXObject] = [:]
        func put(_ key: String, _ object: PBXObject) -> String {
            let id = XcodeProject.identifier(key)
            desired[id] = object
            return id
        }
        let packageIDs = plan.packages.map { put($0.key, $0.object) }

        struct TargetEdits {
            var products: [String] = []
            var buildFiles: [String] = []
            var scripts: [(String, ScriptPhase.Position)] = []
            var settings: String?
            var resources: [String] = []
        }
        var edits: [String: TargetEdits] = [:]
        var settingsFiles: [String] = []
        var resourceFiles: [String] = []
        for target in plan.targets {
            var edit = TargetEdits()
            for product in target.products {
                let id = put(
                    productKey(target: target.name, package: product.package.key, product: product.name),
                    [
                        "isa": "XCSwiftPackageProductDependency", "package": .string(XcodeProject.identifier(product.package.key)),
                        "productName": .string(product.name),
                    ])
                edit.products.append(id)
                if product.link {
                    edit.buildFiles.append(put("build-file:" + id, ["isa": "PBXBuildFile", "productRef": .string(id)]))
                }
            }
            for script in target.scripts {
                var object: PBXObject = [
                    "isa": "PBXShellScriptBuildPhase", "buildActionMask": "2147483647", "files": [],
                    "inputFileListPaths": .array(script.inputFileLists.map(PBXValue.string)),
                    "inputPaths": .array(script.inputFiles.map(PBXValue.string)),
                    "name": .string(scriptPrefix + script.name),
                    "outputFileListPaths": .array(script.outputFileLists.map(PBXValue.string)),
                    "outputPaths": .array(script.outputFiles.map(PBXValue.string)),
                    "runOnlyForDeploymentPostprocessing": "0", "shellPath": .string(script.shellPath),
                    "shellScript": .string(script.script),
                ]
                if !script.showEnvironmentInLog { object["showEnvVarsInLog"] = "0" }
                if !script.basedOnDependencyAnalysis { object["alwaysOutOfDate"] = "1" }
                edit.scripts.append((put(scriptKey(target: target.name, name: script.name), object), script.position))
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
                if !resourceFiles.contains(file) { resourceFiles.append(file) }
                edit.resources.append(put(resourceFileKey(target: target.name, file: file), ["isa": "PBXBuildFile", "fileRef": .string(file)]))
            }
            edits[target.name] = edit
        }
        let groupFiles = settingsFiles + resourceFiles
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
        for (name, edit) in edits {
            guard let settings = edit.settings, let path = plan.targets.first(where: { $0.name == name })?.settingsFile else { continue }
            for (configuration, id) in project.configurations(of: targets[name]!.id) {
                guard let base = project[id]?.string("baseConfigurationReference"), base != settings, !owned.contains(base) else { continue }
                if !includes(project, base: base, settings: path) {
                    throw SwiftPodsError(
                        "Target `\(name)` already uses \(project[base]?.string("path") ?? base) as its \(configuration) base configuration",
                        file: project.file.path,
                        hint: "Add this line to that file: #include? \"\(relativeInclude(project, base: base, settings: path))\"")
                }
            }
        }

        let before = project.objects
        for id in owned where desired[id] == nil { project.remove(id) }
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

    private static func describe(_ id: String, in objects: [String: PBXObject]) -> String? {
        guard let object = objects[id] else { return nil }
        switch object.isa {
        case "XCRemoteSwiftPackageReference": return object.string("repositoryURL").map { "package " + $0 }
        case "XCLocalSwiftPackageReference": return object.string("relativePath").map { "local package " + $0 }
        case "XCSwiftPackageProductDependency":
            let target = objects.values.first { $0.isa == "PBXNativeTarget" && $0.strings("packageProductDependencies").contains(id) }
            return object.string("productName").map { "product \($0)" + (target?.string("name").map { " in " + $0 } ?? "") }
        case "PBXShellScriptBuildPhase": return object.string("name").map { "script phase " + $0 }
        case "PBXFileReference":
            let kind = ["text.xcconfig": "settings file ", "wrapper.plug-in": "resource "][object.string("lastKnownFileType") ?? ""] ?? "file "
            return object.string("path").map { kind + $0 }
        default: return nil
        }
    }

    private static func changes(before: [String: PBXObject], after: [String: PBXObject]) -> [ProjectChange] {
        var added: [String] = []
        var removed: [String] = []
        var updated: [String] = []
        var reordered: [String] = []
        let replaced = Set(before.keys).symmetricDifference(after.keys)
        for id in Set(before.keys).union(after.keys) {
            switch (before[id], after[id]) {
            case (nil, _?): describe(id, in: after).map { added.append($0) }
            case (_?, nil): describe(id, in: before).map { removed.append($0) }
            case (let old?, let new?) where old != new:
                if let subject = describe(id, in: after) {
                    updated.append(subject)
                } else {
                    reordered += reorderedLists(id, old, new, ignoring: replaced, in: after)
                }
            default: break
            }
        }
        // An object replaced under SwiftPods' identifier (adoption) is one update, not a removal and an addition.
        for subject in Set(added).intersection(removed) {
            added.removeAll { $0 == subject }
            removed.removeAll { $0 == subject }
            updated.append(subject)
        }
        let result = added.map { ProjectChange(kind: .added, subject: $0) } + removed.map { ProjectChange(kind: .removed, subject: $0) }
            + Set(updated).map { ProjectChange(kind: .updated, subject: $0) } + reordered.map { ProjectChange(kind: .reordered, subject: $0) }
        return result.sorted { ($0.kind.rawValue, $0.subject) < ($1.kind.rawValue, $1.subject) }
    }

    /// Lists of a container, such as a target's products, whose entries only moved. Entries added or removed are set aside:
    /// they are reported with their own objects.
    private static func reorderedLists(
        _ id: String, _ old: PBXObject, _ new: PBXObject, ignoring replaced: Set<String>, in objects: [String: PBXObject]
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
                owner = objects.values.first { $0.strings("buildPhases").contains(id) }?.string("name") ?? owner
            }
            return noun + " in " + owner
        }
    }

    /// The directory a file reference's path is relative to.
    private static func location(_ project: XcodeProject, of id: String) -> URL? {
        guard let object = project[id], let path = object.string("path") else { return nil }
        switch object.string("sourceTree") {
        case "SOURCE_ROOT": return project.sourceRoot.appendingPathComponent(path)
        case "<absolute>": return URL(fileURLWithPath: path)
        case "<group>":
            guard let parent = project.objects.first(where: { $0.value.isa == "PBXGroup" && $0.value.strings("children").contains(id) })?.key
            else { return project.sourceRoot.appendingPathComponent(path) }
            let directory = location(project, of: parent) ?? groupDirectory(project, parent)
            return directory?.appendingPathComponent(path)
        default: return nil
        }
    }

    private static func groupDirectory(_ project: XcodeProject, _ id: String) -> URL? {
        guard let object = project[id] else { return nil }
        if object.string("path") != nil { return location(project, of: id) }
        guard let parent = project.objects.first(where: { $0.value.isa == "PBXGroup" && $0.value.strings("children").contains(id) })?.key
        else { return project.sourceRoot }
        return groupDirectory(project, parent)
    }

    private static func relativeInclude(_ project: XcodeProject, base: String, settings: String) -> String {
        guard let file = location(project, of: base) else { return settings }
        return Paths.relative(from: file.deletingLastPathComponent(), to: project.sourceRoot.appendingPathComponent(settings))
    }

    private static func includes(_ project: XcodeProject, base: String, settings: String) -> Bool {
        guard let file = location(project, of: base), let text = try? String(contentsOf: file, encoding: .utf8) else { return false }
        let expected = relativeInclude(project, base: base, settings: settings)
        return text.split(separator: "\n").contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("#include") && trimmed.contains("\"\(expected)\"")
        }
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
