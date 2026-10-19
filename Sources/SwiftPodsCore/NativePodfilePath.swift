import Foundation

enum NativePodfilePath {
    static let names = ["CocoaPods.podfile.yaml", "CocoaPods.podfile", "Podfile", "Podfile.rb"]

    static func find(in directory: URL, hardened: Bool = false) -> URL? {
        (hardened ? ["Podfile.json"] : names).map { directory.appendingPathComponent($0) }.first { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory)
                && !isDirectory.boolValue
        }
    }
}
