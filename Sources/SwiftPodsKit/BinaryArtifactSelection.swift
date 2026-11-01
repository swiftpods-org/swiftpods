import Foundation

/// Comparison keys never replace the authenticated URL used for I/O.
struct BinaryArtifactSelection {
    enum Kind { case framework, resource }

    let source: URL
    let kind: Kind
    let pathKey: String

    var outputKey: String {
        source.lastPathComponent.precomposedStringWithCanonicalMapping.lowercased().precomposedStringWithCanonicalMapping
    }

    init(_ source: URL, kind: Kind) {
        self.source = source
        self.kind = kind
        pathKey = source.standardizedFileURL.path.split(separator: "/", omittingEmptySubsequences: false)
            .map { String($0).precomposedStringWithCanonicalMapping.lowercased().precomposedStringWithCanonicalMapping }
            .joined(separator: "/")
    }

    func overlaps(_ other: Self) -> Bool {
        pathKey == other.pathKey || pathKey.hasPrefix(other.pathKey + "/") || other.pathKey.hasPrefix(pathKey + "/")
    }

    func isNestedResource(of framework: Self) -> Bool {
        kind == .resource && framework.kind == .framework
            && pathKey.hasSuffix(".bundle") && framework.pathKey.hasSuffix(".xcframework")
            && pathKey.hasPrefix(framework.pathKey + "/")
    }

    func permitsOverlap(with other: Self) -> Bool {
        isNestedResource(of: other) || other.isNestedResource(of: self)
    }
}
