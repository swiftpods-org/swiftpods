import Darwin
import Foundation

/// Runs external tools. Injected so tests can observe commands without running them.
public protocol CommandRunner: Sendable {
    /// Runs `executable` with `arguments`; returns its standard output, or throws with the end of both outputs on a
    /// non-zero exit.
    func run(_ executable: String, _ arguments: [String], in directory: URL?) throws -> String

    /// As above, for output that is not text, such as Git objects.
    func runData(_ executable: String, _ arguments: [String], in directory: URL?) throws -> Data
}

public extension CommandRunner {
    func runData(_ executable: String, _ arguments: [String], in directory: URL?) throws -> Data {
        Data(try run(executable, arguments, in: directory).utf8)
    }
}

/// Gives each command a process group for timeout handling. An interactive command runs in the foreground so that
/// Ctrl-C and terminal prompts still work. Standard output is the result, and standard error is captured for failures.
/// Standard input is empty.
public struct ProcessRunner: CommandRunner {
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 30 * 60) {
        self.timeout = timeout
    }

    public func run(_ executable: String, _ arguments: [String], in directory: URL?) throws -> String {
        String(decoding: try runData(executable, arguments, in: directory), as: UTF8.self)
    }

    public func runData(_ executable: String, _ arguments: [String], in directory: URL?) throws -> Data {
        let label = ([(executable as NSString).lastPathComponent] + arguments.prefix(2)).joined(separator: " ")
        try Interruption.check()
        // Standard output, then standard error.
        var readers: [Int32] = []
        var writers: [Int32] = []
        defer { (readers + writers).forEach { close($0) } }
        for _ in 0..<2 {
            var descriptors: [Int32] = [-1, -1]
            guard pipe(&descriptors) == 0 else {
                throw SwiftPodsError("Cannot run \(label): \(String(cString: strerror(errno)))")
            }
            readers.append(descriptors[0])
            writers.append(descriptors[1])
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, writers[0], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, writers[1], STDERR_FILENO)
        if let directory {
            posix_spawn_file_actions_addchdir_np(&actions, directory.path)
        }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        let terminal = open("/dev/tty", O_RDWR | O_NOCTTY | O_CLOEXEC)
        defer { if terminal >= 0 { close(terminal) } }
        let previousGroup = getpgrp()
        let hasTerminal = terminal >= 0 && tcgetpgrp(terminal) == previousGroup
        let dispositions = Interruption.dispositions
        let startsSuspended = hasTerminal && !dispositions.handled.isEmpty
        // Only the three standard descriptors reach the command; restore signals SwiftPods may have changed.
        let groupResult = posix_spawnattr_setpgroup(&attributes, 0)
        guard groupResult == 0 else {
            throw SwiftPodsError("Cannot set the process group for \(label): \(String(cString: strerror(groupResult)))")
        }
        var spawnFlags = POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETPGROUP
        // Set up the relay before the tool can try to read the terminal and stop its whole group with SIGTTIN.
        if startsSuspended { spawnFlags |= POSIX_SPAWN_START_SUSPENDED }
        let flagsResult = posix_spawnattr_setflags(&attributes, Int16(spawnFlags))
        guard flagsResult == 0 else {
            throw SwiftPodsError("Cannot configure \(label): \(String(cString: strerror(flagsResult)))")
        }
        var defaults = sigset_t()
        sigfillset(&defaults)
        for number in dispositions.ignored { sigdelset(&defaults, number) }
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attributes, &mask)

        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        let environment = Self.environment(ProcessInfo.processInfo.environment)
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { envp.forEach { free($0) } }
        var pid: pid_t = 0
        let spawned = executable.contains("/")
            ? posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
            : posix_spawnp(&pid, executable, &actions, &attributes, argv, envp)
        writers.forEach { close($0) }
        writers = []
        guard spawned == 0 else {
            throw SwiftPodsError("Cannot run \(label): \(String(cString: strerror(spawned)))")
        }
        var reaped = false
        defer {
            if !reaped, (try? Self.childEvent(pid)) != nil {
                kill(-pid, SIGKILL)
                _ = Self.reap(pid)
            }
        }

        var relay: TerminalSignalRelay?
        if startsSuspended {
            relay = try TerminalSignalRelay(group: pid, signals: dispositions.handled)
            _ = try Self.childEvent(pid, reportingStops: true)
            try Interruption.check()
        }
        let ownsTerminal = hasTerminal && tcgetpgrp(terminal) == previousGroup
            && Self.setForegroundGroup(pid, on: terminal)
        if startsSuspended || ownsTerminal { kill(-pid, SIGCONT) }
        func restoreTerminal() {
            guard ownsTerminal else { return }
            let foreground = tcgetpgrp(terminal)
            if foreground == pid || foreground <= 0 { _ = Self.setForegroundGroup(previousGroup, on: terminal) }
        }
        defer { restoreTerminal() }

        var outputs = [Data(), Data()]
        var open = [true, true]
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        var exited = false
        var timedOut = false
        var interruption: Int32?
        var deadline = ProcessInfo.processInfo.systemUptime + timeout
        var forceDeadline: TimeInterval?
        // A descendant (a build service, an ssh multiplexer) can keep the pipe open after the command exits.
        var drainDeadline = TimeInterval.infinity
        while !exited || (open.contains(true) && ProcessInfo.processInfo.systemUptime < drainDeadline) {
            let streams = readers.indices.filter { open[$0] }
            if !streams.isEmpty {
                var descriptors = streams.map { pollfd(fd: readers[$0], events: Int16(POLLIN), revents: 0) }
                if poll(&descriptors, nfds_t(descriptors.count), 100) > 0 {
                    for (stream, descriptor) in zip(streams, descriptors) where descriptor.revents != 0 {
                        let count = read(descriptor.fd, &buffer, buffer.count)
                        if count > 0 {
                            outputs[stream].append(contentsOf: buffer[0..<count])
                        } else if count == 0 || (errno != EINTR && errno != EAGAIN) {
                            open[stream] = false
                        }
                    }
                }
            } else {
                usleep(20_000)
            }
            let now = ProcessInfo.processInfo.systemUptime
            let event = exited ? .exited : try Self.childEvent(pid, reportingStops: ownsTerminal && forceDeadline == nil)
            var terminalSignal = try relay?.readSignal()
            if !exited && event == .exited {
                exited = true
                drainDeadline = now + 2
                // Close the relay's input and read its pending notifications before reaping the group leader.
                restoreTerminal()
                if let relay {
                    let pending = try relay.finish()
                    terminalSignal = terminalSignal ?? pending
                }
                relay = nil
            }
            if let terminalSignal { Interruption.record(terminalSignal) }
            if interruption == nil, let number = Interruption.received {
                interruption = number
                if terminalSignal != number { kill(-pid, number) }
                forceDeadline = forceDeadline ?? now + 5
            }
            if event == .stopped && interruption == nil && !timedOut {
                // Present the suspension to the parent shell as a stop of its SwiftPods job.
                restoreTerminal()
                kill(-previousGroup, SIGTSTP)
                if tcgetpgrp(terminal) == previousGroup { _ = Self.setForegroundGroup(pid, on: terminal) }
                kill(-pid, SIGCONT)
                deadline += ProcessInfo.processInfo.systemUptime - now
                continue
            }
            if !exited && interruption == nil && !timedOut && now >= deadline {
                timedOut = true
                kill(-pid, SIGTERM)
                forceDeadline = now + 5
            }
            if let force = forceDeadline, exited || now >= force {
                kill(-pid, SIGKILL)
                forceDeadline = nil
            }
        }

        // Guard the final drain as well. The unreaped leader still holds the process group ID.
        if interruption == nil, let number = Interruption.received {
            interruption = number
            kill(-pid, SIGKILL)
        }
        guard let status = Self.reap(pid) else {
            throw SwiftPodsError("Cannot wait for \(label): \(String(cString: strerror(errno)))")
        }
        reaped = true
        if let interruption { throw Interruption.error(interruption) }
        let signal = status & 0x7f
        let code = signal == 0 ? (status >> 8) & 0xff : 128 + signal
        guard !timedOut, code == 0 else {
            let reason = timedOut ? "timed out after \(Int(timeout)) seconds" : "failed (exit \(code))"
            throw SwiftPodsError("\(label) \(reason)" + Self.tail(outputs[0] + outputs[1]))
        }
        return outputs[0]
    }

    private enum ChildEvent { case running, stopped, exited }

    /// Leaves an exited leader unreaped until its process group can be released safely.
    private static func childEvent(_ pid: pid_t, reportingStops: Bool = false) throws -> ChildEvent {
        var info = siginfo_t()
        let flags = WEXITED | WNOHANG | WNOWAIT | (reportingStops ? WSTOPPED : 0)
        if waitid(P_PID, id_t(pid), &info, flags) != 0 {
            if errno == EINTR { return .running }
            throw SwiftPodsError("Cannot wait for command: \(String(cString: strerror(errno)))")
        }
        guard info.si_pid == pid else { return .running }
        if info.si_code == CLD_STOPPED {
            var stopped = siginfo_t()
            _ = waitid(P_PID, id_t(pid), &stopped, WSTOPPED | WNOHANG)
            return stopped.si_pid == pid ? .stopped : .running
        }
        return .exited
    }

    fileprivate static func reap(_ pid: pid_t) -> Int32? {
        var status: Int32 = 0
        var result: pid_t
        repeat { result = waitpid(pid, &status, 0) } while result < 0 && errno == EINTR
        return result == pid ? status : nil
    }

    private static func setForegroundGroup(_ group: pid_t, on terminal: Int32) -> Bool {
        // The runner is in the background while it returns the terminal to its own group.
        var signals = sigset_t()
        sigemptyset(&signals)
        sigaddset(&signals, SIGTTOU)
        var previous = sigset_t()
        guard pthread_sigmask(SIG_BLOCK, &signals, &previous) == 0 else { return false }
        defer { pthread_sigmask(SIG_SETMASK, &previous, nil) }
        return tcsetpgrp(terminal, group) == 0
    }

    /// The last lines of a command's output, for an error message.
    static func tail(_ data: Data) -> String {
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").suffix(20)
        return lines.isEmpty ? "" : ":\n" + lines.map { "  | " + $0 }.joined(separator: "\n")
    }

    /// The caller's environment, except variables that would point Git at another repository, and without
    /// credential prompts that would wait forever in CI.
    static func environment(_ input: [String: String]) -> [String: String] {
        var environment = input
        for key in [
            "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES",
            "GIT_COMMON_DIR", "GIT_NAMESPACE", "GIT_PREFIX",
        ] {
            environment.removeValue(forKey: key)
        }
        environment["GIT_TERMINAL_PROMPT"] = "0"
        return environment
    }
}

/// A process in the foreground tool's group observes SIGINT and SIGHUP even if the tool handles or ignores them.
/// It reports signals over a private socket, independent of the tool's standard streams and exit status.
private final class TerminalSignalRelay {
    /// Signals the terminal can send. SIGTERM, which the runner itself sends on a timeout, stays ignored.
    private static let events: [(number: Int32, name: String, byte: UInt8)] = [
        (SIGINT, "INT", UInt8(ascii: "I")), (SIGHUP, "HUP", UInt8(ascii: "H")),
    ]
    private let pid: pid_t
    private let socket: Int32
    private var eof = false

    init(group: pid_t, signals: Set<Int32>) throws {
        var sockets: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else {
            throw SwiftPodsError("Cannot open the terminal signal relay: \(String(cString: strerror(errno)))")
        }
        let reader = sockets[0]
        var writer = sockets[1]
        defer { if writer >= 0 { close(writer) } }
        var started: pid_t = 0
        do {
            let active = Self.events.filter { signals.contains($0.number) }
            // These are shell builtins only. The socket keeps the relay blocked until the runner closes its input.
            // Ctrl-Z leaves the relay running, since a tool that ignores it may finish without being continued.
            let traps = ["trap '' TSTP"] + active.map { "trap 'printf \(UnicodeScalar($0.byte))' \($0.name)" }
            let script = (traps + ["printf R", "IFS= read -r line"]).joined(separator: "\n")
            var actions: posix_spawn_file_actions_t?
            posix_spawn_file_actions_init(&actions)
            defer { posix_spawn_file_actions_destroy(&actions) }
            posix_spawn_file_actions_adddup2(&actions, writer, STDIN_FILENO)
            posix_spawn_file_actions_adddup2(&actions, writer, STDOUT_FILENO)
            posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)

            var attributes: posix_spawnattr_t?
            posix_spawnattr_init(&attributes)
            defer { posix_spawnattr_destroy(&attributes) }
            posix_spawnattr_setpgroup(&attributes, group)
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT
                | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
            var set = sigset_t()
            sigemptyset(&set)
            for event in active { sigaddset(&set, event.number) }
            posix_spawnattr_setsigdefault(&attributes, &set)
            sigemptyset(&set)
            posix_spawnattr_setsigmask(&attributes, &set)
            let argv = ["sh", "-c", script].map { strdup($0) } + [nil]
            defer { argv.forEach { free($0) } }
            let result = posix_spawn(&started, "/bin/sh", &actions, &attributes, argv, [nil])
            guard result == 0 else {
                throw SwiftPodsError("Cannot start the terminal signal relay: \(String(cString: strerror(result)))")
            }
            close(writer)
            writer = -1
            let byte = try Self.readByte(reader, wait: 2_000)
            guard byte == UInt8(ascii: "R"), getpgid(started) == group else {
                throw SwiftPodsError("Terminal signal relay did not join the command's process group")
            }
        } catch {
            close(reader)
            if started != 0 {
                kill(started, SIGKILL)
                _ = ProcessRunner.reap(started)
            }
            throw error
        }
        pid = started
        socket = reader
    }

    deinit {
        close(socket)
        kill(pid, SIGKILL)
        _ = ProcessRunner.reap(pid)
    }

    func readSignal() throws -> Int32? {
        try receive(wait: 0)
    }

    /// Once the terminal is back with SwiftPods, collects any signals delivered before that handoff. A relay that does
    /// not finish reported nothing and is killed on release; the command's result stands.
    func finish() throws -> Int32? {
        shutdown(socket, SHUT_WR)
        return try receive(wait: 2_000)
    }

    private func receive(wait: Int32) throws -> Int32? {
        guard !eof, let byte = try Self.readByte(socket, wait: wait) else { return nil }
        if byte == 0 {
            eof = true
            return nil
        }
        guard let event = Self.events.first(where: { $0.byte == byte }) else {
            throw SwiftPodsError("Invalid terminal signal relay notification")
        }
        return event.number
    }

    /// Returns nil on timeout and zero on EOF. Relay messages are single ASCII bytes.
    private static func readByte(_ socket: Int32, wait: Int32) throws -> UInt8? {
        var descriptor = pollfd(fd: socket, events: Int16(POLLIN), revents: 0)
        let end = ProcessInfo.processInfo.systemUptime + Double(wait) / 1_000
        var wait = wait
        repeat {
            let ready = poll(&descriptor, 1, wait)
            if ready == 0 { return nil }
            if ready > 0 {
                var byte: UInt8 = 0
                let count = read(socket, &byte, 1)
                if count >= 0 { return byte }
            }
            guard errno == EINTR else {
                throw SwiftPodsError("Cannot read from the terminal signal relay: \(String(cString: strerror(errno)))")
            }
            let remaining = end - ProcessInfo.processInfo.systemUptime
            if remaining <= 0 { return nil }
            wait = Int32((remaining * 1_000).rounded(.up))
        } while true
    }
}
