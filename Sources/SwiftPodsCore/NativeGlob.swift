import Foundation

/// File matching follows the profile's case-insensitive PathList semantics,
/// including brace sets, zero-directory **/ matches and explicit dotfiles.
func nativeGlob(_ patterns: Any?, root: URL) throws -> [URL] {
    let supplied = nativeStrings(patterns)
    if supplied.isEmpty { return [] }
    let boundary = root.standardizedFileURL
    let rootComponents = boundary.pathComponents
    func expression(_ pattern: String) throws -> NSRegularExpression {
        try NativeSpecPaths.validatePath(pattern, stage: "integrate", file: pattern)
        let traversal =
            pattern.replacingOccurrences(of: "\\.", with: ".").range(
                of: #"(?:^|[/,{])\.\.(?:[/,}]|$)"#, options: .regularExpression) != nil
        let scalars = pattern.unicodeScalars
        let characters = Array(scalars)
        let absolute = characters.indices.contains { index in
            characters[index] == "/" && (index == 0 || ["{", ","].contains(characters[index - 1]))
        }
        guard !absolute, !traversal
        else {
            throw Diagnostic(
                "SP-SPEC-PATH", stage: "integrate", "Source patterns must stay inside the pod", file: pattern)
        }
        let count = characters.count
        var result = "\\A"
        var index = 0
        var depth = 0
        var literalText = ""
        func flushLiteral() {
            result += NSRegularExpression.escapedPattern(for: literalText.precomposedStringWithCanonicalMapping)
            literalText = ""
        }
        // Segment boundaries depend on the chosen brace alternative. Check the
        // actual match position instead of carrying state across alternatives.
        let wildcardPrefix = #"(?!(?:^|(?<=/))\.)"#
        while index < count {
            let char = characters[index]
            switch char {
            case "*":
                flushLiteral()
                if index + 2 < count && characters[index + 1] == "*" && characters[index + 2] == "/" {
                    result += "(?:(?!\\.)[^/]+/)*"
                    index += 2
                } else {
                    result += wildcardPrefix + "[^/]*"
                }
            case "?":
                flushLiteral()
                result += wildcardPrefix + "[^/]"
            case "[":
                flushLiteral()
                var end = index + 1
                var members: [(Unicode.Scalar, Bool)] = []
                while end < count && characters[end] != "]" {
                    var escaped = false
                    if characters[end] == "\\", end + 1 < count {
                        escaped = true
                        end += 1
                    }
                    members.append((characters[end], escaped))
                    end += 1
                }
                guard end < count else {
                    throw Diagnostic(
                        "SP-SPEC-PATTERN", stage: "integrate", "Unterminated glob character class", file: pattern)
                }
                let negated = members.first.map { !$0.1 && ["!", "^"].contains($0.0) } ?? false
                if negated { members.removeFirst() }
                func literal(_ character: Unicode.Scalar) -> String {
                    // Glob escapes denote literal characters, never ICU classes or set operators.
                    if ["-", "&", "[", "]", "^", "\\"].contains(character) { return "\\" + String(character) }
                    return NSRegularExpression.escapedPattern(for: String(character))
                }
                var body = ""
                var member = 0
                while member < members.count {
                    let first = members[member].0
                    if member + 2 < members.count, members[member + 1].0 == "-", !members[member + 1].1 {
                        func folded(_ value: Unicode.Scalar) -> Unicode.Scalar {
                            let text = String(value).lowercased()
                            return text.unicodeScalars.count == 1 ? text.unicodeScalars.first! : value
                        }
                        let lower = folded(first)
                        let upper = folded(members[member + 2].0)
                        let ascending = !String(upper).unicodeScalars.lexicographicallyPrecedes(
                            String(lower).unicodeScalars)
                        // Fold before ordering so mixed-case ranges cannot select punctuation.
                        body += literal(lower) + (ascending ? "-" : "") + literal(upper)
                        member += 3
                    } else {
                        body += literal(first)
                        member += 1
                    }
                }
                // A character class consumes exactly one non-separator character.
                result += wildcardPrefix + "(?!/)"
                result += body.isEmpty ? (negated ? "[^/]" : "(?!)") : "[" + (negated ? "^" : "") + body + "]"
                index = end
            case "{":
                flushLiteral()
                result += "(?:"
                depth += 1
            case "}":
                flushLiteral()
                guard depth > 0 else {
                    throw Diagnostic("SP-SPEC-PATTERN", stage: "integrate", "Unbalanced glob brace", file: pattern)
                }
                result += ")"
                depth -= 1
            case "," where depth > 0:
                flushLiteral()
                result += "|"
            case "/":
                flushLiteral()
                result += "/"
            case "\\":
                guard index + 1 < count else {
                    throw Diagnostic("SP-SPEC-PATTERN", stage: "integrate", "Trailing glob escape", file: pattern)
                }
                index += 1
                literalText.unicodeScalars.append(characters[index])
            default:
                literalText.unicodeScalars.append(char)
            }
            index += 1
        }
        flushLiteral()
        guard depth == 0 else {
            throw Diagnostic("SP-SPEC-PATTERN", stage: "integrate", "Unterminated glob brace", file: pattern)
        }
        do { return try NSRegularExpression(pattern: result + "\\z", options: [.caseInsensitive]) } catch {
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
            let components = path.pathComponents
            guard components.count > rootComponents.count,
                Array(components.prefix(rootComponents.count)) == rootComponents
            else {
                throw Diagnostic("SP-SPEC-PATH", stage: "integrate", "Expanded file escapes the pod", file: file.path)
            }
            // Filesystem components can begin with combining marks; grapheme offsets
            // would remove them together with the preceding separator. Normalize only
            // the matching view, retaining the actual URL returned by Foundation.
            let relative = components.dropFirst(rootComponents.count).joined(separator: "/")
                .precomposedStringWithCanonicalMapping
            if matchers.contains(where: {
                $0.firstMatch(in: relative, range: NSRange(relative.startIndex..., in: relative)) != nil
            }) {
                result.insert(path)
            }
        }
    }
    return result.sorted { $0.path < $1.path }
}
