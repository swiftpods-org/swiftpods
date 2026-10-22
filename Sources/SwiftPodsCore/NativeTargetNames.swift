import Foundation

/// Target labels also name support files and static archives on case-insensitive volumes.
enum NativeTargetNames {
    static func assign(
        _ preferred: [String: String], reserved: Set<String>,
        suffix: (String) -> String = { String(digest(Data($0.utf8)).prefix(16)) }
    ) -> [String: String] {
        let counts = Dictionary(grouping: preferred.keys, by: { preferred[$0]!.lowercased() }).mapValues(\.count)
        let reserved = Set(reserved.map { $0.lowercased() })
        // Protect literal labels before assigning suffixes, regardless of iteration order.
        var used = reserved.union(preferred.values.map { $0.lowercased() })
        var result: [String: String] = [:]
        for key in preferred.keys.sorted() {
            let label = preferred[key]!
            if counts[label.lowercased()] == 1 && !reserved.contains(label.lowercased()) {
                result[key] = label
                continue
            }
            let base = label + "-" + suffix(key)
            var candidate = base
            var index = 0
            while !used.insert(candidate.lowercased()).inserted {
                index += 1
                candidate = base + "-" + String(index)
            }
            result[key] = candidate
        }
        return result
    }
}
