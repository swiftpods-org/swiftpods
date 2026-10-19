import Foundation

extension NativeXcode {
    /// Consumers see the public tree; only the producer receives private paths.
    func installLibraryHeaders(
        _ variant: NativePodVariant, attributes: [String: Any], selection: NativeLibraryFiles,
        moduleAttributes: [String: Any], directory: URL,
        module: String, modular: Bool, settings: inout [String: Any]
    ) throws {
        let namespaces = try Set(selection.publicHeaders.map { try selection.headerDirectory($0, module: module) })
        let headerName: String
        if namespaces.count == 1, let namespace = namespaces.first {
            headerName = namespace
        } else {
            headerName = try NativeFileRules.headerDirectory(moduleAttributes, module: module)
        }
        let publicBase = project.appendingPathComponent(headerDirectory(variant.root, platform: variant.platform))
        let publicRoot = publicBase.appendingPathComponent(headerName).standardizedFileURL
        let privateBase = project.appendingPathComponent(
            headerDirectory(variant.root, platform: variant.platform, visibility: .privateHeaders))
        for (base, headers) in [
            (publicBase, selection.publicHeaders),
            (privateBase, selection.headers),
        ] {
            var destinations = Set<String>()
            for header in headers.sorted(by: { $0.path < $1.path }) {
                let relative =
                    try selection.headerDirectory(header, module: module) + "/" + selection.headerPath(header)
                let destination = base.appendingPathComponent(relative).standardizedFileURL
                guard destinations.insert(destination.path).inserted else {
                    throw Diagnostic(
                        "SP-SPEC-HEADER-COLLISION", stage: "integrate", "Multiple headers map to " + relative,
                        file: variant.label)
                }
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: destination.path)
                    || (try? FileManager.default.destinationOfSymbolicLink(atPath: destination.path)) != nil
                {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: header)
            }
        }
        var paths = nativeStrings(settings["HEADER_SEARCH_PATHS"])
        paths.append(NativeBuildSetting.literalPath(privateBase.path))
        settings["HEADER_SEARCH_PATHS"] = paths

        try FileManager.default.createDirectory(at: publicRoot, withIntermediateDirectories: true)
        let modulemap = publicRoot.appendingPathComponent("module.modulemap")
        if attributes["module_map"] as? Bool == false {
            if FileManager.default.fileExists(atPath: modulemap.path) {
                try FileManager.default.removeItem(at: modulemap)
            }
            return
        }
        if let path = attributes["module_map"] as? String {
            // Resolve relative header declarations against the author's map,
            // rather than replacing its modules with an umbrella definition.
            let map = directory.appendingPathComponent(path).standardizedFileURL
            let contents = try String(contentsOf: map, encoding: .utf8)
            let normalized = contents.replacingOccurrences(
                of: #"(?m)^(\s*)framework\s+(module[^{}]+)\{"#, with: "$1$2{", options: .regularExpression)
            let effective: URL
            if normalized != contents {
                // Framework-style maps also describe static libraries. Their
                // mapped public headers live beside this generated copy.
                try Data(normalized.utf8).writeIfChanged(to: modulemap)
                effective = modulemap
            } else {
                effective = map
            }
            customModuleMaps[variant.key] = effective
            settings["MODULEMAP_FILE"] = NativeBuildSetting.literal(effective.path)
            if effective != modulemap, FileManager.default.fileExists(atPath: modulemap.path) {
                try FileManager.default.removeItem(at: modulemap)
            }
            return
        }
        let umbrella = publicRoot.appendingPathComponent(module + "-umbrella.h")
        let content =
            "#ifdef __OBJC__\n#import <Foundation/Foundation.h>\n#endif\n"
            + (try selection.publicHeaders.sorted(by: { $0.path < $1.path }).map { header in
                let destination = try publicBase.appendingPathComponent(
                    selection.headerDirectory(header, module: module) + "/" + selection.headerPath(header)
                ).standardizedFileURL
                let origin = publicRoot.pathComponents
                let target = destination.pathComponents
                let shared = zip(origin, target).prefix { $0 == $1 }.count
                let relative = (Array(repeating: "..", count: origin.count - shared) + target.dropFirst(shared)).joined(
                    separator: "/")
                return "#include \"" + relative + "\""
            }).joined(separator: "\n") + "\n"
        try Data(content.utf8).writeIfChanged(to: umbrella)
        if modular {
            try Data(
                ("module " + module + " { umbrella header \"" + umbrella.lastPathComponent
                    + "\" export * module * { export * } }\n").utf8
            ).writeIfChanged(to: modulemap)
            settings["MODULEMAP_FILE"] = NativeBuildSetting.literal(modulemap.path)
            // Clang cannot discover an aliased directory by the module name.
            if headerName != module { customModuleMaps[variant.key] = modulemap }
        } else if FileManager.default.fileExists(atPath: modulemap.path) {
            try FileManager.default.removeItem(at: modulemap)
        }
    }

    func applyCustomModuleMaps(_ roots: Set<String>, platform: String, settings: inout [String: Any]) {
        let flags = roots.sorted().compactMap { customModuleMaps[variantKey($0, platform)] }.map {
            "-fmodule-map-file=" + NativeBuildSetting.quoted(NativeBuildSetting.literal($0.path))
        }
        guard !flags.isEmpty else { return }
        for (key, additions) in [
            ("OTHER_CFLAGS", flags), ("OTHER_CPLUSPLUSFLAGS", flags),
            ("OTHER_SWIFT_FLAGS", flags.flatMap { ["-Xcc", $0] }),
        ] {
            var values = nativeStrings(settings[key])
            if values.isEmpty { values = ["$(inherited)"] }
            values += additions
            settings[key] = values
        }
    }
}
