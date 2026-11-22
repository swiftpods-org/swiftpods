import Foundation
import SwiftPodsXcode

/// Removes what CocoaPods, or SwiftPods 0.1, added to a project, so migrating does not need a working CocoaPods.
enum CocoaPodsIntegration {
    private static let phasePrefixes = ["[CP] ", "[CP-User] ", "📦 ", ProjectIntegration.scriptPrefix]

    private static func isPodsFile(_ object: PBXObject) -> Bool {
        let path = object.string("path") ?? ""
        let name = object.string("name") ?? (path as NSString).lastPathComponent
        return path.contains("Pods/Target Support Files/") || path == "Pods/Pods.xcodeproj" || path.hasSuffix("/Pods/Pods.xcodeproj")
            || (name.hasPrefix("Pods-") && name.hasSuffix(".xcconfig"))
            || (name.hasPrefix("Pods_") && name.hasSuffix(".framework"))
            || (name.hasPrefix("libPods-") && name.hasSuffix(".a"))
    }

    static func remove(from project: inout XcodeProject) throws -> [ProjectChange] {
        let owned = try ProjectIntegration.ownedIdentifiers(project)
        var removed = Set<String>()
        var changes: [ProjectChange] = []

        let files = Set(project.objects.filter { $0.value.isa == "PBXFileReference" && isPodsFile($0.value) }.keys)
        removed.formUnion(files)
        let proxies = Set(project.objects.filter { _, object in
            object.isa == "PBXContainerItemProxy"
                && (files.contains(object.string("containerPortal") ?? "") || object.string("remoteInfo")?.hasPrefix("Pods-") == true)
        }.keys)
        removed.formUnion(proxies)
        // With Pods.xcodeproj as a subproject, the products it builds (libPods-App.a, Pods_App.framework) are
        // reference proxies in a product group listed by the project's `projectReferences`.
        let productGroups = Set((project.project["projectReferences"]?.array ?? []).compactMap { entry -> String? in
            guard let reference = entry.dictionary, files.contains(reference["ProjectRef"]?.string ?? "") else { return nil }
            return reference["ProductGroup"]?.string
        })
        let referenceProxies = Set(project.objects.filter { _, object in
            object.isa == "PBXReferenceProxy" && proxies.contains(object.string("remoteRef") ?? "")
        }.keys)
        removed.formUnion(productGroups)
        removed.formUnion(referenceProxies)
        let products = files.union(referenceProxies)
        removed.formUnion(project.objects.filter { $0.value.isa == "PBXBuildFile" && products.contains($0.value.string("fileRef") ?? "") }.keys)

        for target in project.nativeTargets {
            let object = project[target.id] ?? [:]
            for id in object.strings("buildPhases") where !owned.contains(id) {
                guard let phase = project[id], phase.isa == "PBXShellScriptBuildPhase", let name = phase.string("name"),
                    phasePrefixes.contains(where: name.hasPrefix)
                else { continue }
                removed.insert(id)
                changes.append(ProjectChange(kind: .removed, subject: "script phase \(name) in \(target.name)"))
            }
            for id in object.strings("dependencies") {
                guard let dependency = project[id] else { continue }
                if dependency.string("name")?.hasPrefix("Pods-") == true || proxies.contains(dependency.string("targetProxy") ?? "") {
                    removed.insert(id)
                    changes.append(ProjectChange(
                        kind: .removed, subject: "target dependency \(dependency.string("name") ?? id) in \(target.name)"))
                }
            }
        }
        for id in files.union(referenceProxies).sorted() {
            changes.append(ProjectChange(kind: .removed, subject: "file " + (project[id]?.string("path") ?? id)))
        }

        // Compute groups that become empty before mutating the graph, then remove every
        // CocoaPods-owned object and every array reference in one graph pass.
        removed.formUnion(project.objects.compactMap { id, object in
            guard object.isa == "PBXGroup",
                (object.string("name") ?? object.string("path")) == "Pods",
                object.strings("children").allSatisfy(removed.contains)
            else { return nil }
            return id
        })
        project.remove(removed)

        // `remove` took the Pods project's entry out of `projectReferences`; Xcode writes no empty list.
        var root = project.project
        if root["projectReferences"]?.array?.isEmpty == true {
            root["projectReferences"] = nil
            project.project = root
        }
        for (id, object) in project.objects where object.isa == "XCBuildConfiguration" {
            var configuration = object
            if let base = configuration.string("baseConfigurationReference"), files.contains(base) {
                configuration["baseConfigurationReference"] = nil
            }
            if var settings = configuration["buildSettings"]?.dictionary {
                for key in settings.keys where key.hasPrefix("PODS_") {
                    settings[key] = nil
                    changes.append(ProjectChange(kind: .removed, subject: "build setting \(key) in \(object.string("name") ?? id)"))
                }
                configuration["buildSettings"] = .dictionary(settings)
            }
            if configuration != object { project[id] = configuration }
        }
        return changes
    }

    /// Removes the Pods project from a workspace's file list. Returns the original contents, for rolling back, when
    /// the workspace changed.
    static func removePodsProject(fromWorkspace workspace: URL) throws -> Data? {
        let file = workspace.appendingPathComponent("contents.xcworkspacedata")
        guard let original = try? Data(contentsOf: file) else { return nil }
        guard let text = String(data: original, encoding: .utf8) else {
            throw SwiftPodsError("Xcode workspace data is not valid UTF-8", file: file.path)
        }
        let pattern = #"[ \t]*<FileRef\s+location\s*=\s*"[^"]*Pods/Pods\.xcodeproj">\s*</FileRef>\r?\n"#
        let expression = try NSRegularExpression(pattern: pattern)
        let updated = expression.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        guard updated != text else { return nil }
        try FileTree.replace(file, with: Data(updated.utf8))
        return original
    }
}
