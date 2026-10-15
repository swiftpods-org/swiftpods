import Foundation

extension NativeXcode {
    func generateBridgeSupport() throws {
        guard manifest["generate_bridge_support"] as? Bool == true else { return }
        let located = try ToolProcess.run("/usr/bin/which", ["gen_bridge_metadata"])
        let tool = String(decoding: located.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard located.status == 0, FileManager.default.isExecutableFile(atPath: tool) else {
            throw Diagnostic("SP-BRIDGE-TOOL", stage: "integrate", "BridgeSupport requires gen_bridge_metadata in PATH")
        }
        for target in manifest["targets"] as? [[String: Any]] ?? [] {
            let label = target["label"] as? String ?? "Pods-" + (target["name"] as? String ?? "")
            let path = project.appendingPathComponent(
                "Pods/Target Support Files/" + label + "/" + label + ".bridgesupport")
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Aggregate frameworks expose their version declarations. Plain
            // Objective-C archives have no aggregate headers in the profile.
            let bindings = variantPlan?.consumers[nativeConsumerKey(target)] ?? [:]
            let usesSwift = try bindings.values.contains { key in
                guard let variant = variantPlan?.variants[key], let spec = resolution.specs[variant.root],
                    let root = spec.directory
                else { return false }
                let attributes = try NativeVariantPlan.attributes(
                    spec, names: variant.names, platform: variant.platform)
                return try NativeFileSelection.sourceFiles(attributes, root: root).contains {
                    $0.pathExtension == "swift"
                }
            }
            var headers: [String] = []
            if target["frameworks"] != nil || usesSwift {
                let module = label.replacingOccurrences(of: "[^A-Za-z0-9_]", with: "_", options: .regularExpression)
                let header = path.deletingLastPathComponent().appendingPathComponent(label + "-umbrella.h")
                let platform = (target["platform"] as? [String: String])?["name"] ?? "ios"
                let framework =
                    platform == "osx"
                    ? "Cocoa/Cocoa.h"
                    : ["ios", "tvos", "visionos"].contains(platform) ? "UIKit/UIKit.h" : "Foundation/Foundation.h"
                let contents =
                    "#ifdef __OBJC__\n#import <" + framework
                    + ">\n#else\n#ifndef FOUNDATION_EXPORT\n#define FOUNDATION_EXPORT extern\n#endif\n#endif\nFOUNDATION_EXPORT double "
                    + module + "VersionNumber;\nFOUNDATION_EXPORT const unsigned char " + module + "VersionString[];\n"
                try Data(contents.utf8).writeIfChanged(to: header, options: .atomic)
                headers = [header.path]
            }
            let flags = headers.isEmpty ? "" : "-I " + NativeLock.quote(path.deletingLastPathComponent().path)
            let result = try ToolProcess.run(tool, ["-c", flags, "-o", path.path] + headers, directory: project)
            if result.status != 0 || !FileManager.default.fileExists(atPath: path.path) {
                // The selected profile preserves the reference's command failure
                // behavior: warn and retain the resource reference. No metadata
                // file is fabricated; a subsequent build can report its absence.
                configurationWarnings.append([
                    "kind": "warning", "code": "SP-BRIDGE-TOOL",
                    "message": "BridgeSupport metadata command exited \(result.status): "
                        + String(decoding: result.error, as: UTF8.self), "file": path.path,
                ])
            }
            let ref = file(path.path)
            if let root = graph.root["rootObject"] as? String, let group = graph.objects[root]?["mainGroup"] as? String
            {
                var children = graph.objects[group]?["children"] as? [String] ?? []
                children.append(ref)
                graph.objects[group]?["children"] = children
            }
        }
    }
    func bridgeSupportResource(_ target: [String: Any]) -> [URL] {
        guard manifest["generate_bridge_support"] as? Bool == true else { return [] }
        let label = target["label"] as? String ?? "Pods-" + (target["name"] as? String ?? "")
        return [project.appendingPathComponent("Pods/Target Support Files/" + label + "/" + label + ".bridgesupport")]
    }
}
