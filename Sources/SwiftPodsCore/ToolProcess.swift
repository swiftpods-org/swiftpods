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

enum ToolProcess {
    static func run(
        _ executable: String, _ arguments: [String], directory: URL? = nil,
        environment: [String: String]? = nil
    ) throws -> ToolOutput {
        let stdout = Pipe()
        let stderr = Pipe()
        let capture = ToolCapture()
        let group = DispatchGroup()
        let process = try NativeChildProcess(
            executable: executable, arguments: arguments, directory: directory,
            environment: environment ?? ProcessInfo.processInfo.environment,
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
