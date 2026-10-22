import Foundation

/// System-library compiler interfaces include pkg-config's Cflags, never Libs.
enum NativeSwiftPackagePkgConfig {
    private static func invalid(_ message: String) -> Diagnostic {
        Diagnostic("SP-SPM-PKGCONFIG", stage: "integrate", message)
    }

    static func read(_ name: String, directory: URL, environment: [String: String]) throws -> [String] {
        let result = try ToolProcess.run(
            "/usr/bin/env", ["pkg-config", "--cflags", "--", name], directory: directory, environment: environment)
        guard result.status == 0, let text = String(data: result.output, encoding: .utf8) else {
            throw invalid(
                "Cannot read pkg-config compiler flags for " + name + ": "
                    + String(decoding: result.error, as: UTF8.self))
        }
        return try words(text)
    }

    static func interface(_ words: [String], directory: URL, user: NativePBX) throws
        -> NativeSwiftPackageCompileSettings.Interface
    {
        var result = NativeSwiftPackageCompileSettings.Interface()
        var index = 0
        func path(_ text: String) -> String {
            user.buildSettingPath(URL(fileURLWithPath: text, relativeTo: directory).standardizedFileURL)
        }
        func operand() throws -> String {
            index += 1
            guard index < words.count, !words[index].isEmpty, !words[index].hasPrefix("-") else {
                throw invalid("Missing pkg-config compiler flag argument")
            }
            return words[index]
        }
        while index < words.count {
            let flag = words[index]
            if flag == "-I" || flag == "-F" {
                let value = path(try operand())
                if flag == "-I" { result.headers.append(value) } else { result.frameworks.append(value) }
            } else if flag.hasPrefix("-I"), flag.count > 2 {
                result.headers.append(path(String(flag.dropFirst(2))))
            } else if flag.hasPrefix("-F"), flag.count > 2 {
                result.frameworks.append(path(String(flag.dropFirst(2))))
            } else if ["-isystem", "-iquote", "-iframework", "-include", "-imacros", "-isysroot"].contains(flag) {
                result.compilerFlags += [flag, path(try operand())]
            } else if flag == "-D" || flag == "-U" {
                result.compilerFlags += [flag, NativeBuildSetting.literal(try operand())]
            } else {
                guard flag.hasPrefix("-"), !flag.hasPrefix("-l"), !flag.hasPrefix("-L"),
                    !flag.hasPrefix("-Wl,"), !["-Xlinker", "-force_load", "-all_load"].contains(flag)
                else { throw invalid("Unsupported pkg-config compiler flag: " + flag) }
                result.compilerFlags.append(NativeBuildSetting.literal(flag))
            }
            index += 1
        }
        return result
    }

    /// pkg-config quotes and escapes its output for a shell; parse it without
    /// executing substitutions or interpreting flags as shell commands.
    private static func words(_ text: String) throws -> [String] {
        var words: [String] = []
        var word = ""
        var started = false
        var quote: Unicode.Scalar?
        var escaped = false
        for scalar in text.unicodeScalars {
            if escaped {
                if quote == "\"", !["$", "`", "\"", "\\", "\n"].contains(scalar) { word += "\\" }
                if scalar != "\n" { word.unicodeScalars.append(scalar) }
                escaped = false
            } else if scalar == "\\", quote != "'" {
                escaped = true
                started = true
            } else if scalar == quote {
                quote = nil
            } else if quote == nil && (scalar == "'" || scalar == "\"") {
                quote = scalar
                started = true
            } else if quote == nil && CharacterSet.whitespacesAndNewlines.contains(scalar) {
                if started {
                    words.append(word)
                    word = ""
                    started = false
                }
            } else {
                word.unicodeScalars.append(scalar)
                started = true
            }
        }
        guard quote == nil, !escaped else { throw invalid("Malformed pkg-config compiler flags") }
        if started { words.append(word) }
        return words
    }
}
