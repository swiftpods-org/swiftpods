import Foundation
import SwiftPodsManifest

/// Commands for working with catalogs rather than projects.
public enum CatalogTools {
    /// Every file and link under a catalog's `Packages/` directory, at any depth, sorted by path.
    static func files(_ directory: URL) -> [URL] {
        let packages = directory.appendingPathComponent("Packages", isDirectory: true).standardizedFileURL
        guard let enumerator = FileManager.default.enumerator(at: packages, includingPropertiesForKeys: nil) else { return [] }
        return enumerator.compactMap { $0 as? URL }
            .filter { !FileTree.isDirectory($0) }
            .map(\.standardizedFileURL)
            .sorted { $0.path < $1.path }
    }

    /// Problems in a catalog checkout: unreadable entries, names that differ from file names, duplicates.
    public static func lint(_ directory: URL) -> [String] {
        let packages = directory.appendingPathComponent("Packages", isDirectory: true)
        guard FileManager.default.fileExists(atPath: packages.path) else { return ["\(packages.path) does not exist"] }
        var problems: [String] = []
        var names: [String: String] = [:]
        var locations: [String: String] = [:]
        for url in files(directory) {
            let label = Paths.relative(from: packages.standardizedFileURL, to: url)
            if (try? FileTree.status(url).st_mode & S_IFMT) == S_IFLNK {
                problems.append("\(label): catalog entries cannot be symbolic links")
                continue
            }
            guard url.pathExtension == "podfile" else {
                problems.append("\(label): catalog files end in .podfile")
                continue
            }
            let expected = url.deletingPathExtension().lastPathComponent
            do {
                guard let text = String(data: try Data(contentsOf: url), encoding: .utf8) else {
                    problems.append("\(label): not valid UTF-8")
                    continue
                }
                let entry = try CatalogEntry.parse(text, file: url.path, source: directory.path)
                if entry.name != expected { problems.append("\(label): declares `\(entry.name)`, expected `\(expected)`") }
                if let other = names[entry.name.lowercased()] {
                    problems.append("\(label): `\(entry.name)` is already declared by \(other)")
                }
                names[entry.name.lowercased()] = label
                if let url = entry.url {
                    let location = PackageLocation.fetchIdentity(url)
                    if let other = locations[location] {
                        problems.append("\(label): \(url) is already declared by \(other)")
                    }
                    locations[location] = label
                }
            } catch let error as ManifestError {
                problems.append(error.description)
            } catch {
                problems.append("\(label): \(error)")
            }
        }
        return problems
    }

    /// Catalog entries whose name contains `text`, case-insensitively.
    public static func search(
        _ text: String, sources: [Source], runner: CommandRunner = ProcessRunner(), cache: URL? = nil, update: Bool = false
    ) throws -> [CatalogEntry] {
        let catalog = GitCatalog(cache: cache ?? GitCatalog.defaultCache, runner: runner, update: update, offline: false)
        let needle = text.precomposedStringWithCanonicalMapping.lowercased()
        var result: [CatalogEntry] = []
        for source in sources {
            for name in try catalog.names(source)
            where name.precomposedStringWithCanonicalMapping.lowercased().contains(needle) {
                if let entry = try catalog.entry(named: name, in: [source]) { result.append(entry) }
            }
        }
        return result
    }
}
