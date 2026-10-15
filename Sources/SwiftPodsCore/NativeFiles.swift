import Foundation

extension Data {
    /// Identical generated files retain their timestamps and incremental build inputs.
    func writeIfChanged(to path: URL, options: Data.WritingOptions = .atomic) throws {
        try NativeCancellation.check()
        if (try? Data(contentsOf: path)) != self { try write(to: path, options: options) }
    }
}
