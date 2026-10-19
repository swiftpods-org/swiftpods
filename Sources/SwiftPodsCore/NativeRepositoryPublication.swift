import Foundation

/// Commits against a private copy, preserving the registered checkout on rejection.
final class NativeRepositoryPublication {
    let directory: URL
    let staging: URL
    private let backup: URL
    private let fingerprint: String
    private let manager = FileManager.default

    init(directory: URL) throws {
        guard
            (try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(".git").path)[.type])
                as? FileAttributeType == .typeDirectory
        else { throw Diagnostic("SP-REPO-GIT", stage: "repo", "Publication requires an independent Git checkout") }
        self.directory = directory
        let identity = UUID().uuidString
        staging = directory.deletingLastPathComponent().appendingPathComponent(".publish-" + identity)
        backup = directory.deletingLastPathComponent().appendingPathComponent(".publish-backup-" + identity)
        fingerprint = try FileFingerprint.tree(directory)
        do {
            // Copy Git config, hooks, local commits and ignored files as well.
            try manager.copyItem(at: directory, to: staging)
        } catch {
            try? manager.removeItem(at: staging)
            throw error
        }
    }

    func publish(_ record: [String: Any], repositories: NativeRepositories) throws {
        guard try FileFingerprint.tree(directory) == fingerprint else {
            throw Diagnostic(
                "SP-REPO-CONFLICT", stage: "repo", "Repository changed during publication", file: directory.path)
        }
        try manager.moveItem(at: directory, to: backup)
        do {
            try manager.moveItem(at: staging, to: directory)
            try repositories.write(record)
        } catch {
            do {
                if manager.fileExists(atPath: directory.path) { try manager.moveItem(at: directory, to: staging) }
                try manager.moveItem(at: backup, to: directory)
            } catch {
                throw Diagnostic(
                    "SP-REPO-RECOVERY", stage: "repo", "Original checkout is preserved at " + backup.path,
                    file: directory.path)
            }
            throw error
        }
        try? manager.removeItem(at: backup)
    }

    deinit { try? manager.removeItem(at: staging) }
}
