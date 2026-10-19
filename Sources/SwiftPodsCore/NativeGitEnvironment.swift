import Foundation

/// Scope Git to the selected checkout while retaining transport credentials
/// and caller configuration (including GIT_CONFIG_COUNT/http.extraHeader).
enum NativeGitEnvironment {
    private static let repositoryVariables: Set<String> = [
        "GIT_DIR", "GIT_COMMON_DIR", "GIT_WORK_TREE", "GIT_IMPLICIT_WORK_TREE", "GIT_INDEX_FILE",
        "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_QUARANTINE_PATH",
        "GIT_GRAFT_FILE", "GIT_SHALLOW_FILE", "GIT_PREFIX", "GIT_INTERNAL_SUPER_PREFIX", "GIT_CONFIG",
    ]

    static func isolated(_ environment: [String: String]) -> [String: String] {
        environment.filter { !repositoryVariables.contains($0.key) }
    }
}
