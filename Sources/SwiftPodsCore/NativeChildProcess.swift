import Darwin
import Foundation
import ProcessSupport

final class NativeChildProcess {
    let pid: pid_t
    private var status: Int32?
    init(
        executable: String, arguments: [String], directory: URL?, environment: [String: String],
        input: Int32, output: Int32, error: Int32
    ) throws {
        guard !executable.utf8.contains(0), !arguments.contains(where: { $0.utf8.contains(0) }),
            !environment.contains(where: { $0.key.utf8.contains(0) || $0.value.utf8.contains(0) }),
            directory.map({ !$0.path.utf8.contains(0) }) ?? true
        else {
            throw Diagnostic("SP-PROCESS-ARGUMENT", stage: "execute", "Process inputs cannot contain NUL")
        }
        guard environment.keys.allSatisfy(NativeProcessEnvironment.isValidName) else {
            throw Diagnostic(
                "SP-PROCESS-ARGUMENT", stage: "execute",
                "Environment variable names must be nonempty and cannot contain '='")
        }
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.sorted(by: { $0.key < $1.key }).map { strdup($0.key + "=" + $0.value) } + [nil]
        defer { for value in argv + envp { free(value) } }
        var child: pid_t = 0
        let result = argv.withUnsafeBufferPointer { args in
            envp.withUnsafeBufferPointer { env in
                if let directory {
                    return directory.path.withCString {
                        sp_child_spawn(
                            executable, args.baseAddress!, env.baseAddress!, $0, input, output, error, &child)
                    }
                }
                return sp_child_spawn(
                    executable, args.baseAddress!, env.baseAddress!, nil, input, output, error, &child)
            }
        }
        guard result == 0 else {
            throw Diagnostic(
                result == ECANCELED ? "SP-CANCELLED" : "SP-PROCESS-SPAWN", stage: "execute",
                "Cannot start " + URL(fileURLWithPath: executable).lastPathComponent + ": "
                    + String(cString: strerror(result)))
        }
        pid = child
    }
    @discardableResult func wait() -> Int32 {
        if let status { return status }
        let result = sp_child_wait(pid)
        status = result
        return result
    }
    func terminate() {
        if status == nil {
            sp_child_terminate(pid)
            _ = wait()
        }
    }
    deinit { terminate() }
}
