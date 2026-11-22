import Foundation
import SwiftPodsManifest

/// The package versions Xcode resolved for a project, from its `Package.resolved`.
struct PackageResolved {
    struct Pin: Equatable {
        let location: String
        let version: Version?
        let branch: String?
        let revision: String?
    }

    let pins: [Pin]

    /// Where Xcode keeps the file for a project opened on its own. A workspace keeps its own copy.
    static func location(project: URL) -> URL {
        project.appendingPathComponent("project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
    }

    init(pins: [Pin]) { self.pins = pins }

    init(contentsOf file: URL) throws {
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch {
            throw SwiftPodsError("Cannot read \(file.path)", hint: "Commit Package.resolved, or run `swiftpods install --resolve`")
        }
        try self.init(data: data, file: file)
    }

    /// Reads schema versions 1 to 3. Fields Xcode may add later are ignored; registry pins are not compared.
    init(data: Data, file: URL) throws {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let schema = root["version"] as? Int
        else {
            throw SwiftPodsError(
                "Package.resolved is not valid", file: file.path, hint: "Regenerate it with `swiftpods install --resolve`")
        }
        let entries: [[String: Any]]
        let locationKey: String
        switch schema {
        case 1:
            entries = (root["object"] as? [String: Any])?["pins"] as? [[String: Any]] ?? []
            locationKey = "repositoryURL"
        case 2, 3:
            entries = root["pins"] as? [[String: Any]] ?? []
            locationKey = "location"
        default:
            throw SwiftPodsError("Package.resolved has unsupported schema version \(schema)", file: file.path)
        }
        pins = entries.compactMap { entry in
            guard let location = entry[locationKey] as? String, let state = entry["state"] as? [String: Any] else { return nil }
            if let kind = entry["kind"] as? String, kind != "remoteSourceControl", kind != "localSourceControl" { return nil }
            return Pin(
                location: location, version: (state["version"] as? String).flatMap(Version.init),
                branch: state["branch"] as? String, revision: (state["revision"] as? String)?.lowercased())
        }
    }

    /// What keeps the pins from satisfying the Podfile's packages.
    func problems(for packages: [Package]) -> [String] {
        let pinsByOrigin = Dictionary(grouping: pins) { PackageLocation.fetchIdentity($0.location) }
        let remoteIdentities = Set(pins.map { PackageLocation.identity($0.location) })
        var result: [String] = []
        for package in packages {
            if package.isOverride, remoteIdentities.contains(package.identity) {
                result.append("\(package.name) is a local override and must not have a remote pin")
            }
            guard case .remote(let url) = package.location, let requirement = package.requirement else { continue }
            let matching = pinsByOrigin[PackageLocation.fetchIdentity(url)] ?? []
            guard matching.count == 1, let pin = matching.first else {
                result.append(matching.isEmpty ? "\(package.name) (\(url)) has no pin" : "\(package.name) has duplicate pins for \(url)")
                continue
            }
            switch requirement {
            case .branch(let branch):
                if pin.branch != branch {
                    result.append("\(package.name) is pinned to \(pin.branch.map { "branch " + $0 } ?? "a version"), the Podfile requires branch \(branch)")
                }
            case .revision(let revision):
                if pin.revision != revision.lowercased() {
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
