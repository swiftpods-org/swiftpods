import Foundation

/// Immutable dependencies and dispatch for commands that do not run the installation engine.
struct CLIContext {
    let arguments: [String]
    let command: String
    let environmentName: String?
    let directory: URL
    let environment: [String: String]
    let executable: URL
    let redactor: Redactor
    let machine: Bool
    let bundle: RuntimeBundle?

    init(
        options: CommandOptions.Global, environment: [String: String], executable: URL, redactor: Redactor,
        machine: Bool
    ) throws {
        arguments = options.arguments
        command = arguments.first ?? "help"
        environmentName = options.environment
        self.environment = environment
        self.executable = executable
        self.redactor = redactor
        self.machine = machine
        bundle = try? RuntimeBundle.locate(environment: environment, executable: executable)
        directory = try Self.projectDirectory(
            path: options.projectDirectory, command: command, hardened: arguments.contains("--hardened"))
    }

    /// A nil result delegates the invocation to the native engine and its project transaction.
    func runCommand() throws -> Int32? {
        switch command {
        case "env": return try runEnvironment()
        case "__archivecheck": return try checkArchive()
        case "runtime": return try verifyRuntime()
        case "__cache": return try accessContentStore()
        case "cache" where arguments.dropFirst().first == "verify": return try verifyCache()
        case "cache": return try runMaintenance()
        case "repo" where arguments.dropFirst().first != "push": return try runMaintenance()
        case "__treecheck": return try checkTree()
        case "version", "--version": return try runVersion()
        case "doctor", "migrate": return try runDoctor()
        case "graph", "why":
            guard !arguments.contains("--refresh") else { return nil }
            return try readGraph()
        case "recover": return try recover()
        case "integrity": return try runIntegrity()
        default: return nil
        }
    }

    func managedBundle() throws -> RuntimeBundle {
        try bundle ?? RuntimeBundle.locate(environment: environment, executable: executable)
    }

    func output(_ object: [String: Any]) throws {
        try CLI.output(object, redactor: redactor)
    }

    private static func projectDirectory(path supplied: String?, command: String, hardened: Bool) throws -> URL {
        let path = supplied ?? FileManager.default.currentDirectoryPath
        let explicit = supplied != nil
        let result = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: result.path, isDirectory: &directory), directory.boolValue else {
            throw Diagnostic("SP-CLI-DIRECTORY", stage: "cli", "Project directory does not exist", file: result.path)
        }
        if !explicit && command != "init" {
            var candidate = result
            while candidate.path != "/" {
                if NativePodfilePath.find(in: candidate, hardened: hardened) != nil {
                    return candidate
                }
                candidate.deleteLastPathComponent()
            }
        }
        return result
    }
}
