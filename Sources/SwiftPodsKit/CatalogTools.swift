import Foundation
import SwiftPodsManifest

/// Commands for working with catalogs rather than projects.
public enum CatalogTools {
    /// Every file under a catalog's `Packages/` directory, at any depth, sorted by path.
    static func files(_ directory: URL) -> [URL] {
        let packages = directory.appendingPathComponent("Packages", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: packages, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        else { return [] }
        return enumerator.compactMap { $0 as? URL }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted { $0.path < $1.path }
    }

    /// Problems in a catalog checkout: unreadable entries, names that differ from file names, duplicates.
    public static func lint(_ directory: URL) -> [String] {
        let packages = directory.appendingPathComponent("Packages", isDirectory: true)
        guard FileManager.default.fileExists(atPath: packages.path) else { return ["\(packages.path) does not exist"] }
        var problems: [String] = []
        var names: [String: String] = [:]
        var locations: [String: String] = [:]
        for file in files(directory) {
            let label = Paths.relative(from: packages, to: file)
            guard file.pathExtension == "podfile" else {
                problems.append("\(label): catalog files end in .podfile")
                continue
            }
            let expected = file.deletingPathExtension().lastPathComponent
            do {
                let entry = try CatalogEntry.parse(String(contentsOf: file, encoding: .utf8), file: file.path, source: directory.path)
                if entry.name != expected { problems.append("\(label): declares `\(entry.name)`, expected `\(expected)`") }
                if let other = names[entry.name.lowercased()] {
                    problems.append("\(label): `\(entry.name)` is already declared by \(other)")
                }
                names[entry.name.lowercased()] = label
                let location = PackageLocation.canonical(entry.url)
                if let other = locations[location] {
                    problems.append("\(label): \(entry.url) is already declared by \(other)")
                }
                locations[location] = label
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
        var result: [CatalogEntry] = []
        for source in sources {
            for name in try catalog.names(source) where name.lowercased().contains(text.lowercased()) {
                if let entry = try catalog.entry(named: name, in: [source]) { result.append(entry) }
            }
        }
        return result
    }
}
