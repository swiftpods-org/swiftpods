import Foundation

struct NativeFileRules {
    static func headerPath(_ file: URL, attributes: [String: Any], root: URL) throws -> String {
        guard let mapping = attributes["header_mappings_dir"] as? String else { return file.lastPathComponent }
        try NativeSpecPaths.validatePath(mapping, stage: "integrate")
        guard mapping.utf8.first != 47, !(mapping as NSString).pathComponents.contains("..") else {
            throw Diagnostic(
                "SP-SPEC-HEADER-MAPPING", stage: "integrate", "Header mapping directory must stay inside the pod")
        }
        let base = root.appendingPathComponent(mapping).standardizedFileURL
        guard let components = NativePath.relativeComponents(of: file, to: base), !components.isEmpty else {
            throw Diagnostic(
                "SP-SPEC-HEADER-MAPPING", stage: "integrate", "Header lies outside header_mappings_dir", file: file.path
            )
        }
        return components.joined(separator: "/")
    }
    static func headerDirectory(_ attributes: [String: Any], module: String) throws -> String {
        let value = attributes["header_dir"] as? String ?? module
        try NativeSpecPaths.validatePath(value, stage: "integrate")
        guard !value.isEmpty, value.utf8.first != 47, !(value as NSString).pathComponents.contains("..") else {
            throw Diagnostic(
                "SP-SPEC-HEADER-MAPPING", stage: "integrate", "header_dir must be a relative path inside public headers"
            )
        }
        return value
    }
    let headers: Set<URL>
    let publicHeaders: Set<URL>
    let privateHeaders: Set<URL>
    let projectHeaders: Set<URL>
    let arcFiles: Set<URL>?

    init(_ attributes: [String: Any], root: URL, files: [URL]) throws {
        headers = Set(files.filter { NativeFileSelection.headers.contains($0.pathExtension) })
        privateHeaders = Set(
            try NativeFileSelection.files(attributes["private_header_files"], root: root, headersOnly: true)
        ).intersection(headers)
        projectHeaders = Set(
            try NativeFileSelection.files(attributes["project_header_files"], root: root, headersOnly: true)
        ).intersection(headers)
        let publicMatches = try NativeFileSelection.files(
            attributes["public_header_files"], root: root, headersOnly: true)
        publicHeaders = (publicMatches.isEmpty ? headers : Set(publicMatches).intersection(headers))
            .subtracting(privateHeaders).subtracting(projectHeaders)
        if let arc = attributes["requires_arc"], !(arc is Bool), !(arc is NSNull) {
            guard arc is String || arc is [String] else {
                throw Diagnostic("SP-SPEC-ARC", stage: "integrate", "requires_arc must be boolean or file patterns")
            }
            arcFiles = Set(try NativeFileSelection.files(arc, root: root))
        } else {
            arcFiles = nil
        }
    }
    func headerSettings(_ file: URL) -> [String: Any] {
        if publicHeaders.contains(file) { return ["ATTRIBUTES": ["Public"]] }
        if privateHeaders.contains(file) { return ["ATTRIBUTES": ["Private"]] }
        return [:]
    }
    func sourceSettings(_ file: URL) -> [String: Any] {
        guard let arcFiles, ["m", "mm", "M"].contains(file.pathExtension) else { return [:] }
        return ["COMPILER_FLAGS": arcFiles.contains(file) ? "-fobjc-arc" : "-fno-objc-arc"]
    }
}

extension NativeXcode {
    func compileSettings(_ attributes: [String: Any], root: URL, label: String, settings: inout [String: Any]) throws {
        if attributes["prefix_header_file"] as? Bool == false {
            settings.removeValue(forKey: "GCC_PREFIX_HEADER")
        } else {
            let sdk = settings["SDKROOT"] as? String ?? ""
            let header =
                sdk == "macosx"
                ? "Cocoa/Cocoa.h"
                : ["iphoneos", "appletvos"].contains(sdk) ? "UIKit/UIKit.h" : "Foundation/Foundation.h"
            var contents =
                "#ifdef __OBJC__\n#import <" + header
                + ">\n#else\n#ifndef FOUNDATION_EXPORT\n#ifdef __cplusplus\n#define FOUNDATION_EXPORT extern \"C\"\n#else\n#define FOUNDATION_EXPORT extern\n#endif\n#endif\n#endif\n"
            contents += nativeStrings(attributes["prefix_header_contents"]).joined(separator: "\n") + "\n"
            if let file = attributes["prefix_header_file"] as? String {
                try NativeSpecPaths.validatePath(file, stage: "integrate")
                let input = root.appendingPathComponent(file).standardizedFileURL
                guard FileManager.default.fileExists(atPath: input.path) else {
                    throw Diagnostic(
                        "SP-SPEC-PREFIX", stage: "integrate", "Prefix header does not exist", file: input.path)
                }
                contents += try String(contentsOf: input, encoding: .utf8) + "\n"
            } else if attributes["prefix_header_file"] as? Bool == true {
                throw Diagnostic("SP-SPEC-PREFIX", stage: "integrate", "prefix_header_file must be false or a path")
            }
            let path = project.appendingPathComponent(
                "Pods/Target Support Files/" + label + "/" + label + "-prefix.pch")
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = Data(contents.utf8)
            if (try? Data(contentsOf: path)) != data { try data.write(to: path, options: .atomic) }
            settings["GCC_PREFIX_HEADER"] = NativeBuildSetting.literal(path.path)
        }
        if let map = attributes["module_map"] as? String {
            try NativeSpecPaths.validatePath(map, stage: "integrate")
            let path = root.appendingPathComponent(map).standardizedFileURL
            guard FileManager.default.fileExists(atPath: path.path) else {
                throw Diagnostic("SP-SPEC-MODULEMAP", stage: "integrate", "Module map does not exist", file: path.path)
            }
            settings["MODULEMAP_FILE"] = NativeBuildSetting.literal(path.path)
        }
    }
}
