import Foundation

/// File matching follows the profile's case-insensitive PathList semantics,
/// including brace sets, zero-directory **/ matches and explicit dotfiles.
func nativeGlob(_ patterns: Any?, root: URL) throws -> [URL] {
    let supplied = nativeStrings(patterns)
    if supplied.isEmpty { return [] }
    let boundary = root.standardizedFileURL
    func expression(_ pattern: String) throws -> NSRegularExpression {
        let traversal =
            pattern.replacingOccurrences(of: "\\.", with: ".").range(
                of: #"(?:^|[/,{])\.\.(?:[/,}]|$)"#, options: .regularExpression) != nil
        guard !pattern.hasPrefix("/"), !pattern.contains("{/"), !pattern.contains(",/"), !traversal else {
            throw Diagnostic(
                "SP-SPEC-PATH", stage: "integrate", "Source patterns must stay inside the pod", file: pattern)
        }
        let characters = Array(pattern)
        let count = characters.count
        var result = "^"
        var index = 0
        var depth = 0
        var segment = true
        while index < count {
            let char = characters[index]
            switch char {
            case "*":
                if index + 2 < count && characters[index + 1] == "*" && characters[index + 2] == "/" {
                    result += "(?:(?!\\.)[^/]+/)*"
                    index += 2
                    segment = true
                } else {
                    result += (segment ? "(?!\\.)" : "") + "[^/]*"
                    segment = false
                }
            case "?":
                result += (segment ? "(?!\\.)" : "") + "[^/]"
                segment = false
            case "[":
                var end = index + 1
                while end < count && characters[end] != "]" { end += 1 }
                guard end < count else {
                    throw Diagnostic(
                        "SP-SPEC-PATTERN", stage: "integrate", "Unterminated glob character class", file: pattern)
                }
                var body = String(characters[(index + 1)..<end])
                if body.hasPrefix("!") { body = "^" + body.dropFirst() }
                result += (segment ? "(?!\\.)" : "") + "[" + body + "]"
                index = end
                segment = false
            case "{":
                result += "(?:"
                depth += 1
            case "}":
                guard depth > 0 else {
                    throw Diagnostic("SP-SPEC-PATTERN", stage: "integrate", "Unbalanced glob brace", file: pattern)
                }
                result += ")"
                depth -= 1
            case "," where depth > 0: result += "|"
            case "/":
                result += "/"
                segment = true
            case "\\":
                guard index + 1 < count else {
                    throw Diagnostic("SP-SPEC-PATTERN", stage: "integrate", "Trailing glob escape", file: pattern)
                }
                index += 1
                result += NSRegularExpression.escapedPattern(for: String(characters[index]))
                segment = false
            default:
                result += NSRegularExpression.escapedPattern(for: String(char))
                segment = false
            }
            index += 1
        }
        guard depth == 0 else {
            throw Diagnostic("SP-SPEC-PATTERN", stage: "integrate", "Unterminated glob brace", file: pattern)
        }
        do { return try NSRegularExpression(pattern: result + "$", options: [.caseInsensitive]) } catch {
            throw Diagnostic("SP-SPEC-PATTERN", stage: "integrate", "Invalid file pattern", file: pattern)
        }
    }
    let matchers = try supplied.map { try expression($0.hasSuffix("/") ? String($0.dropLast()) : $0) }
    var result = Set<URL>()
    if supplied.contains(".") { result.insert(boundary) }
    if let entries = FileManager.default.enumerator(
        at: boundary, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [])
    {
        while let file = entries.nextObject() as? URL {
            try NativeCancellation.check()
            let path = file.standardizedFileURL
            if (try? path.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                entries.skipDescendants()
            }
            guard path.path.hasPrefix(boundary.path + "/") else {
                throw Diagnostic("SP-SPEC-PATH", stage: "integrate", "Expanded file escapes the pod", file: file.path)
            }
            let relative = String(path.path.dropFirst(boundary.path.count + 1))
            if matchers.contains(where: {
                $0.firstMatch(in: relative, range: NSRange(relative.startIndex..., in: relative)) != nil
            }) {
                result.insert(path)
            }
        }
    }
    return result.sorted { $0.path < $1.path }
}
