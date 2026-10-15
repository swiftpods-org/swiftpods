import Foundation
import Darwin
import ProcessSupport

final class NativeChildProcess {
    let pid: pid_t
    private var status: Int32?
    init(executable: String, arguments: [String], directory: URL?, environment: [String: String], input: Int32 = STDIN_FILENO, output: Int32, error: Int32) throws {
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.sorted(by: { $0.key < $1.key }).map { strdup($0.key + "=" + $0.value) } + [nil]
        defer { for value in argv + envp { free(value) } }
        var child: pid_t = 0
        let result = argv.withUnsafeBufferPointer { args in envp.withUnsafeBufferPointer { env in
            if let directory { return directory.path.withCString { sp_child_spawn(executable, args.baseAddress!, env.baseAddress!, $0, input, output, error, &child) } }
            return sp_child_spawn(executable, args.baseAddress!, env.baseAddress!, nil, input, output, error, &child)
        } }
        guard result == 0 else { throw Diagnostic(result == ECANCELED ? "SP-CANCELLED" : "SP-PROCESS-SPAWN", stage: "execute", "Cannot start " + URL(fileURLWithPath: executable).lastPathComponent + ": " + String(cString: strerror(result))) }
        pid = child
    }
    @discardableResult func wait() -> Int32 { if let status { return status }; let result = sp_child_wait(pid); status = result; return result }
    func terminate() { if status == nil { sp_child_terminate(pid); _ = wait() } }
    deinit { terminate() }
}
