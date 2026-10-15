import Foundation
import ProcessSupport

enum NativeCancellation {
    static func check() throws {
        if Thread.current.threadDictionary["SwiftPods.cleanup"] as? Bool == true { return }
        let signal = sp_cancellation_number()
        if signal != 0 { throw Diagnostic("SP-CANCELLED", stage: "execute", "Command cancelled by signal \(signal)") }
    }
    static func cleanup<T>(_ body: () throws -> T) rethrows -> T {
        let previous = Thread.current.threadDictionary["SwiftPods.cleanup"]
        Thread.current.threadDictionary["SwiftPods.cleanup"] = true
        defer { Thread.current.threadDictionary["SwiftPods.cleanup"] = previous }
        return try body()
    }
}
