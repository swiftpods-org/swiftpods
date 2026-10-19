import Foundation

/// Filesystem separators remain boundaries even before Unicode combining marks.
enum NativePath {
    static func relativePath(of path: URL, to root: URL) -> String {
        let components = path.standardizedFileURL.pathComponents
        let base = root.standardizedFileURL.pathComponents
        let shared = zip(components, base).prefix { $0 == $1 }.count
        let relative = Array(repeating: "..", count: base.count - shared) + components.dropFirst(shared)
        return relative.isEmpty ? "." : relative.joined(separator: "/")
    }

    static func relativeComponents(of path: URL, to root: URL) -> [String]? {
        let components = path.standardizedFileURL.pathComponents
        let boundary = root.standardizedFileURL.pathComponents
        guard components.starts(with: boundary) else { return nil }
        return Array(components.dropFirst(boundary.count))
    }

    static func isDescendant(_ path: URL, of root: URL) -> Bool {
        guard let relative = relativeComponents(of: path, to: root) else { return false }
        return !relative.isEmpty
    }
}
