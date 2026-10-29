import SwiftPodsManifest
import SwiftPodsXcode

/// A failure of a command, with where it happened and how to fix it when known.
public struct SwiftPodsError: Error, Sendable, CustomStringConvertible {
    public let message: String
    public let file: String?
    public let hint: String?

    public init(_ message: String, file: String? = nil, hint: String? = nil) {
        self.message = message
        self.file = file
        self.hint = hint
    }

    public var description: String {
        (file.map { $0 + ": " } ?? "") + "error: " + message + (hint.map { "\n  hint: " + $0 } ?? "")
    }

    static func wrap(_ error: any Error) -> any Error {
        switch error {
        case let error as ManifestError: return error
        case let error as XcodeError: return SwiftPodsError(error.message, file: error.file)
        default: return error
        }
    }
}
