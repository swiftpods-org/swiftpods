import Foundation

/// Hooks and the project generator share Swift's file selection and visibility rules.
enum NativeFileAccessor {
    static func response(_ request: [String: Any]) throws -> [String: Any] {
        guard let value = request["value"] as? [String: Any], let path = value["root"] as? String,
            let attributes = value["attributes"] as? [String: Any], let operation = value["operation"] as? String
        else { throw Diagnostic("SP-HOOK-FILES", stage: "hook", "Invalid file accessor request") }
        let root = URL(fileURLWithPath: path).standardizedFileURL
        let sources = try NativeFileSelection.sourceFiles(attributes, root: root)
        let rules = try NativeFileRules(attributes, root: root, files: sources)
        func paths(_ key: String) throws -> [URL] {
            try NativeFileSelection.paths(attributes[key], attributes: attributes, root: root)
        }
        func strings(_ files: [URL]) -> [String] { files.map(\.path).sorted() }
        let headers = sources.filter { NativeFileSelection.headers.contains($0.pathExtension) }
        let arc: [URL]
        if attributes["requires_arc"] as? Bool == false {
            arc = []
        } else if let selected = rules.arcFiles {
            arc = sources.filter(selected.contains)
        } else {
            arc = sources
        }
        let bundles = try (attributes["resource_bundles"] as? [String: Any] ?? [:]).mapValues { patterns in
            strings(try NativeFileSelection.paths(patterns, attributes: attributes, root: root))
        }
        let odr = try NativeOnDemandResources(attributes: attributes, root: root, expandLocalizedDirectories: false)
        var result: Any
        switch operation {
        case "source_files": result = strings(sources)
        case "headers": result = strings(headers)
        case "public_headers":
            var publicFiles = Array(rules.publicHeaders)
            if value["include_frameworks"] as? Bool == true {
                publicFiles += try frameworkHeaders(paths("vendored_frameworks"))
            }
            result = strings(Array(Set(publicFiles)))
        case "private_headers": result = strings(Array(rules.privateHeaders))
        case "project_headers": result = strings(Array(rules.projectHeaders))
        case "arc_source_files": result = strings(arc)
        case "non_arc_source_files": result = strings(sources.filter { !arc.contains($0) })
        case "other_source_files":
            result = strings(
                sources.filter {
                    !NativeFileSelection.sources.union(NativeFileSelection.headers).contains($0.pathExtension)
                })
        case "resources", "preserve_paths", "vendored_frameworks", "vendored_libraries":
            result = strings(try paths(operation))
        case "resource_bundles": result = bundles
        case "resource_bundle_files": result = Array(Set(bundles.values.flatMap { $0 })).sorted()
        case "on_demand_resources":
            var tags: [String: Any] = [:]
            for (category, names) in odr.categories {
                for name in names {
                    tags[name] = [
                        "paths": strings(odr.files.filter { $0.value.contains(name) }.map(\.key)), "category": category,
                    ]
                }
            }
            result = tags
        case "on_demand_resources_files": result = strings(Array(odr.files.keys))
        case "vendored_frameworks_headers": result = strings(try frameworkHeaders(paths("vendored_frameworks")))
        case "vendored_xcframeworks":
            result = strings(try paths("vendored_frameworks").filter { $0.pathExtension == "xcframework" })
        case "vendored_static_frameworks", "vendored_dynamic_frameworks", "vendored_static_xcframeworks",
            "vendored_dynamic_xcframeworks", "vendored_static_libraries", "vendored_dynamic_libraries",
            "vendored_static_artifacts", "vendored_dynamic_artifacts":
            let libraries = operation.hasSuffix("libraries")
            let artifacts = operation.hasSuffix("artifacts")
            let files =
                try libraries
                ? paths("vendored_libraries")
                : artifacts ? paths("vendored_libraries") + paths("vendored_frameworks") : paths("vendored_frameworks")
            let dynamic = operation.contains("_dynamic_")
            result = strings(
                try files.filter { path in
                    let sdk = try NativeVendorSDK(path)
                    let correctContainer =
                        artifacts || libraries
                        || (operation.hasSuffix("xcframeworks") ? sdk.isXCFramework : !sdk.isXCFramework)
                    return correctContainer && sdk.dynamic == dynamic
                })
        case "prefix_header", "module_map":
            result =
                (try paths(operation == "prefix_header" ? "prefix_header_file" : "module_map").first?.path).map {
                    $0 as Any
                } ?? NSNull()
        case "spec_license":
            result =
                (try nativeGlob((attributes["license"] as? [String: Any])?["file"], root: root).first?.path).map {
                    $0 as Any
                } ?? NSNull()
        case "readme", "license", "specs", "docs":
            let patterns = [
                "readme": "{README,readme,Readme}{,.*}", "license": "{LICENSE,LICENCE,license,licence,COPYING}{,.*}",
                "specs": "*.podspec{,.json}", "docs": "{doc,docs,Documentation,documentation}",
            ]
            let files = try nativeGlob(patterns[operation], root: root)
            result = ["specs", "docs"].contains(operation) ? strings(files) : (files.first?.path as Any?) ?? NSNull()
        default: throw Diagnostic("SP-HOOK-FILES", stage: "hook", "Unknown file accessor operation: " + operation)
        }
        return ["result": result]
    }
    private static func frameworkHeaders(_ frameworks: [URL]) throws -> [URL] {
        var result = Set<URL>()
        for framework in frameworks {
            let roots: [URL]
            if framework.pathExtension == "xcframework" {
                roots = try NativeVendorSDK(framework).slices.compactMap {
                    $0.headers
                        ?? ($0.library.pathExtension == "framework"
                            ? $0.library.appendingPathComponent("Headers") : nil)
                }
            } else {
                roots = [framework.appendingPathComponent("Headers")]
            }
            for root in roots {
                result.formUnion(
                    try NativeFileSelection.files("**/*", root: root, headersOnly: true).filter {
                        NativeFileSelection.headers.contains($0.pathExtension)
                    })
            }
        }
        return result.sorted { $0.path < $1.path }
    }
}
