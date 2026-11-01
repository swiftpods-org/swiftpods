import Foundation

/// Swift Package Manager's identity rules for package locations. Spellings that
/// differ only in scheme, credentials, port, case, `.git` suffix or scp-style SSH
/// syntax name one package; distinct locations with one identity cannot coexist.
public enum PackageLocation {
    /// A syntactically authenticated network endpoint for a supported Git
    /// location. Reachability and public-address policy are deliberately left
    /// to the caller so parsing a manifest never performs DNS.
    public struct RemoteEndpoint: Sendable, Equatable {
        public enum Transport: Sendable, Equatable {
            case https
            case ssh
        }

        public let transport: Transport
        public let host: String
        public let port: Int

        fileprivate init(transport: Transport, host: String, port: Int) {
            self.transport = transport
            self.host = host
            self.port = port
        }
    }

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
        if let separator = value.lastIndex(where: { $0 == "/" || $0 == "\\" || $0 == ":" }) {
            value = value[value.index(after: separator)...]
        }
        if value.hasSuffix(".git") { value = value.dropLast(4) }
        return value.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// A repository's fetch origin. Unlike ``canonical(_:)``, this keeps the
    /// transport, port, path case and percent encoding: those can select
    /// different content even when Swift Package Manager gives both locations
    /// the same package identity.
    public static func fetchIdentity(_ location: String) -> String {
        if let scp = scpLocation(location) {
            return "ssh://git@\(scp.host.lowercased())\(repositoryPath(scp.path))"
        }
        guard let components = URLComponents(string: location), let scheme = components.scheme?.lowercased(),
            let host = components.host?.lowercased()
        else { return location.precomposedStringWithCanonicalMapping }
        var result = scheme + "://"
        if let user = components.user, !user.isEmpty { result += user + "@" }
        result += host
        if let port = components.port { result += ":\(port)" }
        result += repositoryPath(components.percentEncodedPath)
        return result.precomposedStringWithCanonicalMapping
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

    /// Remote package and catalog transports SwiftPods permits. HTTPS is the
    /// default; SSH remains supported for private repositories. Git URLs never
    /// carry passwords, query strings or fragments.
    public static func isSafeRemote(_ text: String) -> Bool {
        remoteEndpoint(text) != nil
    }

    /// Parses a supported remote without resolving it. The returned host never
    /// includes IPv6 brackets, which lets network callers apply one DNS and
    /// address policy to URL and scp-style SSH spellings.
    public static func remoteEndpoint(_ text: String) -> RemoteEndpoint? {
        guard !text.isEmpty, !text.hasPrefix("-"), !hasControlOrWhitespace(text), !text.contains("\\") else { return nil }
        if let scp = scpLocation(text) {
            guard safeRemoteHost(scp.host), safeRepositoryPath(scp.path) else { return nil }
            return RemoteEndpoint(transport: .ssh, host: normalizedRemoteHost(scp.host), port: 22)
        }
        guard let components = URLComponents(string: text), let scheme = components.scheme?.lowercased(),
            scheme == "https" || scheme == "ssh", let host = components.host, safeRemoteHost(host),
            components.password == nil, components.query == nil, components.fragment == nil,
            let authority = rawAuthority(text), !authority.contains("%"),
            safeRepositoryPath(components.percentEncodedPath)
        else { return nil }
        let port = components.port ?? (scheme == "https" ? 443 : 22)
        guard (1...65_535).contains(port) else { return nil }
        if scheme == "https" {
            guard components.user == nil else { return nil }
            return RemoteEndpoint(transport: .https, host: normalizedRemoteHost(host), port: port)
        }
        guard components.user.map(safeSSHUser) ?? true else { return nil }
        return RemoteEndpoint(transport: .ssh, host: normalizedRemoteHost(host), port: port)
    }

    /// HTTPS archive locations accepted for binary downloads. Query strings
    /// remain supported for signed CDN URLs, but authority credentials and URL
    /// fragments are forbidden so logs and download clients cannot interpret a
    /// different origin or leak embedded secrets.
    public static func isSafeHTTPSDownloadURL(_ text: String) -> Bool {
        guard !text.isEmpty, !hasControlOrWhitespace(text), !text.contains("\\"),
            let components = URLComponents(string: text), components.scheme?.lowercased() == "https",
            components.host?.isEmpty == false, components.user == nil, components.password == nil,
            components.fragment == nil
        else { return false }
        return true
    }

    /// A local binary archive URL used by development and tests. Only an
    /// unambiguous absolute local path is accepted; remote file authorities,
    /// credentials, traversal, query strings and fragments are rejected.
    public static func isSafeLocalFileURL(_ text: String) -> Bool {
        guard text.lowercased().hasPrefix("file://"), !hasControlOrWhitespace(text), !text.contains("\\"),
            let components = URLComponents(string: text), components.scheme?.lowercased() == "file",
            components.user == nil, components.password == nil, components.port == nil,
            components.query == nil, components.fragment == nil,
            components.host == nil || components.host == "" || components.host?.lowercased() == "localhost",
            components.percentEncodedPath.hasPrefix("/"), components.percentEncodedPath != "/",
            !components.percentEncodedPath.lowercased().contains("%2f"),
            let decodedPath = components.percentEncodedPath.removingPercentEncoding,
            !decodedPath.contains("\\"), !hasControl(decodedPath)
        else { return false }
        let pathComponents = decodedPath.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        return !pathComponents.isEmpty && pathComponents.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    /// Catalogs may additionally be local absolute paths or local file URLs.
    public static func isSafeCatalogSource(_ text: String) -> Bool {
        guard text.utf8.count <= 4_096 else { return false }
        if isSafeRemote(text) { return true }
        guard !text.isEmpty, !text.hasPrefix("-"), !hasControl(text) else { return false }
        if text.hasPrefix("/") { return true }
        guard let components = URLComponents(string: text), components.scheme?.lowercased() == "file",
            components.user == nil, components.password == nil, components.port == nil,
            components.query == nil, components.fragment == nil,
            components.host == nil || components.host == "" || components.host?.lowercased() == "localhost",
            components.percentEncodedPath.hasPrefix("/")
        else { return false }
        return true
    }

    /// Whether text appears intended as a repository location, including an
    /// invalid one. This lets the manifest report a transport error rather than
    /// treating a malformed URL as a catalog package name.
    static func looksLikeRemote(_ text: String) -> Bool {
        text.contains("://") || text.contains("@") || text.hasSuffix(".git") || text.hasPrefix("-")
    }

    static func isRemote(_ text: String) -> Bool { isSafeRemote(text) }

    /// Paths selected inside an SDK archive. Subdirectories and spaces are
    /// supported, while traversal, control characters and build/shell variable
    /// syntax are not.
    static func isSafeArchivePath(_ path: String, extension pathExtension: String) -> Bool {
        guard path.utf8.count <= 4_096, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("$"),
            !path.contains("`"), !hasControl(path)
        else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
            let last = components.last, last.count > pathExtension.count + 1
        else { return false }
        return last.lowercased().hasSuffix("." + pathExtension.lowercased())
    }

    /// Text that will become one generated path or file-list entry.
    static func isSafePathText(_ text: String) -> Bool {
        isSafeMetadataText(text)
    }

    /// A name or generated-file scalar that may contain spaces and punctuation,
    /// but must remain one bounded, printable value.
    static func isSafeMetadataText(_ text: String, maximumBytes: Int = 4_096) -> Bool {
        !text.isEmpty && text.utf8.count <= maximumBytes && !hasControl(text)
    }

    /// Whether `path` is an unambiguous slash-separated relative path. Callers that use a directory descriptor can
    /// leave `allowingParentComponents` false to guarantee the component walk stays beneath that descriptor.
    public static func isSafeRelativePath(_ path: String, allowingParentComponents: Bool = false) -> Bool {
        guard isSafePathText(path), !path.hasPrefix("/"), !path.contains("\\") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !components.isEmpty && components.allSatisfy {
            !$0.isEmpty && $0 != "." && (allowingParentComponents || $0 != "..")
        }
    }

    /// Resolves existing symlinks and compares whole path components. Callers
    /// that write through a manifest-selected path should check this as close
    /// as possible to the filesystem operation, in addition to lexical checks.
    public static func isPath(_ path: String, containedIn directory: String) -> Bool {
        let root = URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        let candidate = URL(fileURLWithPath: path, relativeTo: root).standardizedFileURL.resolvingSymlinksInPath()
        let rootComponents = root.pathComponents
        let candidateComponents = candidate.pathComponents
        guard candidateComponents.count >= rootComponents.count else { return false }
        return candidateComponents.prefix(rootComponents.count).elementsEqual(rootComponents)
    }

    private static func repositoryPath(_ path: String) -> String {
        var result = path
        while result.count > 1 && result.hasSuffix("/") { result.removeLast() }
        if result.hasSuffix(".git") { result.removeLast(4) }
        return result.hasPrefix("/") ? result : "/" + result
    }

    private static func safeRepositoryPath(_ path: String) -> Bool {
        let value = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        return !components.isEmpty && components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func safeSSHUser(_ user: String) -> Bool {
        guard !user.isEmpty, !user.hasPrefix("-") else { return false }
        return user.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._+-".unicodeScalars.contains($0))
        }
    }

    private static func safeRemoteHost(_ host: String) -> Bool {
        guard !host.isEmpty, !host.hasPrefix("-"), !host.contains("%") else { return false }
        if host.hasPrefix("[") || host.hasSuffix("]") {
            guard host.first == "[", host.last == "]" else { return false }
            let address = host.dropFirst().dropLast()
            return !address.isEmpty && address.contains(":") && address.unicodeScalars.allSatisfy {
                $0.isASCII && (CharacterSet(charactersIn: "0123456789abcdefABCDEF:.").contains($0))
            }
        }
        return host.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || ".-_".unicodeScalars.contains($0))
        }
    }

    private static func normalizedRemoteHost(_ host: String) -> String {
        if host.first == "[", host.last == "]" { return String(host.dropFirst().dropLast()) }
        return host
    }

    private static func rawAuthority(_ text: String) -> Substring? {
        guard let scheme = text.range(of: "://") else { return nil }
        let suffix = text[scheme.upperBound...]
        let end = suffix.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) ?? suffix.endIndex
        return suffix[..<end]
    }

    private static func scpLocation(_ text: String) -> (host: String, path: String)? {
        guard text.hasPrefix("git@") else { return nil }
        let hostStart = text.index(text.startIndex, offsetBy: 4)
        let colon: String.Index
        if hostStart < text.endIndex, text[hostStart] == "[" {
            guard let closing = text[hostStart...].firstIndex(of: "]") else { return nil }
            let separator = text.index(after: closing)
            guard separator < text.endIndex, text[separator] == ":" else { return nil }
            colon = separator
        } else {
            guard let separator = text[hostStart...].firstIndex(of: ":") else { return nil }
            colon = separator
        }
        guard colon > hostStart else { return nil }
        let pathStart = text.index(after: colon)
        guard pathStart < text.endIndex else { return nil }
        return (String(text[hostStart..<colon]), String(text[pathStart...]))
    }

    private static func hasControl(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    private static func hasControlOrWhitespace(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespaces.contains($0) }
    }
}
