import Foundation

/// Each declared library interface is validated with its own dependency closure.
struct NativeLintSelection {
    let name: String
    let platform: String
    let deployment: String
    let tests: [String]

    static func plan(_ spec: NativeSpec, platforms: [String], skipTests: Bool) throws -> [Self] {
        func libraries(_ node: [String: Any], name: String) throws -> [String] {
            var names = [name]
            for child in node["subspecs"] as? [[String: Any]] ?? [] {
                guard let part = child["name"] as? String else {
                    throw Diagnostic("SP-SPEC-SUBSPEC", stage: "lint", "Missing subspec name", file: name)
                }
                names += try libraries(child, name: name + "/" + part)
            }
            return names
        }
        let names = try libraries(spec.data, name: spec.name)
        let defaults = ["osx": "13.0", "ios": "15.0", "tvos": "15.0", "watchos": "8.0", "visionos": "1.0"]
        func supported(_ attributes: [String: Any], on platform: String) -> Bool {
            guard let declared = attributes["platforms"] as? [String: Any], !declared.isEmpty else { return true }
            return declared[platform] != nil
        }
        var selections: [Self] = []
        for platform in platforms {
            guard let fallback = defaults[platform] else {
                throw Diagnostic("SP-LINT-PLATFORM", stage: "lint", "Unknown lint platform", file: platform)
            }
            for name in names {
                let attributes = try spec.attributes(name, platform: platform)
                if name != spec.name && !supported(attributes, on: platform) { continue }
                let minimum =
                    (attributes["platforms"] as? [String: String])?[platform]
                    ?? attributes["deployment_target"] as? String ?? fallback
                var tests: [String] = []
                if !skipTests {
                    for test in try spec.nodes(name).last!.data["testspecs"] as? [[String: Any]] ?? [] {
                        guard let part = test["name"] as? String else { continue }
                        let full = name + "/" + part
                        if try supported(spec.attributes(full, platform: platform), on: platform) { tests.append(full) }
                    }
                }
                selections.append(Self(name: name, platform: platform, deployment: minimum, tests: tests))
            }
        }
        return selections
    }
}
