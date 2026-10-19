import Foundation

/// NSString keys remain byte-distinct until a Foundation dictionary is bridged
/// to Swift, whose String equality treats canonical Unicode forms as equal.
enum NativeDictionaryKeys {
    static func validate(_ value: Any, file: String? = nil, stage: String = "read") throws {
        func visit(_ value: Any, depth: Int) throws {
            guard depth <= 512 else {
                throw Diagnostic("SP-DATA-DEPTH", stage: stage, "Data exceeds the nesting limit", file: file)
            }
            if let dictionary = value as? NSDictionary {
                var keys = Set<String>()
                for (raw, child) in dictionary {
                    if let key = raw as? String, !keys.insert(key).inserted {
                        throw Diagnostic(
                            "SP-DATA-KEY", stage: stage,
                            "Distinct dictionary keys have equivalent Unicode spellings", file: file)
                    }
                    try visit(child, depth: depth + 1)
                }
            } else if let array = value as? NSArray {
                for child in array { try visit(child, depth: depth + 1) }
            }
        }
        try visit(value, depth: 0)
    }
}
