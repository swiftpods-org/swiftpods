import Foundation

/// Swift Package Manager's identity rules for package locations. Spellings that
/// differ only in scheme, credentials, port, case, `.git` suffix or scp-style SSH
/// syntax name one package; distinct locations with one identity cannot coexist.
public enum PackageLocation {
    public static func canonical(_ location: String) -> String {
        var description = location.precomposedStringWithCanonicalMapping.lowercased()
        var scheme: String?
        if let range = description.range(of: #"\A[a-z][a-z0-9+.-]*://"#, options: .regularExpression) {
            scheme = String(description[range].dropLast(3))
            description.removeSubrange(range)
        }
        let authorityEnd = description.firstIndex(of: "/") ?? description.endIndex
        if let at = description[..<authorityEnd].lastIndex(of: "@") {
            description.removeSubrange(...at)
        }
        let hostEnd = description.firstIndex(of: "/") ?? description.endIndex
        if let range = description[..<hostEnd].range(of: #":[0-9]+\z"#, options: .regularExpression) {
            description.removeSubrange(range)
        }
        if let fragment = description.firstIndex(of: "#") { description.removeSubrange(fragment...) }
        if let query = description.firstIndex(of: "?") { description.removeSubrange(query...) }
        if scheme == nil || scheme == "ssh", let colon = description.firstIndex(of: ":"),
            colon < (description.firstIndex(of: "/") ?? description.endIndex)
        {
            description.replaceSubrange(colon...colon, with: "/")
        }
        var components = description.split(whereSeparator: { $0 == "/" || $0 == "\\" }).map {
            $0.removingPercentEncoding ?? String($0)
        }
        if let last = components.popLast() {
            components.append(last.hasSuffix(".git") ? String(last.dropLast(4)) : last)
        }
        let path = components.joined(separator: "/")
        return scheme == "file" || location.hasPrefix("/") ? "/" + path : path
    }

    public static func identity(_ location: String) -> String {
        var value = Substring(location)
        if value.last == "/" || value.last == "\\" { value = value.dropLast() }
        if let separator = value.lastIndex(where: { $0 == "/" || $0 == "\\" }) {
            value = value[value.index(after: separator)...]
        }
        if value.hasSuffix(".git") { value = value.dropLast(4) }
        return value.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// The last path component without `.git`, as written.
    static func name(_ location: String) -> String {
        var value = Substring(location)
        while value.last == "/" { value = value.dropLast() }
        if let separator = value.lastIndex(where: { $0 == "/" || $0 == ":" }) {
            value = value[value.index(after: separator)...]
        }
        return String(value.hasSuffix(".git") ? value.dropLast(4) : value)
    }

    static func isRemote(_ text: String) -> Bool {
        text.contains("://") || text.hasPrefix("git@") || text.hasSuffix(".git")
    }
}
