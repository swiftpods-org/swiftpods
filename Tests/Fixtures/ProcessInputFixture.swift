import Darwin
import Foundation

@main
struct ProcessInputFixture {
    static func main() throws {
        let mode = CommandLine.arguments[1]
        let destination = URL(fileURLWithPath: CommandLine.arguments[2])
        let script: String
        if mode == "inherit" {
            script = "IFS= read -r value; printf '%s' \"$value\""
        } else {
            let mask = Int(mode)!
            for descriptor: Int32 in 0...2 where mask & (1 << descriptor) != 0 { close(descriptor) }
            // Fail promptly if stdin aliases our own output capture pipe.
            script =
                "test ! -p /dev/fd/0 || exit 92; read value; printf 'read-status=%s' \"$?\"; printf fixture-error >&2"
        }
        let result = try ToolProcess.run("/bin/sh", ["-c", script], environment: [:])
        try JSONSerialization.data(withJSONObject: [
            "status": result.status,
            "output": String(decoding: result.output, as: UTF8.self),
            "error": String(decoding: result.error, as: UTF8.self),
        ]).write(to: destination)
    }
}
