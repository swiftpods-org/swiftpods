import Darwin
import Dispatch
import Foundation

private final class ProcessObservations {
    private let lock = NSLock()
    private(set) var succeeded = 0
    private(set) var rejected = 0
    private(set) var failed = 0
    private(set) var examples: [String] = []

    func success() {
        lock.lock()
        succeeded += 1
        lock.unlock()
    }
    func rejection() {
        lock.lock()
        rejected += 1
        lock.unlock()
    }
    func failure(_ message: String) {
        lock.lock()
        failed += 1
        if examples.count < 8 { examples.append(message) }
        lock.unlock()
    }
}

@main
struct ConcurrentProcessInput {
    static func main() throws {
        let mask = Int(CommandLine.arguments[1])!
        let destination = URL(fileURLWithPath: CommandLine.arguments[2])
        let observations = ProcessObservations()
        for descriptor: Int32 in 0...2 where mask & (1 << descriptor) != 0 { close(descriptor) }
        let group = DispatchGroup()
        for worker in 0..<8 {
            group.enter()
            Thread {
                defer { group.leave() }
                for iteration in 0..<100 {
                    let token = "\(worker)-\(iteration)"
                    if iteration % 17 == 0 {
                        do {
                            _ = try ToolProcess.run(
                                "/bin/sh", ["-c", "exit 0"], environment: ["FIELD": "before\0after"])
                            observations.failure("Invalid environment launched at " + token)
                        } catch let error as Diagnostic where error.code == "SP-PROCESS-ARGUMENT" {
                            observations.rejection()
                        } catch {
                            observations.failure("Invalid environment returned \(error)")
                        }
                    }
                    do {
                        let script =
                            "test ! -p /dev/fd/0 || exit 92; read value; printf 'read-status=%s token=%s' \"$?\" \"$1\"; printf 'error:%s' \"$1\" >&2"
                        let result = try ToolProcess.run("/bin/sh", ["-c", script, "fixture", token], environment: [:])
                        let output = String(decoding: result.output, as: UTF8.self)
                        let error = String(decoding: result.error, as: UTF8.self)
                        if result.status == 0 && output == "read-status=1 token=" + token && error == "error:" + token {
                            observations.success()
                        } else {
                            observations.failure("\(token): status=\(result.status) output=\(output) error=\(error)")
                        }
                    } catch {
                        observations.failure("\(token): \(error)")
                    }
                }
            }.start()
        }
        group.wait()
        try JSONSerialization.data(
            withJSONObject: [
                "mask": mask, "calls": 800, "succeeded": observations.succeeded,
                "rejected": observations.rejected, "failed": observations.failed, "examples": observations.examples,
            ], options: [.sortedKeys]
        ).write(to: destination)
    }
}
