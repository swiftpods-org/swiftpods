import Foundation

/// A self-contained host tool generated alongside the build scripts. It uses Xcode's current dependency
/// lists, rather than guessing that a package product and its (possibly transitive) modules have one name.
enum PackageModuleBridge {
    static let source = #"""
    import Darwin
    import Foundation

    func mayExist(_ path: String) -> Bool {
        var entry = stat()
        let result = path.withCString { lstat($0, &entry) }
        // The compiler can read SDK sources that the script sandbox deliberately cannot read.
        return result == 0 || errno == EACCES || errno == EPERM
    }

    func quoted(_ value: String) throws -> String {
        guard !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw NSError(domain: "SwiftPods module path contains a control character", code: 1)
        }
        return "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    // Xcode's compiler response files use GNU quoting, including single-quoted paths with spaces.
    func words(_ text: String) throws -> [String] {
        var result: [String] = []
        var word = ""
        var quote: Character?
        var escaped = false
        for character in text {
            if escaped { word.append(character); escaped = false }
            else if character == "\\" && quote != "'" { escaped = true }
            else if let delimiter = quote {
                if character == delimiter { quote = nil } else { word.append(character) }
            } else if character == "\"" || character == "'" { quote = character }
            else if character.isWhitespace {
                if !word.isEmpty { result.append(word); word = "" }
            } else { word.append(character) }
        }
        guard !escaped, quote == nil else { throw NSError(domain: "Invalid Xcode compiler response file", code: 1) }
        if !word.isEmpty { result.append(word) }
        return result
    }

    do {
        let arguments = CommandLine.arguments
        guard arguments.count == 6 else { throw NSError(domain: "Invalid SwiftPods module bridge arguments", code: 1) }
        let maps = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let output = URL(fileURLWithPath: arguments[2], isDirectory: true)
        var modules = Set<String>()
        // Xcode writes these lists for the current target and configuration, including transitive package
        // targets. Reading the lists avoids importing unrelated or stale maps left by previous builds.
        for path in arguments[3...4] {
            for line in try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n") {
                let components = URL(fileURLWithPath: String(line)).pathComponents
                if let metadata = components.lastIndex(of: "Metadata.appintents"), metadata > 0 {
                    let container = components[metadata - 1]
                    if container.hasSuffix(".appintents") {
                        modules.insert(String(container.dropLast(".appintents".count)))
                    }
                }
            }
        }
        // PIFCache retains multiple versions of the same target, including different package checkout
        // roots. Xcode records the current description before running tasks, even when reusing a cached
        // description. Its compiler arguments and response-file attachments identify the live paths.
        let buildData = URL(fileURLWithPath: arguments[5], isDirectory: true)
        var remainingBytes = 128 * 1_024 * 1_024
        func read(_ file: URL) throws -> Data {
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= remainingBytes else { throw NSError(domain: "SwiftPods package build metadata is too large", code: 1) }
            remainingBytes -= size
            return try Data(contentsOf: file)
        }
        let history = String(decoding: try read(buildData.appendingPathComponent("prior-build-descriptions.txt")), as: UTF8.self)
        guard let signature = history.split(separator: "\n").last,
            signature.range(of: #"^[a-fA-F0-9]{32}$"#, options: .regularExpression) != nil else {
            throw NSError(domain: "Missing current Xcode build description", code: 1)
        }
        let description = buildData.appendingPathComponent(String(signature) + ".xcbuilddata", isDirectory: true)
        guard let manifest = try JSONSerialization.jsonObject(with: read(description.appendingPathComponent("manifest.json"))) as? [String: Any],
            let commands = manifest["commands"] as? [String: [String: Any]] else {
            throw NSError(domain: "Invalid current Xcode build manifest", code: 1)
        }
        var liveIncludes = Set<String>()
        var liveMaps = Set<String>()
        let liveOutputs = Set(commands.values.flatMap { $0["outputs"] as? [String] ?? [] })
        func collect(_ arguments: [String]) {
            for (index, argument) in arguments.enumerated() {
                if argument == "-I", index + 1 < arguments.count { liveIncludes.insert(arguments[index + 1]) }
                else if argument.hasPrefix("-I/") { liveIncludes.insert(String(argument.dropFirst(2))) }
                else if argument.hasPrefix("-fmodule-map-file=") { liveMaps.insert(String(argument.dropFirst("-fmodule-map-file=".count))) }
            }
        }
        for command in commands.values { collect(command["args"] as? [String] ?? []) }
        let attachments = try FileManager.default.contentsOfDirectory(
            at: description.appendingPathComponent("attachments"), includingPropertiesForKeys: [.fileSizeKey])
        guard attachments.count <= 20_000 else { throw NSError(domain: "SwiftPods package build has too many attachments", code: 1) }
        for attachment in attachments {
            let data = try read(attachment)
            // Other attachments contain generated sources, file lists and binary data, not flags.
            guard let text = String(data: data, encoding: .utf8),
                text.first == "-" || text.hasPrefix("'-") || text.hasPrefix("\"-") else { continue }
            collect(try words(text))
        }
        let cache = buildData.appendingPathComponent("PIFCache/target", isDirectory: true)
        var recordedMaps: [String: Set<String>] = [:]
        var publicIncludes: [String: Set<String>] = [:]
        if FileManager.default.fileExists(atPath: cache.path) {
            let records = try FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: [.fileSizeKey])
            guard records.count <= 20_000 else { throw NSError(domain: "SwiftPods package target cache is too large", code: 1) }
            for record in records where record.lastPathComponent.hasSuffix("-json") {
                guard let target = try JSONSerialization.jsonObject(with: read(record)) as? [String: Any],
                    (target["guid"] as? String)?.hasPrefix("PACKAGE-TARGET:") == true,
                    let configurations = target["buildConfigurations"] as? [[String: Any]] else { continue }
                for configuration in configurations {
                    guard let settings = configuration["buildSettings"] as? [String: Any],
                        let module = (settings["PRODUCT_MODULE_NAME"] ?? target["name"]) as? String,
                        modules.contains(module) else { continue }
                    let imparted = (configuration["impartedBuildProperties"] as? [String: Any])?["buildSettings"] as? [String: Any]
                    var paths = [settings["MODULEMAP_PATH"] as? String, settings["MODULEMAP_FILE"] as? String].compactMap { $0 }
                    paths += (imparted?["OTHER_CFLAGS"] as? [String] ?? []).compactMap { flag in
                        flag.hasPrefix("-fmodule-map-file=") ? String(flag.dropFirst("-fmodule-map-file=".count)) : nil
                    }
                    for include in imparted?["HEADER_SEARCH_PATHS"] as? [String] ?? []
                        where liveIncludes.contains(include) {
                        publicIncludes[module, default: []].insert(include)
                    }
                    for rawPath in paths {
                        let path = rawPath.replacingOccurrences(of: "$(GENERATED_MODULEMAP_DIR)", with: maps.path)
                        guard path.hasPrefix("/"), mayExist(path) else { continue }
                        let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
                        guard liveOutputs.contains(path)
                            || liveMaps.contains(path) || liveIncludes.contains(parent.path) else { continue }
                        recordedMaps[module, default: []].insert(path)
                    }
                }
            }
        }
        let headers = try NSRegularExpression(pattern: #"\b(?:header|umbrella)\s+\"((?:\\.|[^\"\\])*)\""#)
        var external: [String] = []
        var includes = Set<String>([maps.path, output.path])
        for module in modules.sorted() {
            guard module.range(of: #"^[A-Za-z_][A-Za-z_0-9]*$"#, options: .regularExpression) != nil else {
                throw NSError(domain: "Invalid SwiftPods dependency module name: \(module)", code: 1)
            }
            let candidates = recordedMaps[module] ?? []
            guard candidates.count <= 1 else {
                throw NSError(domain: "Conflicting source module maps in the current Xcode build for \(module): \(candidates.sorted().joined(separator: ", "))", code: 1)
            }
            let map = candidates.first.map { URL(fileURLWithPath: $0) } ?? maps.appendingPathComponent(module + ".modulemap")
            includes.formUnion(publicIncludes[module] ?? [])
            if candidates.isEmpty && !liveOutputs.contains(map.path) && !liveMaps.contains(map.path) { continue } // Binary frameworks have their own maps.
            external.append("extern module \(module) \(try quoted(map.path))")
            if map.deletingLastPathComponent().standardizedFileURL != maps.standardizedFileURL {
                // Public include roots come from Xcode's package settings. Leave the source map itself to
                // the compiler: script sandboxing need not grant read access to package checkout contents.
                includes.insert(map.deletingLastPathComponent().path)
                continue
            }
            let text = try String(contentsOf: map, encoding: .utf8)
            for match in headers.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range(at: 1), in: text) else { continue }
                let literal = String(text[range])
                // Module-map strings use the same quote and backslash escaping as response files.
                var path = ""
                var escaped = false
                for character in literal {
                    if escaped { path.append(character); escaped = false }
                    else if character == "\\" { escaped = true }
                    else { path.append(character) }
                }
                guard !escaped else { throw NSError(domain: "Invalid module-map header path", code: 1) }
                let header = URL(fileURLWithPath: path, relativeTo: map.deletingLastPathComponent()).standardizedFileURL
                let declaration = (text as NSString).substring(with: match.range)
                includes.insert(declaration.hasPrefix("umbrella ") && !declaration.hasPrefix("umbrella header")
                    ? header.path : header.deletingLastPathComponent().path)
            }
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try (external.joined(separator: "\n") + "\n").write(
            to: output.appendingPathComponent("module.modulemap"), atomically: false, encoding: .utf8)
        let flags = try includes.sorted().map { "-I" + (try quoted($0)) }.joined(separator: "\n") + "\n"
        try flags.write(to: output.appendingPathComponent("clang.rsp"), atomically: false, encoding: .utf8)
    } catch {
        FileHandle.standardError.write(Data("error: SwiftPods cannot prepare package modules: \(error)\n".utf8))
        exit(1)
    }
    """#
}
