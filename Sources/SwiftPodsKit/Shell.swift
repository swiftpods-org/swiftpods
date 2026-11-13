import Darwin
import Foundation

/// Structured process metadata lets security-sensitive callers make retry decisions without parsing diagnostics.
struct CommandExecutionFailure: Sendable {
    enum Reason: Sendable, Equatable {
        case timedOut
        case outputLimit
        case interrupted(Int32)
        case exitStatus(Int32)
    }

    let reason: Reason
    let output: Data
}

/// Immutable vnode identity captured from an already-open executable. Security-sensitive callers pass this alongside
/// the descriptor so ProcessRunner can authenticate the child's mapped image while it is still kernel-suspended.
struct ProcessExecutableIdentity {
    let descriptor: Int32
    private let status: stat

    init(descriptor: Int32) throws {
        var status = stat()
        guard descriptor > STDERR_FILENO, fstat(descriptor, &status) == 0 else {
            throw SwiftPodsError("Cannot snapshot the expected command executable")
        }
        self.descriptor = descriptor
        self.status = status
    }

    func validateDescriptor() throws {
        var current = stat()
        guard fstat(descriptor, &current) == 0, sameSnapshot(current) else {
            throw SwiftPodsError("Expected command executable changed before launch")
        }
    }

    func matchesMappedExecutable(_ mapped: vinfo_stat) -> Bool {
        mapped.vst_dev == UInt32(bitPattern: status.st_dev)
            && mapped.vst_ino == status.st_ino
            && mapped.vst_mode == status.st_mode
            && mapped.vst_nlink == status.st_nlink
            && mapped.vst_uid == status.st_uid
            && mapped.vst_gid == status.st_gid
            && mapped.vst_size == status.st_size
            && mapped.vst_mtime == Int64(status.st_mtimespec.tv_sec)
            && mapped.vst_mtimensec == Int64(status.st_mtimespec.tv_nsec)
            && mapped.vst_ctime == Int64(status.st_ctimespec.tv_sec)
            && mapped.vst_ctimensec == Int64(status.st_ctimespec.tv_nsec)
    }

    private func sameSnapshot(_ current: stat) -> Bool {
        current.st_dev == status.st_dev && current.st_ino == status.st_ino
            && current.st_mode == status.st_mode && current.st_nlink == status.st_nlink
            && current.st_uid == status.st_uid && current.st_gid == status.st_gid
            && current.st_size == status.st_size
            && current.st_mtimespec.tv_sec == status.st_mtimespec.tv_sec
            && current.st_mtimespec.tv_nsec == status.st_mtimespec.tv_nsec
            && current.st_ctimespec.tv_sec == status.st_ctimespec.tv_sec
            && current.st_ctimespec.tv_nsec == status.st_ctimespec.tv_nsec
    }
}

/// Runs external tools. Injected so tests can observe commands without running them.
public protocol CommandRunner: Sendable {
    /// Runs `executable` with `arguments`; returns combined output, or throws with it on a non-zero exit.
    func run(_ executable: String, _ arguments: [String], in directory: URL?) throws -> String

    /// As above, but asks the runner to stop the command after `timeout` seconds.
    func run(_ executable: String, _ arguments: [String], in directory: URL?, timeout: TimeInterval) throws -> String

    /// Raw-output variants for callers whose integrity checks must not pass through Unicode decoding.
    func runData(_ executable: String, _ arguments: [String], in directory: URL?) throws -> Data
    func runData(_ executable: String, _ arguments: [String], in directory: URL?, timeout: TimeInterval) throws -> Data
    func runData(
        _ executable: String, _ arguments: [String], in directory: URL?, timeout: TimeInterval, maximumOutputBytes: Int
    ) throws -> Data

    /// Runs a bounded command while explicitly inheriting the supplied descriptors in addition to stdio and the
    /// runner's opaque supervision token. Security-sensitive callers use this for already-authenticated files.
    func runData(
        _ executable: String, _ arguments: [String], in directory: URL?, timeout: TimeInterval,
        maximumOutputBytes: Int, passingFileDescriptors: [Int32]
    ) throws -> Data
}

public extension CommandRunner {
    /// Keeps existing injected runners source-compatible at compile time, but bounded production calls fail closed.
    /// A runner that launches a process must implement the bounded requirements instead of silently discarding them.
    func run(_ executable: String, _ arguments: [String], in directory: URL?, timeout: TimeInterval) throws -> String {
        throw SwiftPodsError("Command runner does not implement bounded execution")
    }

    /// Existing String-based injected runners remain source-compatible.
    func runData(_ executable: String, _ arguments: [String], in directory: URL?) throws -> Data {
        Data(try run(executable, arguments, in: directory).utf8)
    }

    func runData(_ executable: String, _ arguments: [String], in directory: URL?, timeout: TimeInterval) throws -> Data {
        throw SwiftPodsError("Command runner does not implement bounded raw execution")
    }

    func runData(
        _ executable: String, _ arguments: [String], in directory: URL?, timeout: TimeInterval, maximumOutputBytes: Int
    ) throws -> Data {
        throw SwiftPodsError("Command runner does not implement bounded streaming output")
    }

    func runData(
        _ executable: String, _ arguments: [String], in directory: URL?, timeout: TimeInterval,
        maximumOutputBytes: Int, passingFileDescriptors: [Int32]
    ) throws -> Data {
        guard passingFileDescriptors.isEmpty else {
            throw SwiftPodsError("Command runner does not support explicit file-descriptor inheritance")
        }
        return try runData(
            executable, arguments, in: directory, timeout: timeout, maximumOutputBytes: maximumOutputBytes)
    }
}

public struct ProcessRunner: CommandRunner {
    private let defaultTimeout: TimeInterval
    private let defaultMaximumOutputBytes: Int

    /// Commands are bounded by default, while leaving enough time and diagnostics for Xcode and package resolution.
    public init(timeout: TimeInterval = 30 * 60, maximumOutputBytes: Int = 64 * 1_024 * 1_024) {
        defaultTimeout = timeout
        defaultMaximumOutputBytes = maximumOutputBytes
    }

    /// Installs command-line signal handling once for the current process. Catchable termination signals first stop and
    /// reap every registered command tree, then are re-raised with their default disposition so shells and CI retain the
    /// conventional signal exit status. Embedders opt in explicitly instead of having ProcessRunner replace their policy.
    public static func installTerminationSignalHandlers() {
        ProcessTerminationCoordinator.shared.install()
    }

    /// Finishes a pending signal after synchronous command unwinding. When no signal was received this is a no-op.
    public static func terminateIfSignalWasReceived() {
        ProcessTerminationCoordinator.shared.terminateIfRequested()
    }

    public func run(_ executable: String, _ arguments: [String], in directory: URL?) throws -> String {
        String(decoding: try runData(executable, arguments, in: directory), as: UTF8.self)
    }

    public func run(_ executable: String, _ arguments: [String], in directory: URL?, timeout: TimeInterval) throws -> String {
        String(decoding: try runData(executable, arguments, in: directory, timeout: timeout), as: UTF8.self)
    }

    public func runData(_ executable: String, _ arguments: [String], in directory: URL?) throws -> Data {
        try runData(executable, arguments, in: directory, timeout: defaultTimeout)
    }

    public func runData(_ executable: String, _ arguments: [String], in directory: URL?, timeout: TimeInterval) throws -> Data {
        try runData(
            executable, arguments, in: directory, timeout: timeout, maximumOutputBytes: defaultMaximumOutputBytes)
    }

    public func runData(
        _ executable: String, _ arguments: [String], in directory: URL?, timeout: TimeInterval, maximumOutputBytes: Int
    ) throws -> Data {
        try runData(
            executable, arguments, in: directory, timeout: timeout, maximumOutputBytes: maximumOutputBytes,
            passingFileDescriptors: [])
    }

    public func runData(
        _ executable: String, _ arguments: [String], in directory: URL?, timeout: TimeInterval,
        maximumOutputBytes: Int, passingFileDescriptors: [Int32]
    ) throws -> Data {
        try runData(
            executable, arguments, in: directory, timeout: timeout, maximumOutputBytes: maximumOutputBytes,
            passingFileDescriptors: passingFileDescriptors, maximumPhysicalMemoryBytes: nil)
    }

    /// Runs a command under the normal process-tree supervisor while the parent independently polls the child's
    /// current and lifetime-peak physical footprint. macOS exposes no unentitled hard resident-memory rlimit; keeping
    /// this monitor in the parent means allocator pressure or a stuck parser cannot starve its own watchdog thread.
    func runData(
        _ executable: String, _ arguments: [String], in directory: URL?, timeout: TimeInterval,
        maximumOutputBytes: Int, passingFileDescriptors: [Int32], maximumPhysicalMemoryBytes: UInt64?,
        expectedExecutable: ProcessExecutableIdentity? = nil, workingDirectoryDescriptor: Int32? = nil,
        environment: [String: String]? = nil
    ) throws -> Data {
        guard timeout.isFinite else { throw SwiftPodsError("Command timeout must be finite") }
        guard maximumOutputBytes >= 0 else { throw SwiftPodsError("Command output limit cannot be negative") }
        guard maximumPhysicalMemoryBytes.map({ $0 > 0 }) ?? true else {
            throw SwiftPodsError("Command physical-memory limit must be positive")
        }
        let inheritedDescriptors = Array(Set(passingFileDescriptors)).sorted()
        guard inheritedDescriptors.allSatisfy({ descriptor in
            descriptor > STDERR_FILENO && fcntl(descriptor, F_GETFD) >= 0
        }) else { throw SwiftPodsError("Command inherited file descriptors must be valid and greater than stderr") }
        if let expectedExecutable {
            guard inheritedDescriptors.contains(expectedExecutable.descriptor) else {
                throw SwiftPodsError("Expected command executable descriptor must be inherited")
            }
            try expectedExecutable.validateDescriptor()
        }
        if let workingDirectoryDescriptor {
            guard directory == nil, workingDirectoryDescriptor > STDERR_FILENO,
                fcntl(workingDirectoryDescriptor, F_GETFD) >= 0
            else { throw SwiftPodsError("Command descriptor-backed working directory is invalid") }
            var workingStatus = stat()
            guard fstat(workingDirectoryDescriptor, &workingStatus) == 0,
                workingStatus.st_mode & S_IFMT == S_IFDIR
            else { throw SwiftPodsError("Command descriptor-backed working directory is not a directory") }
        }
        let terminationCoordinator = ProcessTerminationCoordinator.shared
        guard terminationCoordinator.beginLaunch() else {
            throw SwiftPodsError("Command launch was interrupted by a termination signal")
        }
        var launchInProgress = true
        defer {
            if launchInProgress { terminationCoordinator.endLaunch() }
        }
        let spawned = try Self.spawn(
            executable, arguments, in: directory,
            workingDirectoryDescriptor: workingDirectoryDescriptor,
            environment: environment ?? Self.sanitizedEnvironment(ProcessInfo.processInfo.environment),
            passingFileDescriptors: inheritedDescriptors)
        do {
            if let expectedExecutable {
                try Self.authenticateMappedExecutable(
                    processIdentifier: spawned.processIdentifier, expected: expectedExecutable)
            }
        } catch {
            let cleanupFailure = Self.discardSuspendedProcess(spawned)
            if let cleanupFailure {
                throw SwiftPodsError("\(error); additionally, \(cleanupFailure)")
            }
            throw error
        }
        let execution = ProcessExecution(
            processIdentifier: spawned.processIdentifier, processGroup: spawned.processIdentifier,
            output: spawned.output, trackingToken: spawned.trackingToken,
            maximumPhysicalMemoryBytes: maximumPhysicalMemoryBytes)
        execution.startTracking()
        terminationCoordinator.register(execution)
        launchInProgress = false
        terminationCoordinator.endLaunch()
        defer { terminationCoordinator.unregister(execution) }
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        let effectiveTimeout = max(0, timeout)
        timer.schedule(deadline: .now() + effectiveTimeout)
        timer.setEventHandler { execution.expire() }
        timer.resume()
        execution.resume()
        var data = Data()
        do {
            while let chunk = try spawned.output.read(upToCount: 1 << 16), !chunk.isEmpty {
                if chunk.count <= maximumOutputBytes - data.count {
                    data.append(chunk)
                } else {
                    let remaining = maximumOutputBytes - data.count
                    if remaining > 0 { data.append(chunk.prefix(remaining)) }
                    execution.exceedOutputLimit()
                }
            }
        } catch {
            execution.outputReaderDidFail(error)
        }
        execution.outputReaderDidFinish()
        // First observe the exit without reaping it. While the child remains waitable, its PID cannot be reused and
        // neither can the process-group identifier that was chosen from that PID. Stop the timer and finish all
        // identity-checked descendant cleanup before the final waitpid removes that kernel identity.
        try Self.waitForExitWithoutReaping(of: spawned.processIdentifier)
        execution.leaderDidExit()
        timer.cancel()
        execution.waitForStopCompletion()
        let terminationStatus = try Self.reap(spawned.processIdentifier)
        // A cleanup failure must never turn into success, but callers which deliberately enforce a timeout or output
        // ceiling still need the structured primary reason and the bounded bytes collected before termination.
        if let signal = execution.interruptionSignal {
            throw SwiftPodsError(
                "Command was interrupted by signal \(signal)",
                commandFailure: CommandExecutionFailure(reason: .interrupted(signal), output: data))
        }
        if execution.outputLimitExceeded {
            throw SwiftPodsError(
                "\(Self.diagnosticLabel((executable as NSString).lastPathComponent)) output is larger than \(maximumOutputBytes) bytes",
                commandFailure: CommandExecutionFailure(reason: .outputLimit, output: data))
        }
        if execution.timedOut {
            let tail = Self.diagnosticTail(data)
            let message =
                "\(Self.diagnosticLabel((executable as NSString).lastPathComponent)) \(Self.diagnosticLabel(arguments.first ?? "")) timed out after \(Int(effectiveTimeout.rounded())) seconds"
                    + (tail.isEmpty ? "" : ":\n" + tail)
            throw SwiftPodsError(
                message, commandFailure: CommandExecutionFailure(reason: .timedOut, output: data))
        }
        if let supervisionFailure = execution.supervisionFailure {
            throw SwiftPodsError(supervisionFailure)
        }
        guard terminationStatus == 0 else {
            let tail = Self.diagnosticTail(data)
            let message =
                "\(Self.diagnosticLabel((executable as NSString).lastPathComponent)) \(Self.diagnosticLabel(arguments.first ?? "")) failed with status \(terminationStatus)"
                    + (tail.isEmpty ? "" : ":\n" + tail)
            throw SwiftPodsError(
                message,
                commandFailure: CommandExecutionFailure(
                    reason: .exitStatus(terminationStatus), output: data))
        }
        return data
    }

    private struct SpawnedProcess {
        let processIdentifier: pid_t
        let output: FileHandle
        let trackingToken: ProcessTrackingToken
    }

    /// POSIX_SPAWN_START_SUSPENDED maps the new image but prevents its entry point from running. Querying the first
    /// executable region therefore closes the pathname ABA window before any substituted image can execute user code.
    private static func authenticateMappedExecutable(
        processIdentifier: pid_t, expected: ProcessExecutableIdentity
    ) throws {
        try expected.validateDescriptor()
        var region = proc_regionwithpathinfo()
        let read = withUnsafeMutablePointer(to: &region) {
            proc_pidinfo(
                processIdentifier, PROC_PIDREGIONPATHINFO, 0, $0,
                Int32(MemoryLayout<proc_regionwithpathinfo>.size))
        }
        guard read == Int32(MemoryLayout<proc_regionwithpathinfo>.size),
            region.prp_prinfo.pri_address > 0, region.prp_prinfo.pri_size > 0,
            region.prp_prinfo.pri_protection & UInt32(bitPattern: VM_PROT_EXECUTE) != 0,
            region.prp_vip.vip_vi.vi_stat.vst_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
            expected.matchesMappedExecutable(region.prp_vip.vip_vi.vi_stat)
        else {
            throw SwiftPodsError("Spawned command mapped an unauthenticated executable")
        }
    }

    /// Authentication failure happens before SIGCONT, so the child cannot have created descendants. Kill and reap it
    /// directly; never resume an image whose mapped vnode does not match the caller's pinned descriptor.
    private static func discardSuspendedProcess(_ spawned: SpawnedProcess) -> String? {
        var problems: [String] = []
        if kill(-spawned.processIdentifier, SIGKILL) != 0, errno != ESRCH {
            problems.append("cannot kill the unauthenticated command process group")
        }
        if kill(spawned.processIdentifier, SIGKILL) != 0, errno != ESRCH {
            problems.append("cannot kill the unauthenticated command leader")
        }
        var status = Int32()
        while waitpid(spawned.processIdentifier, &status, 0) < 0 {
            if errno == EINTR { continue }
            if errno != ECHILD { problems.append("cannot reap the unauthenticated command leader") }
            break
        }
        do {
            try spawned.output.close()
        } catch {
            problems.append("cannot close the unauthenticated command output")
        }
        return problems.isEmpty ? nil : problems.joined(separator: "; ")
    }

    /// `Foundation.Process` has no pre-exec process-group hook. `posix_spawn` creates the group atomically, before
    /// untrusted tooling can fork, so a timeout can address the complete command tree instead of only its leader.
    private static func spawn(
        _ executable: String, _ arguments: [String], in directory: URL?, workingDirectoryDescriptor: Int32?,
        environment: [String: String], passingFileDescriptors: [Int32]
    ) throws -> SpawnedProcess {
        guard executable.hasPrefix("/"), !executable.contains("\0") else {
            throw SwiftPodsError("Command executable must be an absolute path without NUL bytes")
        }
        guard arguments.allSatisfy({ !$0.contains("\0") }),
            environment.allSatisfy({ !$0.key.contains("\0") && !$0.value.contains("\0") })
        else { throw SwiftPodsError("Command arguments and environment cannot contain NUL bytes") }

        let descriptors = try closeOnExecPipe()
        let output = FileHandle(fileDescriptor: descriptors[0], closeOnDealloc: true)
        var writerOpen = true
        defer {
            if writerOpen { close(descriptors[1]) }
        }
        let trackingToken = try ProcessTrackingToken()

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        var result = posix_spawn_file_actions_init(&actions)
        guard result == 0 else {
            try? output.close()
            throw SwiftPodsError("Cannot initialize command file actions: \(String(cString: strerror(result)))")
        }
        defer { posix_spawn_file_actions_destroy(&actions) }
        result = posix_spawnattr_init(&attributes)
        guard result == 0 else {
            try? output.close()
            throw SwiftPodsError("Cannot initialize command attributes: \(String(cString: strerror(result)))")
        }
        defer { posix_spawnattr_destroy(&attributes) }

        for action in [
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0),
            posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDOUT_FILENO),
            posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDERR_FILENO),
            posix_spawn_file_actions_addclose(&actions, descriptors[0]),
            posix_spawn_file_actions_addclose(&actions, descriptors[1]),
        ] where action != 0 {
            try? output.close()
            throw SwiftPodsError("Cannot configure command file actions: \(String(cString: strerror(action)))")
        }
        if let workingDirectoryDescriptor {
            result = posix_spawn_file_actions_addfchdir_np(&actions, workingDirectoryDescriptor)
            guard result == 0 else {
                try? output.close()
                throw SwiftPodsError(
                    "Cannot configure descriptor-backed command working directory: \(String(cString: strerror(result)))")
            }
        } else if let directory {
            let path = directory.standardizedFileURL.path
            guard path.hasPrefix("/"), !path.contains("\0") else {
                try? output.close()
                throw SwiftPodsError("Command working directory must be an absolute path without NUL bytes")
            }
            result = path.withCString { posix_spawn_file_actions_addchdir_np(&actions, $0) }
            guard result == 0 else {
                try? output.close()
                throw SwiftPodsError("Cannot configure command working directory: \(String(cString: strerror(result)))")
            }
        }
        for descriptor in passingFileDescriptors {
            result = posix_spawn_file_actions_addinherit_np(&actions, descriptor)
            guard result == 0 else {
                try? output.close()
                throw SwiftPodsError("Cannot inherit command file descriptor: \(String(cString: strerror(result)))")
            }
        }
        result = posix_spawn_file_actions_addinherit_np(&actions, trackingToken.descriptor)
        guard result == 0 else {
            try? output.close()
            throw SwiftPodsError("Cannot inherit command tracking descriptor: \(String(cString: strerror(result)))")
        }
        result = posix_spawnattr_setpgroup(&attributes, 0)
        guard result == 0 else {
            try? output.close()
            throw SwiftPodsError("Cannot configure command process group: \(String(cString: strerror(result)))")
        }
        // The CLI temporarily ignores these signals so Dispatch can coordinate cleanup. Children must not inherit that
        // disposition: ProcessExecution's graceful SIGTERM phase depends on ordinary tools receiving termination.
        var defaultSignals = sigset_t()
        guard sigemptyset(&defaultSignals) == 0,
            sigaddset(&defaultSignals, SIGINT) == 0, sigaddset(&defaultSignals, SIGTERM) == 0
        else {
            try? output.close()
            throw SwiftPodsError("Cannot configure command termination signals")
        }
        result = posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
        guard result == 0 else {
            try? output.close()
            throw SwiftPodsError("Cannot reset command termination signals: \(String(cString: strerror(result)))")
        }
        result = posix_spawnattr_setflags(
            &attributes,
            Int16(
                POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT
                    | POSIX_SPAWN_START_SUSPENDED))
        guard result == 0 else {
            try? output.close()
            throw SwiftPodsError("Cannot enable command process group: \(String(cString: strerror(result)))")
        }

        // Native spawn chdir avoids an ambient shell entirely; exported shell functions cannot replace `cd` or
        // otherwise gain execution before the requested absolute executable starts.
        let spawnExecutable = executable
        let spawnArguments = [executable] + arguments
        let environmentArguments = environment.sorted { $0.key < $1.key }.map { $0.key + "=" + $0.value }
        var processIdentifier = pid_t()
        result = try withCStringArray(spawnArguments) { argumentVector in
            try withCStringArray(environmentArguments) { environmentVector in
                spawnExecutable.withCString {
                    posix_spawn(&processIdentifier, $0, &actions, &attributes, argumentVector, environmentVector)
                }
            }
        }
        guard result == 0 else {
            try? output.close()
            throw SwiftPodsError(
                "Cannot run \(diagnosticLabel((executable as NSString).lastPathComponent)): \(String(cString: strerror(result)))")
        }
        // Only the spawned command tree may retain this capability. Leaving the parent endpoint open would let an
        // unrelated raw fork of SwiftPods inherit it before exec and be mistaken for a supervised descendant.
        trackingToken.closeParentEndpointAfterSpawn()
        close(descriptors[1])
        writerOpen = false
        return SpawnedProcess(
            processIdentifier: processIdentifier, output: output, trackingToken: trackingToken)
    }

    static func closeOnExecPipe() throws -> [Int32] {
        var descriptors = [Int32](repeating: -1, count: 2)
        if let pipe2Result = dynamicallyCreateCloseOnExecPipe(&descriptors) {
            guard pipe2Result.result == 0 else {
                throw SwiftPodsError(
                    "Cannot create command output pipe: \(String(cString: strerror(pipe2Result.error)))")
            }
            return descriptors
        }

        // Older Darwin SDKs do not expose pipe2. POSIX_SPAWN_CLOEXEC_DEFAULT prevents these descriptors from leaking
        // through this runner's own concurrent spawns; set both descriptors close-on-exec before any untrusted child
        // is resumed, and fail rather than accepting a partially secured pipe. macOS 13...26 provide no anonymous-pipe
        // creation API with atomic CLOEXEC, so a different library doing a raw concurrent fork/exec remains a platform
        // race until the deployment floor reaches macOS 27.
        guard pipe(&descriptors) == 0 else {
            throw SwiftPodsError("Cannot create command output pipe: \(String(cString: strerror(errno)))")
        }
        for descriptor in descriptors where fcntl(descriptor, F_SETFD, FD_CLOEXEC) != 0 {
            let savedError = errno
            close(descriptors[0])
            close(descriptors[1])
            throw SwiftPodsError("Cannot secure command output pipe: \(String(cString: strerror(savedError)))")
        }
        return descriptors
    }

    /// Resolve pipe2 dynamically so the package still compiles with Swift 6.0/macOS 15 SDKs, where the declaration is
    /// absent, while using the atomic macOS 27 API whenever the running system provides it.
    private static func dynamicallyCreateCloseOnExecPipe(
        _ descriptors: inout [Int32]
    ) -> (result: Int32, error: Int32)? {
        typealias Pipe2Function = @convention(c) (UnsafeMutablePointer<Int32>?, Int32) -> Int32
        guard let handle = dlopen(nil, RTLD_LAZY | RTLD_LOCAL) else { return nil }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "pipe2") else { return nil }
        let function = unsafeBitCast(symbol, to: Pipe2Function.self)
        let result = descriptors.withUnsafeMutableBufferPointer { buffer in
            function(buffer.baseAddress, O_CLOEXEC)
        }
        return (result, result == 0 ? 0 : errno)
    }

    private static func withCStringArray<Result>(
        _ strings: [String], _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> Result
    ) throws -> Result {
        var pointers: [UnsafeMutablePointer<CChar>?] = []
        pointers.reserveCapacity(strings.count + 1)
        for string in strings {
            guard let pointer = strdup(string) else {
                for pointer in pointers { free(pointer) }
                throw SwiftPodsError("Cannot allocate command arguments")
            }
            pointers.append(pointer)
        }
        pointers.append(nil)
        defer { for pointer in pointers { free(pointer) } }
        return try pointers.withUnsafeMutableBufferPointer { buffer in
            try body(buffer.baseAddress!)
        }
    }

    private static func waitForExitWithoutReaping(of processIdentifier: pid_t) throws {
        var information = siginfo_t()
        while true {
            let result = waitid(P_PID, id_t(processIdentifier), &information, WEXITED | WNOWAIT)
            if result == 0 { return }
            if errno == EINTR { continue }
            throw SwiftPodsError("Cannot observe command exit: \(String(cString: strerror(errno)))")
        }
    }

    private static func reap(_ processIdentifier: pid_t) throws -> Int32 {
        var status = Int32()
        while true {
            let result = waitpid(processIdentifier, &status, 0)
            if result == processIdentifier { break }
            if result < 0, errno == EINTR { continue }
            throw SwiftPodsError("Cannot wait for command: \(String(cString: strerror(errno)))")
        }
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : 128 + signal
    }

    static func diagnosticText(_ text: String) -> String {
        enum EscapeState { case text, escape, controlSequence, operatingSystemCommand, operatingSystemEscape }
        var state = EscapeState.text
        var result = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            let value = scalar.value
            switch state {
            case .text:
                switch value {
                case 0x1b: state = .escape
                case 0x9b: state = .controlSequence
                case 0x9d: state = .operatingSystemCommand
                case 0x09, 0x0a: result.append(scalar)
                case 0x00...0x1f, 0x7f...0x9f: continue
                default: result.append(scalar)
                }
            case .escape:
                if value == 0x5b { state = .controlSequence }
                else if value == 0x5d { state = .operatingSystemCommand }
                else if value == 0x1b { state = .escape }
                else { state = .text }
            case .controlSequence:
                if value == 0x1b { state = .escape }
                else if value >= 0x40, value <= 0x7e { state = .text }
            case .operatingSystemCommand:
                if value == 0x07 || value == 0x9c { state = .text }
                else if value == 0x1b { state = .operatingSystemEscape }
            case .operatingSystemEscape:
                state = value == 0x5c ? .text : .operatingSystemCommand
            }
        }
        return String(result)
    }

    /// Command names and arguments are rendered into a single diagnostic line. Terminal sanitization alone is not
    /// enough here: a newline could start a GitHub Actions workflow command on the next log line.
    private static func diagnosticLabel(_ text: String) -> String {
        let sanitized = diagnosticText(text)
        var result = String.UnicodeScalarView()
        for scalar in sanitized.unicodeScalars {
            if scalar == "\t" || CharacterSet.newlines.contains(scalar) {
                result.append(" ")
            } else {
                result.append(scalar)
            }
        }
        return String(result)
    }

    private static func diagnosticTail(_ data: Data) -> String {
        let sanitized = diagnosticText(String(decoding: data, as: UTF8.self))
        let lines = sanitized.split(separator: "\n", omittingEmptySubsequences: false).suffix(20).joined(separator: "\n")
        let bounded = String(lines.suffix(16 * 1_024))
        guard !bounded.isEmpty else { return "" }
        // Prefix every physical line after truncation. Besides making subprocess output unambiguous, this prevents
        // `::error`, `::warning`, `::stop-commands`, and similar output from being interpreted by GitHub Actions.
        return bounded.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "  | " + $0 }
            .joined(separator: "\n")
    }

    static func sanitizedEnvironment(_ input: [String: String]) -> [String: String] {
        var environment = input
        for key in environment.keys
        where key.hasPrefix("GIT_") || key.hasPrefix("DYLD_") || key.hasPrefix("LD_")
            || key.hasPrefix("CURL_")
            || key.hasPrefix("BASH_FUNC_")
            || key == "BASH_ENV" || key == "ENV" || key == "CDPATH" || key == "SSH_ASKPASS"
            || key == "SHELLOPTS" || key == "BASHOPTS" || key == "BASH_XTRACEFD"
            || key == "PS4" || key == "IFS"
            || key == "TAR_OPTIONS" || key == "TAR_READER_OPTIONS" || key == "TAR_WRITER_OPTIONS"
            || key == "GZIP" || key == "GZIP_OPT" || key == "BZIP2" || key == "BZIP2OPT"
            || key == "XZ_OPT" || key == "XZ_DEFAULTS" || key == "LZMA_OPT"
            || key == "ZSTD_CLEVEL" || key == "ZSTD_NBTHREADS" || key == "ZSTD_WINDOWLOG"
            || key == "SSL_CERT_FILE" || key == "SSL_CERT_DIR" || key == "SSLKEYLOGFILE"
        {
            environment.removeValue(forKey: key)
        }
        // Keep SSH_AUTH_SOCK: agent-based authentication does not let a dependency choose a command to execute.
        environment["SSH_ASKPASS_REQUIRE"] = "never"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        return environment
    }
}

/// An inherited anonymous pipe gives the supervisor a second way to find descendants after they have both reparented
/// and changed session. Unlike a named file, another same-UID process has no pathname it can open to inject itself into
/// cleanup. The parent endpoint is closed immediately after a successful spawn, leaving the descriptor only in the
/// supervised tree. Holder discovery compares the retained kernel pipe identity behind each descriptor and the
/// holder's process start time. Public macOS APIs still cannot atomically follow a process that deliberately closes the
/// descriptor and completes a double fork between two snapshots, so ancestry/process-group tracking remains a bounded
/// fallback. Starting the leader suspended ensures both mechanisms are active before user code.
private final class ProcessTrackingToken: @unchecked Sendable {
    fileprivate struct Holder: Hashable, Sendable {
        let processIdentifier: pid_t
        let startSeconds: UInt64
        let startMicroseconds: UInt64
    }

    private struct Identity: Equatable {
        let handle: UInt64
        let peerHandle: UInt64
    }

    private static let maximumProcessIdentifiers = 131_072
    /// A descriptor table never grows past the kernel's per-process limit, but same-user services such as the virtual
    /// machine of Docker Desktop do reach 65,536 slots. The margin covers the slack proc_pidinfo adds to its estimate.
    private static let maximumDescriptorsPerProcess = max(65_536, kernelDescriptorLimitPerProcess()) + 64
    private static let maximumDescriptorsInspected = 1_000_000
    private(set) var descriptor: Int32
    private let identity: Identity

    init() throws {
        let descriptors = try ProcessRunner.closeOnExecPipe()
        close(descriptors[1])
        var information = pipe_fdinfo()
        let read = proc_pidfdinfo(
            getpid(), descriptors[0], PROC_PIDFDPIPEINFO, &information,
            Int32(MemoryLayout<pipe_fdinfo>.size))
        guard read == MemoryLayout<pipe_fdinfo>.size else {
            let savedError = errno
            close(descriptors[0])
            throw SwiftPodsError(
                "Cannot authenticate command tracking token: \(String(cString: strerror(savedError)))")
        }
        descriptor = descriptors[0]
        identity = Identity(
            handle: information.pipeinfo.pipe_handle,
            peerHandle: information.pipeinfo.pipe_peerhandle)
    }

    deinit {
        if descriptor >= 0 { close(descriptor) }
    }

    /// `posix_spawn_file_actions_addinherit_np` has already copied the endpoint into the suspended child. Keep only
    /// its immutable kernel identity in the supervisor so later raw forks cannot acquire the tracking capability.
    func closeParentEndpointAfterSpawn() {
        guard descriptor >= 0 else { return }
        close(descriptor)
        descriptor = -1
    }

    func holders(maximum: Int) throws -> [Holder] {
        var result: [Holder] = []
        var inspected = 0
        for processIdentifier in try Self.processIdentifiers() where processIdentifier > 0 {
            guard let before = Self.processInformation(processIdentifier), before.pbi_uid == geteuid() else { continue }
            guard let descriptors = try Self.fileDescriptors(of: processIdentifier) else { continue }
            inspected += descriptors.count
            guard inspected <= Self.maximumDescriptorsInspected else {
                throw SwiftPodsError("Command tracking descriptor scan exceeded its bounded work limit")
            }
            var found = false
            for candidate in descriptors where candidate.proc_fdtype == PROX_FDTYPE_PIPE {
                var information = pipe_fdinfo()
                let read = proc_pidfdinfo(
                    processIdentifier, candidate.proc_fd, PROC_PIDFDPIPEINFO, &information,
                    Int32(MemoryLayout<pipe_fdinfo>.size))
                guard read == MemoryLayout<pipe_fdinfo>.size else { continue }
                if Identity(
                    handle: information.pipeinfo.pipe_handle,
                    peerHandle: information.pipeinfo.pipe_peerhandle) == identity
                {
                    found = true
                    break
                }
            }
            guard found, let after = Self.processInformation(processIdentifier),
                after.pbi_pid == before.pbi_pid,
                after.pbi_start_tvsec == before.pbi_start_tvsec,
                after.pbi_start_tvusec == before.pbi_start_tvusec
            else { continue }
            guard result.count < maximum else {
                throw SwiftPodsError("Command process tracking exceeded \(maximum) processes")
            }
            result.append(Holder(
                processIdentifier: processIdentifier,
                startSeconds: after.pbi_start_tvsec,
                startMicroseconds: after.pbi_start_tvusec))
        }
        return result
    }

    private static func processIdentifiers() throws -> [pid_t] {
        var capacity = 1_024
        while capacity <= maximumProcessIdentifiers {
            var identifiers = [pid_t](repeating: 0, count: capacity)
            let count = identifiers.withUnsafeMutableBytes { buffer in
                proc_listallpids(buffer.baseAddress, Int32(buffer.count))
            }
            guard count >= 0 else {
                throw SwiftPodsError(
                    "Cannot enumerate command tracking processes: \(String(cString: strerror(errno)))")
            }
            if count < capacity { return Array(identifiers.prefix(Int(count))) }
            guard capacity < maximumProcessIdentifiers else {
                throw SwiftPodsError("Command tracking process scan exceeded its bounded work limit")
            }
            capacity = min(capacity * 2, maximumProcessIdentifiers)
        }
        throw SwiftPodsError("Command tracking process scan exceeded its bounded work limit")
    }

    private static func processInformation(_ processIdentifier: pid_t) -> proc_bsdinfo? {
        var information = proc_bsdinfo()
        let read = withUnsafeMutablePointer(to: &information) { pointer in
            proc_pidinfo(
                processIdentifier, PROC_PIDTBSDINFO, 0, pointer,
                Int32(MemoryLayout<proc_bsdinfo>.size))
        }
        guard read == MemoryLayout<proc_bsdinfo>.size,
            information.pbi_pid == UInt32(processIdentifier)
        else { return nil }
        return information
    }

    private static func kernelDescriptorLimitPerProcess() -> Int {
        var limit: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.maxfilesperproc", &limit, &size, nil, 0) == 0, size == MemoryLayout<Int32>.size,
            limit > 0
        else { return 0 }
        return Int(limit)
    }

    private static func fileDescriptors(of processIdentifier: pid_t) throws -> [proc_fdinfo]? {
        let stride = MemoryLayout<proc_fdinfo>.stride
        let requiredBytes = proc_pidinfo(processIdentifier, PROC_PIDLISTFDS, 0, nil, 0)
        guard requiredBytes > 0 else { return nil }
        var capacity = max(32, Int(requiredBytes) / stride + 16)
        guard capacity <= maximumDescriptorsPerProcess else {
            throw SwiftPodsError("Command tracking process \(processIdentifier) has too many open descriptors")
        }
        while capacity <= maximumDescriptorsPerProcess {
            var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
            let byteCount = descriptors.withUnsafeMutableBytes { buffer in
                proc_pidinfo(
                    processIdentifier, PROC_PIDLISTFDS, 0, buffer.baseAddress,
                    Int32(buffer.count))
            }
            guard byteCount >= 0 else { return nil }
            guard Int(byteCount) % stride == 0 else {
                throw SwiftPodsError("Command tracking descriptor enumeration returned malformed data")
            }
            if Int(byteCount) < descriptors.count * stride {
                return Array(descriptors.prefix(Int(byteCount) / stride))
            }
            guard capacity < maximumDescriptorsPerProcess else {
                throw SwiftPodsError("Command tracking process \(processIdentifier) has too many open descriptors")
            }
            capacity = min(capacity * 2, maximumDescriptorsPerProcess)
        }
        throw SwiftPodsError("Command tracking process \(processIdentifier) has too many open descriptors")
    }
}

/// Signal delivery is process-wide, while ProcessRunner instances are cheap values and may execute concurrently. This
/// coordinator owns the opt-in CLI policy and keeps each child registered until its leader is reaped and descendant
/// cleanup has completed. A launch reservation closes the small interval between posix_spawn and registration.
private final class ProcessTerminationCoordinator: @unchecked Sendable {
    static let shared = ProcessTerminationCoordinator()

    private let condition = NSCondition()
    private let signalQueue = DispatchQueue(label: "org.swiftpods.termination-signals", qos: .userInitiated)
    private var sources: [any DispatchSourceSignal] = []
    private var installed = false
    private var requestedSignal: Int32?
    private var launchesInProgress = 0
    private var executions: [ObjectIdentifier: ProcessExecution] = [:]

    private init() {}

    func install() {
        condition.lock()
        guard !installed else {
            condition.unlock()
            return
        }
        installed = true
        condition.unlock()

        var installedSources: [any DispatchSourceSignal] = []
        for signalNumber in [SIGINT, SIGTERM] {
            // Dispatch signal sources require the default action to be disabled before the source is resumed. This is
            // installed by the CLI before it can spawn a command, so there is no child-lifetime gap here.
            _ = Darwin.signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: signalQueue)
            source.setEventHandler { [self] in requestTermination(signalNumber) }
            source.resume()
            installedSources.append(source)
        }
        condition.lock()
        sources = installedSources
        condition.unlock()
    }

    func beginLaunch() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard requestedSignal == nil else { return false }
        launchesInProgress += 1
        return true
    }

    func endLaunch() {
        condition.lock()
        if launchesInProgress > 0 { launchesInProgress -= 1 }
        condition.broadcast()
        condition.unlock()
    }

    func register(_ execution: ProcessExecution) {
        condition.lock()
        executions[ObjectIdentifier(execution)] = execution
        let signalNumber = requestedSignal
        condition.unlock()
        if let signalNumber { execution.interrupt(signalNumber) }
    }

    func unregister(_ execution: ProcessExecution) {
        condition.lock()
        executions.removeValue(forKey: ObjectIdentifier(execution))
        condition.broadcast()
        condition.unlock()
    }

    func terminateIfRequested() {
        condition.lock()
        let signalNumber = requestedSignal
        condition.unlock()
        if let signalNumber { waitForCleanupAndTerminate(signalNumber) }
    }

    private func requestTermination(_ signalNumber: Int32) {
        condition.lock()
        let isFirstSignal = requestedSignal == nil
        if requestedSignal == nil { requestedSignal = signalNumber }
        let effectiveSignal = requestedSignal ?? signalNumber
        let active = Array(executions.values)
        condition.broadcast()
        condition.unlock()

        for execution in active { execution.interrupt(effectiveSignal) }
        if isFirstSignal {
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                waitForCleanupAndTerminate(effectiveSignal)
            }
        } else {
            // A repeated Ctrl-C is an explicit request to stop waiting for graceful cleanup.
            for execution in active { execution.forceTerminateForParentSignal() }
        }
    }

    private func waitForCleanupAndTerminate(_ signalNumber: Int32) -> Never {
        let gracefulDeadline = Date().addingTimeInterval(6)
        condition.lock()
        while (!executions.isEmpty || launchesInProgress > 0), Date() < gracefulDeadline {
            _ = condition.wait(until: gracefulDeadline)
        }
        var remaining = Array(executions.values)
        condition.unlock()

        if !remaining.isEmpty {
            for execution in remaining { execution.forceTerminateForParentSignal() }
            let forcedDeadline = Date().addingTimeInterval(1)
            condition.lock()
            while (!executions.isEmpty || launchesInProgress > 0), Date() < forcedDeadline {
                _ = condition.wait(until: forcedDeadline)
            }
            remaining = Array(executions.values)
            condition.unlock()
            // The normal ProcessExecution path is bounded and should have unregistered by now. Even if an unexpected
            // kernel failure prevents that, restore ordinary signal behavior rather than making SIGTERM hang forever.
            for execution in remaining { execution.forceTerminateForParentSignal() }
        }

        _ = Darwin.signal(signalNumber, SIG_DFL)
        if Darwin.raise(signalNumber) != 0 { _exit(128 + signalNumber) }
        // A default fatal disposition never returns from raise(3). Avoid converting an unexpectedly delayed delivery
        // into an ordinary exit status; remain signal-waitable instead.
        while true { _ = pause() }
    }
}

/// Dispatch callbacks are synchronized here instead of sharing mutable locals with a `@Sendable` closure.
private final class ProcessExecution: @unchecked Sendable {
    private struct ProcessIdentity: Hashable, Sendable {
        let processIdentifier: pid_t
        let startSeconds: UInt64
        let startMicroseconds: UInt64
    }

    private struct ProcessSnapshot {
        let identity: ProcessIdentity
        let parent: pid_t
        let processGroup: pid_t
        let isZombie: Bool
    }

    private static let maximumTrackedProcesses = 4_096
    private let processIdentifier: pid_t
    private let processGroup: pid_t
    private let output: FileHandle
    private let trackingToken: ProcessTrackingToken
    private let maximumPhysicalMemoryBytes: UInt64?
    private let processEventQueue = kqueue()
    private let lock = NSLock()
    private let refreshLock = NSLock()
    private let trackingReady = DispatchSemaphore(value: 0)
    private let trackingCompletion = DispatchSemaphore(value: 0)
    private let stopCompletion = DispatchSemaphore(value: 0)
    private let readerCompletion = DispatchSemaphore(value: 0)
    private var finished = false
    private var leaderExited = false
    private var resumed = false
    private var stopping = false
    private var trackingShouldStop = false
    private var readerFinished = false
    private var processEventsAvailable = false
    private var expired = false
    private var exceededOutput = false
    private var interruptedBySignal: Int32?
    private var trackedProcesses: Set<ProcessIdentity> = []
    private var watchedProcesses: Set<ProcessIdentity> = []
    private var trackingError: String?
    private var memoryProcessStartTime: UInt64?

    init(
        processIdentifier: pid_t, processGroup: pid_t, output: FileHandle,
        trackingToken: ProcessTrackingToken, maximumPhysicalMemoryBytes: UInt64?
    ) {
        self.processIdentifier = processIdentifier
        self.processGroup = processGroup
        self.output = output
        self.trackingToken = trackingToken
        self.maximumPhysicalMemoryBytes = maximumPhysicalMemoryBytes
    }

    deinit {
        if processEventQueue >= 0 { close(processEventQueue) }
    }

    var timedOut: Bool {
        lock.withLock { expired }
    }

    var outputLimitExceeded: Bool {
        lock.withLock { exceededOutput }
    }

    var supervisionFailure: String? {
        lock.withLock { trackingError }
    }

    var interruptionSignal: Int32? {
        lock.withLock { interruptedBySignal }
    }

    func startTracking() {
        let eventsAvailable = registerProcessEvents(for: processIdentifier)
        lock.withLock { processEventsAvailable = eventsAvailable }
        let thread = Thread { [self] in trackingLoop() }
        thread.name = "SwiftPods process tracker"
        thread.qualityOfService = .utility
        thread.start()
        trackingReady.wait()
    }

    func resume() {
        let shouldResume = lock.withLock { () -> Bool in
            guard !stopping else { return false }
            resumed = true
            return true
        }
        guard shouldResume else { return }
        guard kill(processIdentifier, SIGCONT) == 0 else {
            failSupervision("Cannot resume command: \(String(cString: strerror(errno)))")
            return
        }
    }

    func leaderDidExit() {
        let shouldCleanUp = lock.withLock { () -> Bool in
            leaderExited = true
            finished = true
            guard !stopping else { return false }
            stopping = true
            return true
        }
        if shouldCleanUp {
            DispatchQueue.global(qos: .utility).async { [self] in
                completeStop(initialDescendants: nil)
            }
        }
    }

    func waitForStopCompletion() {
        let shouldWait = lock.withLock { stopping }
        if shouldWait { stopCompletion.wait() }
    }

    func outputReaderDidFinish() {
        let shouldSignal = lock.withLock { () -> Bool in
            guard !readerFinished else { return false }
            readerFinished = true
            return true
        }
        if shouldSignal { readerCompletion.signal() }
    }

    func outputReaderDidFail(_ error: Error) {
        guard lock.withLock({ !expired && !exceededOutput && trackingError == nil }) else { return }
        failSupervision("Cannot read command output: \(error)")
    }

    func expire() {
        guard !lock.withLock({ finished }) else { return }
        if lock.withLock({ resumed }), Self.hasExitedWithoutReaping(processIdentifier) {
            leaderDidExit()
            return
        }
        stop(timeout: true, outputLimit: false)
    }

    func exceedOutputLimit() {
        stop(timeout: false, outputLimit: true)
    }

    func interrupt(_ signalNumber: Int32) {
        lock.withLock {
            if interruptedBySignal == nil { interruptedBySignal = signalNumber }
        }
        stop(timeout: false, outputLimit: false)
    }

    func forceTerminateForParentSignal() {
        let descendants = refreshTrackedProcesses(includeTokenHolders: true)
        sendSignal(SIGKILL, to: descendants)
        sendSignal(SIGKILL, toProcess: -processGroup, describedAs: "interrupted command process group")
        sendSignal(SIGKILL, toProcess: processIdentifier, describedAs: "interrupted command leader")
    }

    private func failSupervision(_ message: String) {
        recordSupervisionFailure(message)
        stop(timeout: false, outputLimit: false)
    }

    private func failPhysicalMemorySupervision(_ message: String) {
        recordSupervisionFailure(message)
        let shouldTerminate = lock.withLock { () -> Bool in
            guard !stopping else { return false }
            stopping = true
            return true
        }
        guard shouldTerminate else { return }
        let descendants = refreshTrackedProcesses(includeTokenHolders: true)
        // Memory containment cannot wait through the normal graceful-termination interval. The direct child remains
        // unreaped, so its PID and process-group identity cannot be recycled while these signals are sent.
        sendSignal(SIGKILL, to: descendants)
        sendSignal(SIGKILL, toProcess: -processGroup, describedAs: "memory-limited command process group")
        sendSignal(SIGKILL, toProcess: processIdentifier, describedAs: "memory-limited command leader")
        DispatchQueue.global(qos: .utility).async { [self, descendants] in
            completeStop(initialDescendants: descendants)
        }
    }

    private func recordSupervisionFailure(_ message: String) {
        lock.withLock {
            if trackingError == nil { trackingError = message }
        }
    }

    private func stop(timeout: Bool, outputLimit: Bool) {
        let shouldTerminate = lock.withLock { () -> Bool in
            if timeout {
                // Preserve an earlier output-limit or supervision cause, and do not turn an already observed exit into
                // a timeout while its descendants are being cleaned up.
                guard !finished, !stopping else { return false }
                expired = true
            } else if outputLimit {
                // The leader can exit while its multi-megabyte output is still buffered. Record a subsequently observed
                // limit even though normal-exit cleanup is already running, but preserve an earlier failure cause.
                guard !expired, trackingError == nil else { return false }
                exceededOutput = true
                if stopping { return false }
            } else {
                guard !stopping else { return false }
            }
            stopping = true
            return true
        }
        guard shouldTerminate else { return }
        let descendants = refreshTrackedProcesses(includeTokenHolders: true)
        sendSignal(SIGTERM, to: descendants)
        sendSignal(SIGTERM, toProcess: -processGroup, describedAs: "command process group")
        // The leader cannot normally leave the group it leads, but a direct signal also makes the waitpid deadline
        // independent of process-group membership and remains safe because an unreaped child PID cannot be reused.
        sendSignal(SIGTERM, toProcess: processIdentifier, describedAs: "command leader")
        DispatchQueue.global(qos: .utility).async { [self, descendants] in
            completeStop(initialDescendants: descendants)
        }
    }

    private func completeStop(initialDescendants: Set<ProcessIdentity>?) {
        defer { stopCompletion.signal() }
        var descendants = initialDescendants
            ?? refreshTrackedProcesses(includeTokenHolders: true)
        sendSignal(SIGTERM, to: descendants)
        if !lock.withLock({ leaderExited }) {
            sendSignal(SIGTERM, toProcess: -processGroup, describedAs: "command process group")
            sendSignal(SIGTERM, toProcess: processIdentifier, describedAs: "command leader")
        }
        let termDeadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
        while DispatchTime.now().uptimeNanoseconds < termDeadline {
            let discovered = refreshTrackedProcesses(includeTokenHolders: false)
            let newDescendants = discovered.subtracting(descendants)
            sendSignal(SIGTERM, to: newDescendants)
            descendants.formUnion(discovered)
            let rootIsRunning = !lock.withLock({ leaderExited }) && Self.processIsRunning(processIdentifier)
            if !rootIsRunning, !descendants.contains(where: Self.processIsRunning) { break }
            usleep(20_000)
        }

        let killDeadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
        var liveDescendants = Set<ProcessIdentity>()
        while true {
            // Always query the inherited token after the leader has become waitable. This closes the ordering window
            // in which NOTE_EXIT can arrive before a preceding NOTE_FORK has been consumed by the tracking thread.
            descendants.formUnion(refreshTrackedProcesses(includeTokenHolders: true))
            liveDescendants = Set(descendants.filter(Self.processIsRunning))
            sendSignal(SIGKILL, to: liveDescendants)
            if !lock.withLock({ leaderExited }) {
                sendSignal(SIGKILL, toProcess: -processGroup, describedAs: "command process group")
                sendSignal(SIGKILL, toProcess: processIdentifier, describedAs: "command leader")
            }

            // A second token scan after signalling catches a holder which forked while the first snapshot was being
            // processed. The remaining close-token/double-fork race is a documented macOS API limitation below.
            let finalDiscovery = refreshTrackedProcesses(includeTokenHolders: true)
            let newlyDiscovered = finalDiscovery.subtracting(descendants)
            descendants.formUnion(finalDiscovery)
            sendSignal(SIGKILL, to: newlyDiscovered)
            liveDescendants = Set(descendants.filter(Self.processIsRunning))
            if liveDescendants.isEmpty { break }
            if DispatchTime.now().uptimeNanoseconds >= killDeadline { break }
            usleep(20_000)
        }
        if !liveDescendants.isEmpty {
            recordSupervisionFailure(
                "Command cleanup deadline expired with \(liveDescendants.count) live descendant process(es)")
        }

        lock.withLock { trackingShouldStop = true }
        if trackingCompletion.wait(timeout: .now() + 1) == .timedOut {
            recordSupervisionFailure("Command process tracker did not stop within its cleanup deadline")
        }
        // The process event can arrive while the caller is still draining bytes already buffered in the pipe. Closing
        // the shared FileHandle at that point would silently turn a successful command into truncated output. Wait for
        // the sole reader first; close only to break an inherited writer that survived all bounded cleanup, and never
        // report that forced truncation as a successful normal exit.
        if !lock.withLock({ readerFinished }), readerCompletion.wait(timeout: .now() + 1) == .timedOut {
            lock.withLock {
                if !expired, !exceededOutput, trackingError == nil {
                    trackingError = "Command descendants kept the output stream open after the command exited"
                }
            }
            do {
                try output.close()
            } catch {
                recordSupervisionFailure("Cannot close the command output stream: \(error)")
            }
            if !lock.withLock({ readerFinished }), readerCompletion.wait(timeout: .now() + 1) == .timedOut {
                recordSupervisionFailure("Command output reader did not stop within its cleanup deadline")
            }
        }
    }

    private func trackingLoop() {
        _ = refreshTrackedProcesses(includeTokenHolders: false)
        checkPhysicalMemoryLimit()
        trackingReady.signal()
        while !lock.withLock({ trackingShouldStop }) {
            let sawFork = waitForProcessEvent()
            if sawFork {
                _ = refreshTrackedProcesses(includeTokenHolders: true)
            }
            if lock.withLock({ resumed }), Self.hasExitedWithoutReaping(processIdentifier) { leaderDidExit() }
            checkPhysicalMemoryLimit()
            _ = refreshTrackedProcesses(includeTokenHolders: false)
        }
        trackingCompletion.signal()
    }

    private func checkPhysicalMemoryLimit() {
        guard let maximumPhysicalMemoryBytes else { return }
        var information = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &information) { pointer in
            pointer.withMemoryRebound(to: Optional<UnsafeMutableRawPointer>.self, capacity: 1) {
                proc_pid_rusage(processIdentifier, RUSAGE_INFO_V4, $0)
            }
        }
        guard result == 0 else {
            if Self.hasExitedWithoutReaping(processIdentifier) { return }
            failPhysicalMemorySupervision("Cannot measure memory-limited command physical footprint")
            return
        }
        if let expected = memoryProcessStartTime {
            guard information.ri_proc_start_abstime == expected else {
                failPhysicalMemorySupervision("Memory-limited command identity changed while it was supervised")
                return
            }
        } else {
            memoryProcessStartTime = information.ri_proc_start_abstime
        }
        guard information.ri_phys_footprint <= maximumPhysicalMemoryBytes,
            information.ri_lifetime_max_phys_footprint <= maximumPhysicalMemoryBytes
        else {
            failPhysicalMemorySupervision(
                "Command physical footprint exceeded its \(maximumPhysicalMemoryBytes)-byte limit")
            return
        }
    }

    private func waitForProcessEvent() -> Bool {
        guard lock.withLock({ processEventsAvailable }) else {
            usleep(maximumPhysicalMemoryBytes == nil ? 10_000 : 5_000)
            return false
        }
        var events = [kevent64_s](repeating: kevent64_s(), count: 16)
        var timeout = timespec(
            tv_sec: 0, tv_nsec: maximumPhysicalMemoryBytes == nil ? 10_000_000 : 5_000_000)
        let count = events.withUnsafeMutableBufferPointer { buffer in
            kevent64(processEventQueue, nil, 0, buffer.baseAddress, Int32(buffer.count), 0, &timeout)
        }
        if count < 0 {
            if errno != EINTR { lock.withLock { processEventsAvailable = false } }
            usleep(maximumPhysicalMemoryBytes == nil ? 10_000 : 5_000)
            return false
        }
        guard count > 0 else { return false }
        var sawFork = false
        for event in events.prefix(Int(count)) {
            if event.fflags & UInt32(NOTE_FORK) != 0 { sawFork = true }
            if event.ident == UInt64(processIdentifier), event.fflags & NOTE_EXIT != 0 {
                leaderDidExit()
            }
        }
        return sawFork
    }

    private func refreshTrackedProcesses(includeTokenHolders: Bool) -> Set<ProcessIdentity> {
        refreshLock.lock()
        let known = lock.withLock { trackedProcesses }
        var result: Result<(Set<ProcessIdentity>, Set<ProcessIdentity>), Error>
        do {
            var discovered = try Self.descendants(of: processIdentifier, includingChildrenOf: Array(known))
            let tokenHolders = includeTokenHolders
                ? Set(try trackingToken.holders(maximum: Self.maximumTrackedProcesses).map {
                    ProcessIdentity(
                        processIdentifier: $0.processIdentifier,
                        startSeconds: $0.startSeconds,
                        startMicroseconds: $0.startMicroseconds)
                })
                : []
            let tokenProcessIdentifiers = Set(tokenHolders.map(\.processIdentifier))
            let candidates = Array(tokenProcessIdentifiers) + (try Self.processIdentifiers(inGroup: processGroup))
            for candidate in candidates where candidate != processIdentifier && candidate != getpid() {
                guard let snapshot = Self.snapshot(of: candidate) else { continue }
                guard tokenHolders.contains(snapshot.identity) || snapshot.processGroup == processGroup else { continue }
                if !discovered.contains(snapshot.identity) {
                    guard discovered.count < Self.maximumTrackedProcesses else {
                        throw SwiftPodsError(
                            "Command process tracking exceeded \(Self.maximumTrackedProcesses) processes")
                    }
                    discovered.insert(snapshot.identity)
                }
            }
            let newlyWatched = lock.withLock { () -> Set<ProcessIdentity> in
                trackedProcesses = discovered
                watchedProcesses.formIntersection(discovered)
                let new = discovered.subtracting(watchedProcesses)
                watchedProcesses.formUnion(new)
                return new
            }
            result = .success((discovered, newlyWatched))
        } catch {
            result = .failure(error)
        }
        refreshLock.unlock()

        guard case .success(let (discovered, newlyWatched)) = result else {
            if case .failure(let error) = result {
                failSupervision("Cannot supervise command process tree: \(error)")
            }
            return known
        }
        for identity in newlyWatched { _ = registerProcessEvents(for: identity.processIdentifier) }
        return discovered
    }

    private func registerProcessEvents(for processIdentifier: pid_t) -> Bool {
        guard processEventQueue >= 0 else { return false }
        var event = kevent64_s(
            ident: UInt64(processIdentifier), filter: Int16(EVFILT_PROC),
            flags: UInt16(EV_ADD | EV_ENABLE | EV_CLEAR),
            fflags: UInt32(NOTE_FORK) | NOTE_EXIT, data: 0, udata: 0, ext: (0, 0))
        return kevent64(processEventQueue, &event, 1, nil, 0, 0, nil) == 0
    }

    private static func processExists(_ identity: ProcessIdentity) -> Bool {
        snapshot(of: identity.processIdentifier)?.identity == identity
    }

    private static func processIsRunning(_ identity: ProcessIdentity) -> Bool {
        guard let current = snapshot(of: identity.processIdentifier), current.identity == identity else { return false }
        return !current.isZombie
    }

    private static func processIsRunning(_ processIdentifier: pid_t) -> Bool {
        guard let current = snapshot(of: processIdentifier) else { return false }
        return !current.isZombie
    }

    private func sendSignal(_ signal: Int32, to identities: Set<ProcessIdentity>) {
        for identity in identities where Self.processExists(identity) {
            sendSignal(signal, toProcess: identity.processIdentifier, describedAs: "command descendant")
        }
    }

    private func sendSignal(_ signal: Int32, toProcess processIdentifier: pid_t, describedAs label: String) {
        guard kill(processIdentifier, signal) != 0 else { return }
        let savedError = errno
        guard savedError != ESRCH else { return }
        recordSupervisionFailure(
            "Cannot signal \(label): \(String(cString: strerror(savedError)))")
    }

    /// Captures descendants by PID and start time before signalling. Identity checks reject stale snapshots between
    /// cleanup passes, and the unreaped leader PID/process-group ID cannot be recycled. macOS has no public pidfd-like
    /// primitive which atomically combines an individual descendant identity check with `kill`, so a descendant can
    /// still exit and have its PID recycled in the final check/kill interval. Known escaped descendants are retained as
    /// roots, so their children remain discoverable after the original leader changes session or process group.
    private static func descendants(
        of root: pid_t, includingChildrenOf known: [ProcessIdentity]
    ) throws -> Set<ProcessIdentity> {
        var result = Set(known.filter(processExists))
        guard result.count <= maximumTrackedProcesses else {
            throw SwiftPodsError("Command process tracking exceeded \(maximumTrackedProcesses) processes")
        }
        var queue = [root] + result.map(\.processIdentifier)
        var scanned: Set<pid_t> = []
        while let parent = queue.popLast() {
            guard scanned.insert(parent).inserted else { continue }
            for child in try childProcessIdentifiers(of: parent) {
                guard let snapshot = snapshot(of: child), snapshot.parent == parent else { continue }
                if result.contains(snapshot.identity) { continue }
                guard result.count < maximumTrackedProcesses else {
                    throw SwiftPodsError("Command process tracking exceeded \(maximumTrackedProcesses) processes")
                }
                result.insert(snapshot.identity)
                queue.append(child)
            }
        }
        return result
    }

    private static func processIdentifiers(inGroup processGroup: pid_t) throws -> [pid_t] {
        var capacity = 32
        while capacity <= maximumTrackedProcesses + 1 {
            let requestedCapacity = min(capacity, maximumTrackedProcesses + 1)
            var identifiers = [pid_t](repeating: 0, count: requestedCapacity)
            let count = identifiers.withUnsafeMutableBytes { buffer in
                proc_listpgrppids(processGroup, buffer.baseAddress, Int32(buffer.count))
            }
            if count < 0 {
                throw SwiftPodsError(
                    "Cannot enumerate command process group: \(String(cString: strerror(errno)))")
            }
            guard count > 0 else { return [] }
            guard count <= requestedCapacity else {
                throw SwiftPodsError("Command process group enumeration returned malformed data")
            }
            if count > maximumTrackedProcesses {
                throw SwiftPodsError(
                    "Command process tracking exceeded \(maximumTrackedProcesses) processes")
            }
            if count < requestedCapacity {
                return Array(identifiers.prefix(Int(count))).filter { $0 > 0 }
            }
            if requestedCapacity == maximumTrackedProcesses + 1 {
                throw SwiftPodsError(
                    "Command process tracking exceeded \(maximumTrackedProcesses) processes")
            }
            capacity = min(capacity * 2, maximumTrackedProcesses + 1)
        }
        throw SwiftPodsError("Command process tracking exceeded \(maximumTrackedProcesses) processes")
    }

    private static func childProcessIdentifiers(of parent: pid_t) throws -> [pid_t] {
        var capacity = 32
        while capacity <= maximumTrackedProcesses + 1 {
            let requestedCapacity = min(capacity, maximumTrackedProcesses + 1)
            var identifiers = [pid_t](repeating: 0, count: requestedCapacity)
            let count = identifiers.withUnsafeMutableBytes { buffer in
                proc_listchildpids(parent, buffer.baseAddress, Int32(buffer.count))
            }
            if count < 0 {
                throw SwiftPodsError(
                    "Cannot enumerate command descendants: \(String(cString: strerror(errno)))")
            }
            guard count > 0 else { return [] }
            guard count <= requestedCapacity else {
                throw SwiftPodsError("Command descendant enumeration returned malformed data")
            }
            if count > maximumTrackedProcesses {
                throw SwiftPodsError(
                    "Command process tracking exceeded \(maximumTrackedProcesses) processes")
            }
            if count < requestedCapacity {
                return Array(identifiers.prefix(Int(count))).filter { $0 > 0 }
            }
            if requestedCapacity == maximumTrackedProcesses + 1 {
                throw SwiftPodsError(
                    "Command process tracking exceeded \(maximumTrackedProcesses) processes")
            }
            capacity = min(capacity * 2, maximumTrackedProcesses + 1)
        }
        throw SwiftPodsError("Command process tracking exceeded \(maximumTrackedProcesses) processes")
    }

    private static func hasExitedWithoutReaping(_ processIdentifier: pid_t) -> Bool {
        var information = siginfo_t()
        while true {
            let result = waitid(
                P_PID, id_t(processIdentifier), &information, WEXITED | WNOWAIT | WNOHANG)
            if result == 0 { return information.si_pid == processIdentifier }
            if errno == EINTR { continue }
            return false
        }
    }

    private static func snapshot(of processIdentifier: pid_t) -> ProcessSnapshot? {
        var information = proc_bsdinfo()
        let expected = MemoryLayout<proc_bsdinfo>.size
        let read = withUnsafeMutablePointer(to: &information) { pointer in
            proc_pidinfo(processIdentifier, PROC_PIDTBSDINFO, 0, pointer, Int32(expected))
        }
        guard read == Int32(expected), information.pbi_pid == UInt32(processIdentifier) else { return nil }
        return ProcessSnapshot(
            identity: ProcessIdentity(
                processIdentifier: processIdentifier, startSeconds: information.pbi_start_tvsec,
                startMicroseconds: information.pbi_start_tvusec),
            parent: pid_t(information.pbi_ppid), processGroup: pid_t(information.pbi_pgid),
            isZombie: information.pbi_status == UInt32(SZOMB))
    }
}
