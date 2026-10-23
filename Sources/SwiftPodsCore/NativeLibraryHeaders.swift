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
        var copies: [(source: URL, destination: URL)] = []
        for (base, headers) in [
            (publicBase, selection.publicHeaders),
            (privateBase, selection.headers),
        ] {
            var destinations = Set<String>()
            for header in headers.sorted(by: { $0.path < $1.path }) {
                let relative =
                    try selection.headerDirectory(header, module: module) + "/" + selection.headerPath(header)
                let destination = base.appendingPathComponent(relative).standardizedFileURL
                let identity = destination.path.folding(
                    options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
                guard destinations.insert(identity).inserted else {
                    throw Diagnostic(
                        "SP-SPEC-HEADER-COLLISION", stage: "integrate", "Multiple headers map to " + relative,
                        file: variant.label)
                }
                copies.append((header, destination))
            }
        }
        // Both visibility trees must be valid before replacing the first link.
        try removeObsoleteLibraryHeaders(
            in: [publicBase, privateBase], keeping: copies.map(\.destination), source: directory)
        for (source, destination) in copies {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path)
                || (try? FileManager.default.destinationOfSymbolicLink(atPath: destination.path)) != nil
            {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: source)
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
            let normalized = try NativeClangModuleMap.libraryContents(contents)
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
        // Keep include paths relative to the public namespace, while reserving
        // every authored header name before choosing the generated umbrella.
        let publicCopies = copies.filter { NativePath.isDescendant($0.destination, of: publicBase) }
        let umbrellaName = generatedUmbrellaName(
            module, occupied: publicCopies.map { NativePath.relativePath(of: $0.destination, to: publicRoot) })
        let umbrella = publicRoot.appendingPathComponent(umbrellaName)
        let support = project.appendingPathComponent("Pods/Target Support Files/" + variant.label)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let receipt = support.appendingPathComponent(module + "-library-umbrella.json")
        let previousName = (try? readObject(receipt))?["filename"] as? String ?? module + "-umbrella.h"
        guard NativeTargetNames.isFileComponent(previousName),
            previousName == module + "-umbrella.h"
                || (previousName.hasPrefix(module + "-swiftpods-umbrella-") && previousName.hasSuffix(".h"))
        else {
            throw Diagnostic(
                "SP-STATE-INVALID", stage: "integrate", "Invalid generated umbrella receipt", file: receipt.path)
        }
        for name in Set([previousName, module + "-umbrella.h"]) where name != umbrellaName {
            let previous = publicRoot.appendingPathComponent(name)
            let identity = previous.path.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            let authored = publicCopies.contains {
                $0.destination.path.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
                    == identity
                    && $0.destination.resolvingSymlinksInPath() == previous.resolvingSymlinksInPath()
            }
            let directory = (try? previous.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if !authored, !directory,
                FileManager.default.fileExists(atPath: previous.path)
                    || (try? FileManager.default.destinationOfSymbolicLink(atPath: previous.path)) != nil
            {
                try FileManager.default.removeItem(at: previous)
            }
        }
        let content =
            "#ifdef __OBJC__\n#import <Foundation/Foundation.h>\n#endif\n"
            + (try selection.publicHeaders.sorted(by: { $0.path < $1.path }).map { header in
                let destination = try publicBase.appendingPathComponent(
                    selection.headerDirectory(header, module: module) + "/" + selection.headerPath(header)
                ).standardizedFileURL
                let relative = NativePath.relativePath(of: destination, to: publicRoot)
                return "#include \"" + relative + "\""
            }).joined(separator: "\n") + "\n"
        try Data(umbrellaHeader(content, variant: variant).utf8).writeIfChanged(to: umbrella)
        try jsonData(["filename": umbrellaName]).writeIfChanged(to: receipt)
        if modular {
            try Data(
                ("module " + module + " { umbrella header "
                    + NativeBuildSetting.quoted(umbrella.lastPathComponent)
                    + " export * module * { export * } }\n").utf8
            ).writeIfChanged(to: modulemap)
            settings["MODULEMAP_FILE"] = NativeBuildSetting.literal(modulemap.path)
            // Clang cannot discover an aliased directory by the module name.
            if headerName != module { customModuleMaps[variant.key] = modulemap }
        } else if FileManager.default.fileExists(atPath: modulemap.path) {
            try FileManager.default.removeItem(at: modulemap)
        }
    }

    /// Variant directories own their header links, including links from installations
    /// predating this cleanup. Leave regular files and links to other trees alone.
    private func removeObsoleteLibraryHeaders(in bases: [URL], keeping destinations: [URL], source: URL) throws {
        func identity(_ path: URL) -> String {
            path.standardizedFileURL.path.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
        }
        let retained = Set(destinations.map(identity))
        for base in bases {
            let entries = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isSymbolicLinkKey])
            while let entry = entries?.nextObject() as? URL {
                try NativeCancellation.check()
                guard NativeFileSelection.headers.contains(entry.pathExtension), !retained.contains(identity(entry)),
                    let target = try? FileManager.default.destinationOfSymbolicLink(atPath: entry.path)
                else { continue }
                let original = URL(fileURLWithPath: target, relativeTo: entry.deletingLastPathComponent())
                    .standardizedFileURL
                guard NativePath.isDescendant(original, of: source),
                    (try? original.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true
                else { continue }
                try FileManager.default.removeItem(at: entry)
            }
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
