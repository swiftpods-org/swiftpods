import Foundation
import SwiftPodsManifest

/// Xcode's record of resolved package versions, in any of its formats.
struct PackageResolved {
    struct Pin: Equatable {
        let location: String
        let version: Version?
        let branch: String?
        let revision: String?
    }

    let pins: [Pin]

    static func location(project: URL) -> URL {
        project.appendingPathComponent("project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
    }

    init(pins: [Pin]) { self.pins = pins }

    init(contentsOf file: URL) throws {
        let data: Data
        do { data = try Data(contentsOf: file) } catch {
            throw SwiftPodsError("Cannot read \(file.path)", hint: "Commit Package.resolved, or run `swiftpods install --resolve`")
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SwiftPodsError("Package.resolved is not valid JSON", file: file.path)
        }
        // Version 1 nests pins under "object" and names the location "repositoryURL".
        let entries = (root["pins"] as? [[String: Any]]) ?? ((root["object"] as? [String: Any])?["pins"] as? [[String: Any]]) ?? []
        pins = entries.compactMap { entry in
            guard let location = (entry["location"] ?? entry["repositoryURL"]) as? String else { return nil }
            let state = entry["state"] as? [String: Any] ?? [:]
            return Pin(
                location: location, version: (state["version"] as? String).flatMap(Version.init),
                branch: state["branch"] as? String, revision: state["revision"] as? String)
        }
    }

    /// Problems that make the pins unusable for a deployment install.
    func problems(for packages: [Package]) -> [String] {
        var result: [String] = []
        for package in packages {
            guard case .remote(let url) = package.location, let requirement = package.requirement else { continue }
            let canonical = PackageLocation.canonical(url)
            guard let pin = pins.first(where: { PackageLocation.canonical($0.location) == canonical }) else {
                result.append("\(package.name) (\(url)) has no pin")
                continue
            }
            switch requirement {
            case .branch(let branch):
                if pin.branch != branch { result.append("\(package.name) is pinned to \(pin.branch.map { "branch " + $0 } ?? "a version"), the Podfile requires branch \(branch)") }
            case .revision(let revision):
                if pin.revision.map({ $0.lowercased().hasPrefix(revision) }) != true {
                    result.append("\(package.name) is pinned to revision \(pin.revision ?? "none"), the Podfile requires \(revision)")
                }
            default:
                guard let version = pin.version else {
                    result.append("\(package.name) is pinned to \(pin.branch.map { "branch " + $0 } ?? "a revision"), the Podfile requires \(requirement)")
                    continue
                }
                if !requirement.allows(version) {
                    result.append("\(package.name) is pinned to \(version), the Podfile requires \(requirement)")
                }
            }
        }
        return result
    }
}
