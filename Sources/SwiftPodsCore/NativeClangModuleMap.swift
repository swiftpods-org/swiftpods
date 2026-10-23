import Foundation

/// Read public module names and language requirements without interpreting
/// comments, header filenames or nested submodules as top-level declarations.
struct NativeClangModuleMap {
    enum Language: String, CaseIterable {
        case c, cpp, m, mm

        var fileType: String {
            switch self {
            case .c: return "sourcecode.c.c"
            case .cpp: return "sourcecode.cpp.cpp"
            case .m: return "sourcecode.c.objc"
            case .mm: return "sourcecode.cpp.objcpp"
            }
        }

        var cxx: Bool { self == .cpp || self == .mm }
    }

    struct Module: Equatable {
        let name: String
        var requiresCXX: Bool?
        var requiresObjC: Bool?

        func language(cxx: Bool) -> Language {
            let cxx = requiresCXX ?? cxx
            return requiresObjC == false ? (cxx ? .cpp : .c) : (cxx ? .mm : .m)
        }

        var importDirective: String {
            requiresObjC == false ? "#pragma clang module import " + name + "\n" : "@import " + name + ";\n"
        }
    }

    let modules: [Module]

    private static let tokenPattern = #"/\*[\s\S]*?\*/|//[^\r\n]*|"(?:\\.|[^"\\])*"|[A-Za-z_][A-Za-z0-9_]*|[^\s]"#

    /// Only declaration tokens change; comments, strings and the authored file remain intact.
    static func libraryContents(_ contents: String) throws -> String {
        let expression = try NSRegularExpression(pattern: tokenPattern)
        let source = contents as NSString
        let tokens = expression.matches(in: contents, range: NSRange(location: 0, length: source.length)).filter {
            let token = source.substring(with: $0.range)
            return !token.hasPrefix("//") && !token.hasPrefix("/*")
        }
        let result = NSMutableString(string: contents)
        for index in tokens.indices.reversed() where index + 1 < tokens.count {
            if source.substring(with: tokens[index].range) == "framework",
                source.substring(with: tokens[index + 1].range) == "module"
            {
                var range = tokens[index].range
                let following = source.substring(from: NSMaxRange(range)).unicodeScalars
                    .prefix { CharacterSet.whitespacesAndNewlines.contains($0) }
                range.length += String(String.UnicodeScalarView(following)).utf16.count
                result.deleteCharacters(in: range)
            }
        }
        return result as String
    }

    init(_ contents: String) throws {
        let expression = try NSRegularExpression(pattern: Self.tokenPattern)
        let tokens = expression.matches(in: contents, range: NSRange(contents.startIndex..., in: contents))
            .compactMap { Range($0.range, in: contents).map { String(contents[$0]) } }
            .filter { !$0.hasPrefix("//") && !$0.hasPrefix("/*") }
        var modules: [Module] = []
        var depth = 0
        var index = 0
        func identifier(_ token: String) -> String? {
            let name = token.hasPrefix("\"") && token.hasSuffix("\"")
                ? String(token.dropFirst().dropLast()) : token
            guard name.range(of: #"\A[A-Za-z_][A-Za-z0-9_]*\z"#, options: .regularExpression) != nil else { return nil }
            return name
        }
        while index < tokens.count {
            let token = tokens[index]
            if token == "module", depth == 0, index + 1 < tokens.count {
                if tokens[index + 1] == "*" { index += 1; continue }
                guard var name = identifier(tokens[index + 1]) else {
                    throw Diagnostic("SP-LINT-MODULE-MAP", stage: "lint", "Module name cannot be imported: " + tokens[index + 1])
                }
                index += 1
                while index + 2 < tokens.count, tokens[index + 1] == ".", let part = identifier(tokens[index + 2]) {
                    name += "." + part
                    index += 2
                }
                modules.append(Module(name: name))
            } else if token == "requires", depth == 1, !modules.isEmpty {
                var feature = index + 1
                while feature < tokens.count {
                    let negated = tokens[feature] == "!"
                    if negated { feature += 1 }
                    guard feature < tokens.count, identifier(tokens[feature]) != nil else { break }
                    if tokens[feature] == "cplusplus" {
                        modules[modules.count - 1].requiresCXX = !negated
                    } else if !negated && tokens[feature].hasPrefix("cplusplus") {
                        modules[modules.count - 1].requiresCXX = true
                    } else if tokens[feature] == "objc" {
                        modules[modules.count - 1].requiresObjC = !negated
                    }
                    feature += 1
                    guard feature < tokens.count, tokens[feature] == "," else { break }
                    feature += 1
                }
            }
            if token == "{" { depth += 1 }
            if token == "}" { depth = max(0, depth - 1) }
            index += 1
        }
        self.modules = modules
    }
}
