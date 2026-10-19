import Foundation

/// Receipts cover generated project files, so stale cleanup preserves user edits.
enum NativeProjectInventory {
    static func path(_ relative: String, root: URL) throws -> URL {
        guard
            !relative.utf8.contains(0),
            // NSString regex ranges preserve separators before combining marks.
            (relative as NSString).range(
                of: #"\A[^/\r\n]+\.xcodeproj/(?:project\.pbxproj|xcshareddata/xcschemes/[^/\r\n]+\.xcscheme)\z"#,
                options: .regularExpression
            ).location != NSNotFound
        else {
            throw Diagnostic("SP-XCODE-INVENTORY", stage: "integrate", "Invalid generated project file", file: relative)
        }
        let path = root.appendingPathComponent(relative).standardizedFileURL
        guard NativePath.isDescendant(path.resolvingSymlinksInPath(), of: root.resolvingSymlinksInPath()) else {
            throw Diagnostic(
                "SP-XCODE-INVENTORY", stage: "integrate", "Generated project file escapes Pods", file: relative)
        }
        return path
    }
    static func load(_ url: URL, root: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let value = try readObject(url)
        guard value["schema_version"] as? Int == 1, let files = value["files"] as? [String: String],
            let products = value["products"] as? [String],
            products.allSatisfy({ $0.range(of: #"\A[A-Fa-f0-9]{24}\z"#, options: .regularExpression) != nil })
        else { throw Diagnostic("SP-XCODE-INVENTORY", stage: "integrate", "Invalid project inventory", file: url.path) }
        for (relative, hash) in files {
            _ = try path(relative, root: root)
            guard hash.range(of: #"\A[0-9a-f]{64}\z"#, options: .regularExpression) != nil else {
                throw Diagnostic("SP-XCODE-INVENTORY", stage: "integrate", "Invalid project receipt", file: relative)
            }
        }
        return value
    }
    static func clean(previous: [String: String], current: Set<String>, root: URL) throws {
        for (relative, expected) in previous.sorted(by: { $0.key < $1.key }) where !current.contains(relative) {
            let file = try path(relative, root: root)
            guard FileManager.default.fileExists(atPath: file.path), try FileFingerprint.file(file) == expected else {
                continue
            }
            try FileManager.default.removeItem(at: file)
            var directory = file.deletingLastPathComponent()
            while NativePath.isDescendant(directory, of: root),
                (try FileManager.default.contentsOfDirectory(atPath: directory.path)).isEmpty
            {
                try FileManager.default.removeItem(at: directory)
                directory = directory.deletingLastPathComponent()
            }
        }
    }
}

extension NativeXcode {
    func saveProjectInventory() throws {
        let root = project.appendingPathComponent("Pods")
        let projects = [podsProject] + generatedProjects.keys.sorted().compactMap { generatedProjects[$0] }
        var files: [String: String] = [:]
        for file in Set(projects.map(\.url)).union(managedSchemes) {
            guard let components = NativePath.relativeComponents(of: file, to: root), !components.isEmpty else {
                throw Diagnostic(
                    "SP-XCODE-INVENTORY", stage: "integrate", "Project file is outside Pods", file: file.path)
            }
            let relative = components.joined(separator: "/")
            _ = try NativeProjectInventory.path(relative, root: root)
            files[relative] = try FileFingerprint.file(file)
        }
        try NativeProjectInventory.clean(
            previous: previousInventory["files"] as? [String: String] ?? [:], current: Set(files.keys), root: root)
        let products = previousProducts.union(
            targetIDs.compactMap { graph.objects[$0]?["productReference"] as? String }
        ).sorted()
        let value: [String: Any] = ["schema_version": 1, "products": products, "files": files]
        try FileManager.default.createDirectory(
            at: projectInventoryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try jsonData(value).write(to: projectInventoryURL, options: .atomic)
    }
}
