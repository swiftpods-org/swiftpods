import Foundation

enum CommandOptions {
    static func take(_ name: String, from arguments: inout [String]) throws -> String? {
        var value: String?
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == name || argument.hasPrefix(name + "=") {
                guard value == nil else { throw Diagnostic("SP-CLI-ARGUMENT", stage: "cli", "Repeated option: " + name) }
                if argument == name {
                    guard index + 1 < arguments.count else { throw Diagnostic("SP-CLI-ARGUMENT", stage: "cli", "Missing value for " + name) }
                    value = arguments.remove(at: index + 1)
                } else { value = String(argument.dropFirst(name.count + 1)) }
                arguments.remove(at: index)
                guard value?.isEmpty == false else { throw Diagnostic("SP-CLI-ARGUMENT", stage: "cli", "Empty value for " + name) }
            } else { index += 1 }
        }
        return value
    }
}
