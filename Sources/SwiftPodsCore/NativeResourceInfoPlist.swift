import Foundation

extension NativeXcode {
    /// Resource-only bundles have no executable; Xcode's automatic plist declares one anyway.
    func resourceBundleInfoPlist(_ label: String, settings: inout [String: Any]) throws {
        let info = project.appendingPathComponent("Pods/Target Support Files/" + label + "/Info.plist")
        let plist: [String: Any] = [
            "CFBundleDevelopmentRegion": "$(DEVELOPMENT_LANGUAGE)", "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)", "CFBundleName": "$(PRODUCT_NAME)",
            "CFBundlePackageType": "BNDL", "CFBundleShortVersionString": "1.0", "CFBundleVersion": "1",
        ]
        try FileManager.default.createDirectory(at: info.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).writeIfChanged(
            to: info, options: .atomic)
        settings["GENERATE_INFOPLIST_FILE"] = "NO"
        settings["INFOPLIST_FILE"] = graph.buildSettingPath(info)
    }
}
