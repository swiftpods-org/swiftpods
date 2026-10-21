import Foundation

extension CLIContext {
    func runEnvironment() throws -> Int32 {
        let options = Array(arguments.dropFirst(2))
        let action = arguments.dropFirst().first ?? "list"
        switch action {
        case "shim": try createEnvironmentShim(options: options)
        case "list": try listEnvironmentProfiles(options: options)
        case "import": try importEnvironment(options: options)
        default:
            throw Diagnostic("SP-CLI-ARGUMENT", stage: "cli", "Use env import, env list or env shim")
        }
        return 0
    }

    private func createEnvironmentShim(options: [String]) throws {
        var options = options
        guard let path = try CommandOptions.take("--directory", from: &options), options.isEmpty else {
            throw Diagnostic("SP-CLI-ARGUMENT", stage: "cli", "Use env shim --directory PATH")
        }
        let parent = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let target = parent.appendingPathComponent("pod")
        try FileManager.default.createSymbolicLink(
            at: target, withDestinationURL: executable.resolvingSymlinksInPath())
        try output(
            [
                "schema_version": 1, "status": "created", "path": target.path,
                "target": executable.resolvingSymlinksInPath().path, "path_modified": false,
            ])
    }

    private func listEnvironmentProfiles(options: [String]) throws {
        guard options.isEmpty else {
            throw Diagnostic("SP-CLI-ARGUMENT", stage: "cli", "Unknown env list option")
        }
        let parent = ProjectStorage(project: directory).file("environments")
        let paths =
            (try? FileManager.default.contentsOfDirectory(
                at: parent, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        let profiles = paths.compactMap { path -> [String: Any]? in
            guard let profile = try? readObject(path.appendingPathComponent("profile.json")) else {
                return nil
            }
            return [
                "name": profile["name"] ?? path.lastPathComponent, "gems": profile["gems"] ?? [],
                "plugins": profile["plugins"] ?? [],
            ]
        }
        try output(
            [
                "schema_version": 1,
                "profiles": profiles.sorted {
                    ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "")
                },
            ])
    }

    private func importEnvironment(options: [String]) throws {
        var options = options
        let local = options.contains("--local")
        options.removeAll { $0 == "--local" }
        let managed = try managedBundle()
        guard let path = try CommandOptions.take("--gemfile", from: &options) else {
            throw Diagnostic(
                "SP-CLI-ARGUMENT", stage: "cli", "Use env import --gemfile Gemfile [--name NAME]")
        }
        let gemfile = URL(fileURLWithPath: path, relativeTo: directory).standardizedFileURL
            .resolvingSymlinksInPath()
        let name =
            try CommandOptions.take("--name", from: &options)
            ?? EnvironmentProfile.defaultName(gemfile: gemfile)
        guard options.isEmpty else {
            throw Diagnostic("SP-CLI-ARGUMENT", stage: "cli", "Unknown environment import option")
        }
        try output(
            EnvironmentProfile.importProfile(
                name: name, gemfile: gemfile, project: directory, bundle: managed, environment: environment,
                local: local))
    }
}
