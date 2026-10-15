import Foundation

func nativeStrings(_ value: Any?) -> [String] {
    if let value = value as? String { return [value] }
    return (value as? [Any] ?? []).compactMap { $0 as? String }
}
