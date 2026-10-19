import Darwin
import Dispatch
import Foundation

struct ToolOutput {
    let status: Int32
    let output: Data
    let error: Data
}

private final class ToolCapture {
    var output = Data()
    var error = Data()
}

private final class ToolStreams {
    // A borrowed fallback descriptor must remain open until capture pipes exist.
    // Allocate streams and release fallback owners under the same lock.
    private static let lock = NSLock()
    let input: Int32
    private let fallback: Int32
    let stdout: Pipe
    let stderr: Pipe

    init() throws {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        var fallback: Int32 = -1
        var input = fcntl(STDIN_FILENO, F_DUPFD_CLOEXEC, STDERR_FILENO + 1)
        if input < 0, errno == EBADF {
            fallback = open("/dev/null", O_RDONLY | O_CLOEXEC)
            if fallback >= 0 { input = fcntl(fallback, F_DUPFD_CLOEXEC, STDERR_FILENO + 1) }
        }
        guard input >= 0 else {
            let error = errno
            if fallback >= 0 { close(fallback) }
            throw Diagnostic(
                "SP-PROCESS-SPAWN", stage: "execute",
                "Cannot open child standard input: " + String(cString: strerror(error)))
        }
        self.input = input
        self.fallback = fallback
        stdout = Pipe()
        stderr = Pipe()
    }

    deinit {
        Self.lock.lock()
        close(input)
        if fallback >= 0 { close(fallback) }
        Self.lock.unlock()
    }
}

enum ToolProcess {
    static func run(
        _ executable: String, _ arguments: [String], directory: URL? = nil,
        environment: [String: String]? = nil
    ) throws -> ToolOutput {
        let streams = try ToolStreams()
        defer { withExtendedLifetime(streams) {} }
        let stdout = streams.stdout
        let stderr = streams.stderr
        let capture = ToolCapture()
        let group = DispatchGroup()
        let inherited = environment ?? ProcessInfo.processInfo.environment
        let childEnvironment = executable == "/usr/bin/git" ? NativeGitEnvironment.isolated(inherited) : inherited
        let process = try NativeChildProcess(
            executable: executable, arguments: arguments, directory: directory,
            environment: childEnvironment,
            input: streams.input,
            output: stdout.fileHandleForWriting.fileDescriptor, error: stderr.fileHandleForWriting.fileDescriptor)
        try stdout.fileHandleForWriting.close()
        try stderr.fileHandleForWriting.close()
        group.enter()
        DispatchQueue.global().async {
            capture.output = stdout.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            capture.error = stderr.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let status = process.wait()
        group.wait()
        return ToolOutput(status: status, output: capture.output, error: capture.error)
    }
}
