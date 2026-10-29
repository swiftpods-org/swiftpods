import Foundation

/// Runs external tools. Injected so tests can observe commands without running them.
public protocol CommandRunner: Sendable {
    /// Runs `executable` with `arguments`; returns combined output, or throws with it on a non-zero exit.
    func run(_ executable: String, _ arguments: [String], in directory: URL?) throws -> String
}

public struct ProcessRunner: CommandRunner {
    public init() {}

    public func run(_ executable: String, _ arguments: [String], in directory: URL?) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        // Never wait for credentials: an unknown repository must fail, not prompt.
        process.environment = ProcessInfo.processInfo.environment.merging(["GIT_TERMINAL_PROMPT": "0"]) { _, new in new }
        if let directory { process.currentDirectoryURL = directory }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            let tail = text.split(separator: "\n").suffix(20).joined(separator: "\n")
            throw SwiftPodsError(
                "\((executable as NSString).lastPathComponent) \(arguments.first ?? "") failed with status \(process.terminationStatus)"
                    + (tail.isEmpty ? "" : ":\n" + tail))
        }
        return text
    }
}
