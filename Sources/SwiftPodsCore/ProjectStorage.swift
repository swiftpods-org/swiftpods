import Darwin
import Foundation

/// Keeps each Podfile's private state in one repository-level directory.
struct ProjectStorage {
    let project: URL
    let root: URL
    let directory: URL

    init(project: URL) {
        let project = project.standardizedFileURL.resolvingSymlinksInPath()
        self.project = project
        var repository = project
        while !FileManager.default.fileExists(atPath: repository.appendingPathComponent(".git").path) {
            if repository.path == "/" {
                repository = project
                break
            }
            repository = repository.deletingLastPathComponent().standardizedFileURL
        }
        root = repository.appendingPathComponent(".swiftpods")
        if repository == project {
            directory = root
        } else {
            let relative = project.pathComponents.dropFirst(repository.pathComponents.count).joined(separator: "/")
            let name = project.lastPathComponent.utf8.map { byte -> UInt8 in
                (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
                    || byte == 45 || byte == 95 ? byte : 45
            }
            let key = String(decoding: name.prefix(48), as: UTF8.self) + "-" + digest(Data(relative.utf8))
            directory = root.appendingPathComponent("projects").appendingPathComponent(key)
        }
    }

    private var legacy: URL { project.appendingPathComponent(".swiftpods") }

    /// Read-only commands can inspect installations made by an older release.
    var existingDirectory: URL {
        attributes(directory) == nil && attributes(legacy) != nil ? legacy : directory
    }

    func file(_ name: String) -> URL { existingDirectory.appendingPathComponent(name) }

    var directories: [URL] {
        directory == root ? [root] : [root, root.appendingPathComponent("projects"), directory]
    }

    func validate(code: String = "SP-STATE-PATH", stage: String = "prepare") throws {
        for path in Set(directories + [legacy]) {
            if let value = attributes(path), value[.type] as? FileAttributeType != .typeDirectory {
                throw Diagnostic(
                    code, stage: stage, "SwiftPods state must use directories without symlinks", file: path.path)
            }
        }
    }

    /// Returns only newly created directories, so failed imports can remove them.
    @discardableResult func prepare() throws -> [URL] {
        try validate()
        var created: [URL] = []
        do {
            for path in directories.dropLast() {
                if try createDirectory(path) { created.append(path) }
            }
            if directory.path != legacy.path, attributes(legacy) != nil {
                try migrateLegacy()
            }
            if try createDirectory(directory) { created.append(directory) }
            try validate()
            return created
        } catch {
            for path in created.reversed() { _ = rmdir(path.path) }
            throw error
        }
    }

    private func migrateLegacy() throws {
        guard attributes(directory) == nil else {
            throw Diagnostic(
                "SP-STATE-MIGRATION", stage: "prepare",
                "Both legacy and repository state exist; preserve and inspect both directories before continuing",
                file: legacy.path)
        }
        let descriptor = open(legacy.appendingPathComponent("process.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            throw Diagnostic("SP-STATE-LOCK", stage: "prepare", "Cannot open legacy project process lock")
        }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw Diagnostic(
                "SP-STATE-BUSY", stage: "prepare", "Another SwiftPods mutation is running for this project")
        }
        guard renamex_np(legacy.path, directory.path, UInt32(RENAME_EXCL)) == 0 else {
            throw Diagnostic(
                "SP-STATE-MIGRATION", stage: "prepare", "Cannot move legacy state into the repository directory",
                file: legacy.path)
        }
    }

    private func attributes(_ path: URL) -> [FileAttributeKey: Any]? {
        try? FileManager.default.attributesOfItem(atPath: path.path)
    }

    private func createDirectory(_ path: URL) throws -> Bool {
        if mkdir(path.path, 0o700) == 0 { return true }
        if errno == EEXIST, attributes(path)?[.type] as? FileAttributeType == .typeDirectory { return false }
        throw Diagnostic("SP-STATE-PATH", stage: "prepare", "Cannot create SwiftPods state directory", file: path.path)
    }
}
