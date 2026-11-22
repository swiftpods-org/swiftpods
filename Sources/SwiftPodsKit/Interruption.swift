import Darwin
import Dispatch
import Foundation

/// Lets SIGINT, SIGTERM and SIGHUP end SwiftPods through its rollback rather than at an arbitrary instruction.
///
/// After `install()` such a signal is only recorded. `ProcessRunner` passes it on to the running command's process
/// group and fails, and `check()` fails before the next command and where an install commits its work, so the install
/// rolls back. `endIfReceived()` then ends SwiftPods by the same signal, and the shell or tool that started it sees an
/// interrupted command. A signal ignored when SwiftPods started, such as SIGHUP under `nohup`, stays ignored.
public enum Interruption {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var signal: Int32?
        var installed = false
        var sources: [Int32: DispatchSourceSignal] = [:]
        var ignored: Set<Int32> = []
    }

    private static let state = State()

    public static func install() {
        state.lock.lock()
        defer { state.lock.unlock() }
        guard !state.installed else { return }
        state.installed = true
        for number in [SIGINT, SIGTERM, SIGHUP] {
            // Dispatch observes the signal; ignoring it keeps the default action from ending the process first.
            let previous = signal(number, SIG_IGN)
            if unsafeBitCast(previous, to: Int.self) == unsafeBitCast(SIG_IGN, to: Int.self) {
                state.ignored.insert(number)
                continue
            }
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { record(number) }
            source.resume()
            state.sources[number] = source
        }
    }

    static var dispositions: (handled: Set<Int32>, ignored: Set<Int32>) {
        state.lock.lock()
        defer { state.lock.unlock() }
        return (Set(state.sources.keys), state.ignored)
    }

    /// The first signal received, if any.
    static var received: Int32? {
        state.lock.lock()
        defer { state.lock.unlock() }
        return state.signal
    }

    static func record(_ number: Int32) {
        state.lock.lock()
        defer { state.lock.unlock() }
        if state.signal == nil { state.signal = number }
    }

    /// Forgets a recorded signal; for tests.
    static func reset() {
        state.lock.lock()
        defer { state.lock.unlock() }
        state.signal = nil
    }

    /// Fails once a signal was received.
    static func check() throws {
        if let number = received { throw error(number) }
    }

    static func error(_ number: Int32) -> SwiftPodsError {
        SwiftPodsError("Interrupted by \(name(number))")
    }

    static func name(_ number: Int32) -> String {
        switch number {
        case SIGINT: "SIGINT"
        case SIGTERM: "SIGTERM"
        case SIGHUP: "SIGHUP"
        default: "signal \(number)"
        }
    }

    /// Ends SwiftPods by the signal it received, once its work is complete or rolled back.
    public static func endIfReceived() {
        guard let number = received else { return }
        signal(number, SIG_DFL)
        var signals = sigset_t()
        sigemptyset(&signals)
        sigaddset(&signals, number)
        sigprocmask(SIG_UNBLOCK, &signals, nil)
        raise(number)
        exit(128 + number)
    }
}
