import Foundation

struct NativeFileRules {
    static func headerPath(_ file: URL, attributes: [String: Any], root: URL) throws -> String {
        guard let mapping = attributes["header_mappings_dir"] as? String else { return file.lastPathComponent }
        guard !mapping.hasPrefix("/"), !mapping.split(separator: "/").contains("..") else {
            throw Diagnostic(
                "SP-SPEC-HEADER-MAPPING", stage: "integrate", "Header mapping directory must stay inside the pod")
        }
        let base = root.appendingPathComponent(mapping).standardizedFileURL.path
        guard file.path.hasPrefix(base + "/") else {
            throw Diagnostic(
                "SP-SPEC-HEADER-MAPPING", stage: "integrate", "Header lies outside header_mappings_dir", file: file.path
            )
        }
        return String(file.path.dropFirst(base.count + 1))
    }
    static func headerDirectory(_ attributes: [String: Any], module: String) throws -> String {
        let value = attributes["header_dir"] as? String ?? module
        guard !value.isEmpty, !value.hasPrefix("/"), !value.split(separator: "/").contains("..") else {
            throw Diagnostic(
                "SP-SPEC-HEADER-MAPPING", stage: "integrate", "header_dir must be a relative path inside public headers"
            )
        }
        return value
    }
    let publicHeaders: Set<URL>
    let privateHeaders: Set<URL>
    let projectHeaders: Set<URL>
    let arcFiles: Set<URL>?

    init(_ attributes: [String: Any], root: URL, files: [URL]) throws {
        let headers = Set(files.filter { NativeFileSelection.headers.contains($0.pathExtension) })
        privateHeaders = Set(
            try NativeFileSelection.files(attributes["private_header_files"], root: root, headersOnly: true)
        ).intersection(headers)
        projectHeaders = Set(
            try NativeFileSelection.files(attributes["project_header_files"], root: root, headersOnly: true)
        ).intersection(headers)
        publicHeaders =
            (nativeStrings(attributes["public_header_files"]).isEmpty
            ? headers
            : Set(try NativeFileSelection.files(attributes["public_header_files"], root: root, headersOnly: true))
                .intersection(headers)).subtracting(privateHeaders).subtracting(projectHeaders)
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
        guard let arcFiles, ["m", "mm"].contains(file.pathExtension) else { return [:] }
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
            settings["GCC_PREFIX_HEADER"] = path.path
        }
        if let map = attributes["module_map"] as? String {
            let path = root.appendingPathComponent(map).standardizedFileURL
            guard FileManager.default.fileExists(atPath: path.path) else {
                throw Diagnostic("SP-SPEC-MODULEMAP", stage: "integrate", "Module map does not exist", file: path.path)
            }
            settings["MODULEMAP_FILE"] = path.path
        }
    }
}
