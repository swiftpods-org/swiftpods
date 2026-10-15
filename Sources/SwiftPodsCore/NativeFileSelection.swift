import Foundation

enum NativeFileSelection {
    static let headers = Set(["h", "hh", "hpp", "ipp", "tpp", "hxx", "def", "inl", "inc"])
    static let sources = Set(["m", "mm", "i", "c", "cc", "cpp", "cxx", "c++", "swift"])
    static func excluded(_ file: URL, by paths: Set<URL>) -> Bool {
        let file = file.standardizedFileURL.path
        return paths.contains {
            var path = $0.standardizedFileURL.path
            while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
            return file == path || file.hasPrefix(path + "/")
        }
    }
    static func files(_ patterns: Any?, root: URL, headersOnly: Bool = false) throws -> [URL] {
        var result = Set<URL>()
        let extensions = headersOnly ? headers : headers.union(sources)
        for pattern in nativeStrings(patterns) {
            for path in try nativeGlob(pattern, root: root) {
                if (try? path.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    let relative =
                        path.path == root.standardizedFileURL.path
                        ? "." : String(path.path.dropFirst(root.standardizedFileURL.path.count + 1))
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
    static func sourceFiles(_ attributes: [String: Any], root: URL) throws -> [URL] {
        let excluded = Set(try nativeGlob(attributes["exclude_files"], root: root))
        return try files(attributes["source_files"], root: root).filter { !self.excluded($0, by: excluded) }
    }
}
