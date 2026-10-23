import Foundation

/// Target labels also name support files and static archives on case-insensitive volumes.
enum NativeTargetNames {
    static func isFileComponent(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.utf8.contains(47) && !name.utf8.contains(0)
    }

    static func assign(
        _ preferred: [String: String], reserved: Set<String>,
        suffix: (String) -> String = { String(digest(Data($0.utf8)).prefix(16)) },
        relatedNames: (String) -> [String] = { [$0] }
    ) -> [String: String] {
        let locale = Locale(identifier: "en_US_POSIX")
        func identity(_ label: String) -> String { label.folding(options: .caseInsensitive, locale: locale) }
        let families = preferred.mapValues { Set(relatedNames($0).map(identity)) }
        let counts = Dictionary(grouping: families.values.flatMap { $0 }, by: { $0 }).mapValues(\.count)
        let reserved = Set(reserved.map(identity))
        // Protect literal labels before assigning suffixes, regardless of iteration order.
        var used = reserved.union(counts.keys)
        var result: [String: String] = [:]
        for key in preferred.keys.sorted() {
            let label = preferred[key]!
            if families[key]!.allSatisfy({ counts[$0] == 1 && !reserved.contains($0) }) {
                result[key] = label
                continue
            }
            let base = label + "-" + suffix(key)
            var candidate = base
            var index = 0
            while !Set(relatedNames(candidate).map(identity)).isDisjoint(with: used) {
                index += 1
                candidate = base + "-" + String(index)
            }
            used.formUnion(relatedNames(candidate).map(identity))
            result[key] = candidate
        }
        return result
    }
}
