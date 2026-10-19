import Foundation

enum NativeFileSelection {
    static let headers = Set(["h", "hh", "hpp", "ipp", "tpp", "hxx", "def", "inl", "inc"])
    static let sources = Set(["m", "mm", "i", "c", "cc", "cpp", "cxx", "c++", "swift"])
    static let objectSources = sources.union(["s", "S", "C", "M"])
    // Assembly and Metal are compiled when explicitly selected. Directory defaults and
    // FileAccessor.other_source_files retain the declarative source extensions.
    static let compilableSources = objectSources.union(["metal"])
    static func excluded(_ file: URL, by paths: Set<URL>) -> Bool {
        paths.contains { NativePath.relativeComponents(of: file, to: $0) != nil }
    }
    static func files(_ patterns: Any?, root: URL, headersOnly: Bool = false) throws -> [URL] {
        var result = Set<URL>()
        let extensions = headersOnly ? headers : headers.union(sources)
        for pattern in nativeStrings(patterns) {
            for path in try nativeGlob(pattern, root: root) {
                if (try? path.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    guard let components = NativePath.relativeComponents(of: path, to: root) else { continue }
                    let relative = components.isEmpty ? "." : components.joined(separator: "/")
                    guard
                        relative.caseInsensitiveCompare(pattern.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
                            == .orderedSame
                    else { continue }
                    for child in try FileManager.default.contentsOfDirectory(
                        at: path, includingPropertiesForKeys: [.isRegularFileKey])
                    {
                        try NativeCancellation.check()
                        guard extensions.contains(child.pathExtension.lowercased()) else { continue }
                        if (try? child.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                            result.insert(child.standardizedFileURL)
                        }
                    }
                } else {
                    result.insert(path)
                }
            }
        }
        return result.sorted { $0.path < $1.path }
    }
    static func paths(_ patterns: Any?, attributes: [String: Any], root: URL) throws -> [URL] {
        let excluded = Set(try nativeGlob(attributes["exclude_files"], root: root))
        return try nativeGlob(patterns, root: root).filter { !self.excluded($0, by: excluded) }
    }
    /// Localized directories become individual build inputs; filter after expansion.
    static func resourcePaths(_ patterns: Any?, attributes: [String: Any], root: URL) throws -> [URL] {
        let excluded = Set(try nativeGlob(attributes["exclude_files"], root: root))
        let expanded = try NativeResources.expandedPaths(nativeGlob(patterns, root: root))
        return Set(expanded.map(\.standardizedFileURL)).filter {
            !self.excluded($0, by: excluded)
                && !($0.pathExtension == "lproj"
                    && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true)
        }.sorted { $0.path < $1.path }
    }
    static func sourceFiles(_ attributes: [String: Any], root: URL) throws -> [URL] {
        let excluded = Set(try nativeGlob(attributes["exclude_files"], root: root))
        return try files(attributes["source_files"], root: root).filter { !self.excluded($0, by: excluded) }
    }
}
