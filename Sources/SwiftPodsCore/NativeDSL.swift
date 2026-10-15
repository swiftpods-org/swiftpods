import Foundation
import Dispatch

/// One interpreter session owns the user's Ruby closures for the whole install.
/// The protocol only evaluates DSL and hooks; it never resolves or installs pods.
final class NativeDSL {
    var callback: (([String: Any]) throws -> [String: Any])?
    private let process: NativeChildProcess
    private let adapterPath: String
    private let input: FileHandle
    private let output: FileHandle
    private var pending = Data()
    private let relay = DispatchGroup()
    init(bundle: RuntimeBundle, environment: [String: String], directory: URL, overrides: [String: String] = [:]) throws {
        let ruby = try ExternalRuby.locate(manifest: bundle.manifest, environment: environment, bundleRoot: bundle.root)
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        adapterPath = bundle.root.appendingPathComponent("host/dsl.rb").path
        input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading
        process = try NativeChildProcess(executable: ruby.executable.path, arguments: [adapterPath], directory: directory, environment: bundle.environment(from: environment).merging(overrides) { _, new in new }, input: stdin.fileHandleForReading.fileDescriptor, output: stdout.fileHandleForWriting.fileDescriptor, error: stderr.fileHandleForWriting.fileDescriptor)
        stdin.fileHandleForReading.closeFile(); stdout.fileHandleForWriting.closeFile(); stderr.fileHandleForWriting.closeFile()
        let handle = stderr.fileHandleForReading, group = relay, redactor = Redactor(environment: environment)
        group.enter()
        DispatchQueue.global().async {
            defer { try? handle.close(); group.leave() }
            var buffer = Data()
            var dropping = false
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 10) {
                    let line = buffer.prefix(through: newline)
                    if !dropping { FileHandle.standardError.write(Data(redactor.scrub(String(decoding: line, as: UTF8.self)).utf8)) }
                    buffer.removeSubrange(...newline); dropping = false
                }
                if buffer.count > 1_048_576 { buffer.removeAll(); dropping = true; FileHandle.standardError.write(Data("[SwiftPods: oversized Ruby output line omitted]\n".utf8)) }
            }
            if !dropping && !buffer.isEmpty { FileHandle.standardError.write(Data(redactor.scrub(String(decoding: buffer, as: UTF8.self)).utf8)) }
        }
    }
    deinit {
        try? input.close(); try? output.close()
        process.terminate()
        relay.wait()
    }
    func request(_ operation: String, _ arguments: [String: Any] = [:]) throws -> Any {
        var object = arguments; object["operation"] = operation
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]); data.append(10)
        try input.write(contentsOf: data)
        while true {
        while !pending.contains(10) {
            let chunk = output.availableData
            guard !chunk.isEmpty else {
                throw Diagnostic("SP-DSL-PROTOCOL", stage: "dsl", "Ruby DSL adapter exited before responding")
            }
            pending.append(chunk)
            guard pending.count <= 16_777_216 else { throw Diagnostic("SP-DSL-PROTOCOL", stage: "dsl", "DSL response exceeds 16 MiB") }
        }
        let end = pending.firstIndex(of: 10)!
        let line = pending.prefix(upTo: end); pending.removeSubrange(...end)
        guard let reply = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
            throw Diagnostic("SP-DSL-PROTOCOL", stage: "dsl", "Invalid response from Ruby DSL adapter")
        }
        if reply["callback"] != nil {
            let response: [String: Any]
            do {
                if ["file_accessor", "build_settings"].contains(reply["callback"] as? String ?? "") {
                    let value = try reply["callback"] as? String == "file_accessor" ? NativeFileAccessor.response(reply) : NativeBuildSettings.response(reply)
                    var data = try JSONSerialization.data(withJSONObject: ["ok": true, "value": value], options: [.sortedKeys]); data.append(10); try input.write(contentsOf: data)
                    continue
                }
                guard let callback else { throw Diagnostic("SP-HOOK-CALLBACK", stage: "hook", "Project callbacks are only available during hooks") }
                response = ["ok": true, "value": try callback(reply)]
            } catch { response = ["ok": false, "message": String(describing: error)] }
            var data = try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys]); data.append(10); try input.write(contentsOf: data)
            continue
        }
        guard reply["ok"] as? Bool == true else {
            let frames = reply["backtrace"] as? [String] ?? []
            let own = URL(fileURLWithPath: adapterPath).deletingLastPathComponent().path + "/"
            let frame = frames.first { $0.contains("Podfile:") || $0.contains(".podspec:") } ?? frames.first { !$0.hasPrefix(own) && !$0.hasPrefix("<internal:") }
            var file = frame, lineNumber: Int?
            if let frame, let expression = try? NSRegularExpression(pattern: #"^(.+?):([0-9]+)(?::|$)"#),
               let match = expression.firstMatch(in: frame, range: NSRange(frame.startIndex..., in: frame)),
               let path = Range(match.range(at: 1), in: frame), let line = Range(match.range(at: 2), in: frame) {
                file = String(frame[path]); lineNumber = Int(frame[line])
            }
            throw Diagnostic("SP-DSL-ERROR", stage: operation, reply["message"] as? String ?? "Ruby evaluation failed", file: file, line: lineNumber, backtrace: frames)
        }
        return reply["value"] ?? NSNull()
        }
    }
    func object(_ operation: String, _ arguments: [String: Any] = [:]) throws -> [String: Any] {
        guard let value = try request(operation, arguments) as? [String: Any] else { throw Diagnostic("SP-DSL-SCHEMA", stage: "dsl", "Expected an object from \(operation)") }
        return value
    }
    func spec(_ path: URL) throws -> [String: Any] {
        if path.pathExtension == "json" { return try readObject(path) }
        return try object("spec", ["path": path.path])
    }
    func serializedSpec(_ path: URL) throws -> Data {
        guard let value = try object("spec_serialization", ["path": path.path])["json"] as? String else { throw Diagnostic("SP-DSL-SCHEMA", stage: "dsl", "Expected a serialized specification") }
        return Data(value.utf8)
    }
}
