import Foundation

/// Validates the shared command envelope before project code or tools execute.
struct NativeCommandRequest {
    let action: String
    let arguments: [String]
    let project: URL

    init(_ tokens: [String], project: URL? = nil) throws {
        guard let action = tokens.first, !action.isEmpty else {
            throw Diagnostic("SP-CLI-ARGUMENT", stage: "cli", "A command is required")
        }
        var arguments = Array(tokens.dropFirst())
        let path = try CommandOptions.take("--project-directory", from: &arguments)
        self.action = action
        self.arguments = arguments
        self.project = URL(fileURLWithPath: path ?? project?.path ?? FileManager.default.currentDirectoryPath)
            .standardizedFileURL.resolvingSymlinksInPath()
    }
}
