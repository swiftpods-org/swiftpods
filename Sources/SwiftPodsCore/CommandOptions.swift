import Foundation

enum CommandOptions {
    struct Global {
        let arguments: [String]
        let projectDirectory: String?
        let environment: String?

        init(_ tokens: [String]) throws {
            for name in ["--project-directory", "--environment"] {
                var original = tokens
                _ = try CommandOptions.take(name, from: &original)
            }
            var remaining = tokens
            projectDirectory = try CommandOptions.take("--project-directory", from: &remaining)
            environment = try CommandOptions.take("--environment", from: &remaining)
            remaining.removeAll { $0 == "--json" }
            arguments = remaining
        }
    }

    static func parseGlobalOptions(in arguments: [String]) throws -> Global {
        let global = try Global(arguments)
        let commandArguments = global.arguments
        let command = commandArguments.first
        let action = commandArguments.dropFirst().first
        let names: [String]
        switch (command, action) {
        case ("env", "shim"):
            names = ["--directory"]
        case ("env", "import"):
            names = ["--gemfile", "--name"]
        case ("doctor", _), ("migrate", _):
            names = ["--platform", "--variant", "--arch", "--app", "--deployment-target"]
        case ("spec", "lint"), ("lib", "lint"), ("repo", "push"):
            names = ["--sources", "--platforms", "--swift-version"]
        case ("spec", "cat"), ("spec", "which"):
            names = ["--version", "--sources"]
        default:
            names = []
        }
        // Validate against the original tokens so removing one option cannot hide another's missing value.
        for name in names {
            var options = arguments
            _ = try take(name, from: &options)
        }
        return global
    }

    static func hasOptionPrefix(_ value: String) -> Bool {
        value.utf8.first == 45
    }

    static func take(_ name: String, from arguments: inout [String]) throws -> String? {
        var value: String?
        var index = 0
        let prefix = (name + "=").unicodeScalars
        while index < arguments.count {
            let argument = arguments[index]
            if argument == name || argument.unicodeScalars.starts(with: prefix) {
                guard value == nil else {
                    throw Diagnostic("SP-CLI-ARGUMENT", stage: "cli", "Repeated option: " + name)
                }
                if argument == name {
                    guard index + 1 < arguments.count,
                        arguments[index + 1] == "-" || !hasOptionPrefix(arguments[index + 1])
                    else {
                        throw Diagnostic("SP-CLI-ARGUMENT", stage: "cli", "Missing value for " + name)
                    }
                    value = arguments.remove(at: index + 1)
                } else {
                    value = String(argument.unicodeScalars.dropFirst(prefix.count))
                }
                arguments.remove(at: index)
                guard value?.isEmpty == false else {
                    throw Diagnostic("SP-CLI-ARGUMENT", stage: "cli", "Empty value for " + name)
                }
            } else {
                index += 1
            }
        }
        return value
    }
}
