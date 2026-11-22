import Foundation
import SwiftPodsManifest

/// Records from Git's NUL-delimited tree and config output. Paths come from a remote repository and are checked
/// before anything is written.
enum GitPackageTree {
    struct Entry {
        enum Kind: Equatable {
            case directory, file(executable: Bool), symbolicLink, submodule
        }

        let path: String
        let object: String
        let kind: Kind
        let bytes: Int

        var isRegularFile: Bool {
            if case .file = kind { return true }
            return false
        }
    }

    static func parse(_ listing: Data, objectIDLength: Int, prefix: String) throws -> [Entry] {
        guard listing.isEmpty || listing.last == 0 else {
            throw SwiftPodsError("Package override has an incomplete Git tree listing")
        }
        var entries: [Entry] = []
        var paths: Set<String> = []
        for record in listing.split(separator: 0) {
            guard let tab = record.firstIndex(of: 9),
                let header = String(bytes: record[..<tab], encoding: .utf8),
                let relative = String(bytes: record[record.index(after: tab)...], encoding: .utf8)
            else { throw SwiftPodsError("Package override contains an invalid Git tree entry") }
            let path = prefix.isEmpty ? relative : prefix + "/" + relative
            guard isSafePath(path), paths.insert(path.precomposedStringWithCanonicalMapping.lowercased()).inserted else {
                throw SwiftPodsError("Package override contains an unsafe or colliding Git tree path")
            }
            if let first = path.split(separator: "/").first,
                GeneratedPackageMetadata.directories.contains(first.lowercased()),
                !GeneratedPackageMetadata.directories.contains(String(first))
            {
                throw SwiftPodsError("Package override path collides with resolver metadata on macOS")
            }
            let fields = header.split(separator: " ")
            guard fields.count == 4, fields[2].utf8.count == objectIDLength, isObjectID(String(fields[2])) else {
                throw SwiftPodsError("Package override contains an invalid Git tree object ID")
            }
            let kind: Entry.Kind
            let bytes: Int
            switch (fields[0], fields[1]) {
            case ("040000", "tree"), ("160000", "commit"):
                guard fields[3] == "-" else { throw SwiftPodsError("Package override contains an invalid tree entry size") }
                kind = fields[0] == "040000" ? .directory : .submodule
                bytes = 0
            case ("100644", "blob"), ("100755", "blob"), ("120000", "blob"):
                guard let count = Int(fields[3]), count >= 0 else {
                    throw SwiftPodsError("Package override contains an invalid blob size")
                }
                kind = fields[0] == "120000" ? .symbolicLink : .file(executable: fields[0] == "100755")
                bytes = count
            default:
                throw SwiftPodsError("Package override contains an unsupported Git tree entry type")
            }
            if GeneratedPackageMetadata.directories.contains(path), kind != .directory {
                throw SwiftPodsError("Package override metadata root must be a directory")
            }
            entries.append(Entry(path: path, object: String(fields[2]), kind: kind, bytes: bytes))
        }
        return entries
    }

    static func isObjectID(_ text: String) -> Bool {
        (text.utf8.count == 40 || text.utf8.count == 64)
            && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func isSafePath(_ path: String) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !path.contains("\\") && !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            && components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && $0.lowercased() != ".git" }
    }

    static func linkTarget(_ data: Data, at path: String) throws -> String {
        guard let target = String(data: data, encoding: .utf8), !target.isEmpty,
            !target.hasPrefix("/"), !target.contains("\\"),
            !target.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw SwiftPodsError("Package override requires a relative symbolic link at \(path)") }
        var depth = path.split(separator: "/").count - 1
        for part in target.split(separator: "/") where part != "." {
            depth += part == ".." ? -1 : 1
            guard depth >= 0 else { throw SwiftPodsError("Package override symbolic link escapes its tree at \(path)") }
        }
        return target
    }

    static func submoduleOrigins(_ config: Data, links: [Entry]) throws -> [String: String] {
        var paths: [String: String] = [:]
        var urls: [String: String] = [:]
        for entry in config.split(separator: 0) {
            guard let text = String(bytes: entry, encoding: .utf8) else {
                throw SwiftPodsError("Package override .gitmodules must be valid UTF-8")
            }
            let pair = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            guard let key = pair.first, key.hasPrefix("submodule."), let dot = key.lastIndex(of: ".") else { continue }
            let field = key[key.index(after: dot)...]
            guard field == "path" || field == "url" else { continue }
            let name = String(key[..<dot])
            guard name != "submodule", pair.count == 2 else {
                throw SwiftPodsError("Package override .gitmodules has an incomplete path or URL")
            }
            let value = String(pair[1])
            let previous = field == "path" ? paths.updateValue(value, forKey: name) : urls.updateValue(value, forKey: name)
            guard previous == nil else { throw SwiftPodsError("Package override .gitmodules repeats a path or URL") }
        }
        let linkedPaths = Set(links.map(\.path))
        var origins: [String: String] = [:]
        for (name, path) in paths where linkedPaths.contains(path) {
            guard let url = urls[name],
                url.lowercased().hasPrefix("https://") || url.lowercased().hasPrefix("ssh://"),
                PackageLocation.isSafeRemote(url)
            else { throw SwiftPodsError("Package override submodule \(path) needs an absolute HTTPS or SSH URL") }
            guard origins.updateValue(url, forKey: path) == nil else {
                throw SwiftPodsError("Package override .gitmodules declares the submodule path \(path) twice")
            }
        }
        guard origins.count == links.count else {
            throw SwiftPodsError("Package override .gitmodules is missing a path or URL for a gitlink")
        }
        return origins
    }
}
