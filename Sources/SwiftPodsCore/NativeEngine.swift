import Foundation

public struct HostResult {
    public let status: Int32
    public let events: [[String: Any]]
}

/// Entry point for native commands; a session owns each execution's state.
struct NativeEngine {
    let bundle: RuntimeBundle

    func run(
        arguments: [String], environment: [String: String], machine: Bool, overrides: [String: String] = [:],
        project: URL? = nil
    )
        -> HostResult
    {
        NativeCommandSession(
            bundle: bundle, arguments: arguments, environment: environment, machine: machine, overrides: overrides
        ).run(arguments: arguments, project: project)
    }
}
