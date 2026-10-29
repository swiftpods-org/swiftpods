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

    static func remove(from project: inout XcodeProject) -> [ProjectChange] {
        let owned = ProjectIntegration.ownedIdentifiers(project)
        var removed = Set<String>()
        var changes: [ProjectChange] = []

        let files = Set(project.objects.filter { $0.value.isa == "PBXFileReference" && isPodsFile($0.value) }.keys)
        removed.formUnion(files)
        removed.formUnion(project.objects.filter { $0.value.isa == "PBXBuildFile" && files.contains($0.value.string("fileRef") ?? "") }.keys)
        let proxies = Set(project.objects.filter { _, object in
            object.isa == "PBXContainerItemProxy"
                && (files.contains(object.string("containerPortal") ?? "") || object.string("remoteInfo")?.hasPrefix("Pods-") == true)
        }.keys)
        removed.formUnion(proxies)

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
        for id in files.sorted() {
            changes.append(ProjectChange(kind: .removed, subject: "file " + (project[id]?.string("path") ?? id)))
        }

        for id in removed { project.remove(id) }

        // Cross-project references to the Pods project are dictionaries, which `remove` does not visit.
        var root = project.project
        if let references = root["projectReferences"]?.array {
            let kept = references.filter { !files.contains($0.dictionary?["ProjectRef"]?.string ?? "") }
            root["projectReferences"] = kept.isEmpty ? nil : .array(kept)
            project.project = root
        }
        for (id, object) in project.objects where object.isa == "PBXGroup" && object.string("name") ?? object.string("path") == "Pods" {
            if object.strings("children").isEmpty { project.remove(id) }
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

    /// Removes the Pods project from a workspace's file list; returns whether the workspace changed.
    static func removePodsProject(fromWorkspace workspace: URL) throws -> Bool {
        let file = workspace.appendingPathComponent("contents.xcworkspacedata")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return false }
        let pattern = #"[ \t]*<FileRef\s+location\s*=\s*"[^"]*Pods/Pods\.xcodeproj">\s*</FileRef>\r?\n"#
        let expression = try NSRegularExpression(pattern: pattern)
        let updated = expression.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        guard updated != text else { return false }
        try Data(updated.utf8).write(to: file, options: .atomic)
        return true
    }
}
