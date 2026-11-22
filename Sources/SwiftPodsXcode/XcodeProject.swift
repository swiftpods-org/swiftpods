import CryptoKit
import Foundation

/// A `.xcodeproj` bundle's `project.pbxproj`, edited as typed values and written with minimal diffs.
public struct XcodeProject: Sendable {
    public struct NativeTarget: Sendable, Equatable {
        public let id: String
        public let name: String
        public let productType: String?
    }

    /// The `.xcodeproj` directory.
    public let path: URL
    public var objects: [String: PBXObject]
    public let rootID: String
    private let document: PBXDocument
    private var root: [String: PBXValue]
    /// SHA-256 of the bytes this value was read from or last wrote; `save` refuses to overwrite anything else.
    private var sourceDigest: String

    public var file: URL { path.appendingPathComponent("project.pbxproj") }

    public init(path: URL) throws(XcodeError) {
        let project = path.standardizedFileURL
        let file = project.appendingPathComponent("project.pbxproj")
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch {
            throw XcodeError("Cannot read the project: \(error.localizedDescription)", file: file.path)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw XcodeError("Project file is not valid UTF-8", file: file.path)
        }
        try self.init(path: project, text: text)
        // The text no longer has a byte order mark the file may start with; `save` compares the file's bytes.
        sourceDigest = Self.digest(data)
    }

    public init(path: URL, text: String) throws(XcodeError) {
        self.path = path.standardizedFileURL
        let file = self.path.appendingPathComponent("project.pbxproj").path
        do {
            document = try PBXDocument(text)
        } catch {
            throw XcodeError(error.message, file: file)
        }
        root = document.value.dictionary ?? [:]
        var objects: [String: PBXObject] = [:]
        for (id, value) in root["objects"]?.dictionary ?? [:] {
            guard let object = value.dictionary, object.isa != nil else {
                throw XcodeError("Object \(id) has no class", file: file)
            }
            objects[id] = object
        }
        guard let rootID = root["rootObject"]?.string, objects[rootID]?.isa == "PBXProject" else {
            throw XcodeError("The project has no PBXProject root object", file: file)
        }
        self.objects = objects
        self.rootID = rootID
        sourceDigest = Self.digest(Data(text.utf8))
    }

    /// The file format version; Xcode 15 introduced 60.
    public var objectVersion: Int? { root["objectVersion"]?.string.flatMap { Int($0) } }

    /// The project's directory: where `<group>` and `SOURCE_ROOT` paths start.
    ///
    /// Xcode generators may place the `.xcodeproj` outside the source tree and record that tree in the
    /// `PBXProject.projectDirPath` field. An empty field means the directory containing the `.xcodeproj`.
    public var sourceRoot: URL {
        let projectDirectory = path.deletingLastPathComponent()
        guard let projectDirPath = project.string("projectDirPath"), !projectDirPath.isEmpty else {
            return projectDirectory
        }
        if (projectDirPath as NSString).isAbsolutePath {
            return URL(fileURLWithPath: projectDirPath).standardizedFileURL
        }
        return projectDirectory.appendingPathComponent(projectDirPath).standardizedFileURL
    }

    public subscript(id: String) -> PBXObject? {
        get { objects[id] }
        set { objects[id] = newValue }
    }

    public var project: PBXObject {
        get { objects[rootID]! }
        set { objects[rootID] = newValue }
    }

    public var nativeTargets: [NativeTarget] {
        project.strings("targets").compactMap { id in
            guard let object = objects[id], object.isa == "PBXNativeTarget", let name = object.string("name") else {
                return nil
            }
            return NativeTarget(id: id, name: name, productType: object.string("productType"))
        }
    }

    /// Every object whose array property `key` lists `id`.
    public func referrers(of id: String, through key: String) -> [String] {
        objects.filter { $0.value.strings(key).contains(id) }.keys.sorted()
    }

    /// Text with only changed records rewritten.
    public func serialized() -> String {
        var value = root
        value["objects"] = .dictionary(objects.mapValues { .dictionary($0) })
        return document.updating(.dictionary(value))
    }

    public var hasChanges: Bool {
        var value = root
        value["objects"] = .dictionary(objects.mapValues { .dictionary($0) })
        return document.value != .dictionary(value)
    }

    /// Writes atomically when something changed. Returns whether it wrote. Refuses to overwrite a file that changed
    /// since it was read, for example by Xcode saving the project meanwhile.
    @discardableResult
    public mutating func save() throws(XcodeError) -> Bool {
        guard hasChanges else { return false }
        let data = Data(serialized().utf8)
        let desired = Self.digest(data)
        let current: Data
        do {
            current = try Data(contentsOf: file)
        } catch {
            throw XcodeError("Cannot read the project: \(error.localizedDescription)", file: file.path)
        }
        let currentDigest = Self.digest(current)
        if currentDigest == desired {
            sourceDigest = desired
            return false
        }
        guard currentDigest == sourceDigest else {
            throw XcodeError("Project file changed since SwiftPods read it; no changes were written", file: file.path)
        }
        do {
            try Self.replace(file, with: data)
        } catch {
            throw XcodeError("Cannot write the project: \(error.localizedDescription)", file: file.path)
        }
        sourceDigest = desired
        return true
    }

    /// Atomically replaces `file`, keeping its permissions.
    static func replace(_ file: URL, with data: Data) throws {
        let permissions = try? FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions]
        try data.write(to: file, options: .atomic)
        if let permissions {
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: file.path)
        }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The identifier SwiftPods gives the object it derives from `key`. Stable across runs and machines,
    /// so ownership needs no record: an object is SwiftPods' own when its identifier matches its key.
    public static func identifier(_ key: String) -> String {
        let digest = SHA256.hash(data: Data(("SwiftPods\u{0}" + key).utf8))
        return digest.prefix(12).map { String(format: "%02X", $0) }.joined()
    }

    /// Adds or replaces the object with the identifier derived from `key`.
    @discardableResult
    public mutating func put(_ key: String, _ object: PBXObject) -> String {
        let id = Self.identifier(key)
        objects[id] = object
        return id
    }

    /// Removes an object, the objects that only refer to it, and every reference to them.
    public mutating func remove(_ id: String) {
        remove(Set([id]))
    }

    /// Objects that mean nothing without the object one of these properties names: a build file of a removed product,
    /// a dependency on a removed target, a proxy into a removed subproject, a product of a removed package.
    private static let dependentReferences: [String: [String]] = [
        "PBXBuildFile": ["fileRef", "productRef"],
        "PBXTargetDependency": ["target", "targetProxy", "productRef"],
        "PBXContainerItemProxy": ["containerPortal", "remoteGlobalIDString"],
        "PBXReferenceProxy": ["remoteRef"],
        "XCSwiftPackageProductDependency": ["package"],
    ]

    /// Removes a set of objects, the objects that exist only to refer to them (see `dependentReferences`), and every
    /// remaining reference to any of them: array entries, single-valued properties and `projectReferences` entries.
    /// No property is left naming an object that is gone.
    public mutating func remove(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        var removed = ids
        var grew = true
        while grew {
            grew = false
            for (id, object) in objects where !removed.contains(id) {
                guard let keys = Self.dependentReferences[object.isa ?? ""],
                    keys.contains(where: { object.string($0).map(removed.contains) == true })
                else { continue }
                removed.insert(id)
                grew = true
            }
        }
        for id in removed { objects[id] = nil }
        for (other, object) in objects {
            var updated = object
            for (key, value) in object {
                switch value {
                case .string(let reference) where removed.contains(reference):
                    updated[key] = nil
                case .array(let array):
                    let filtered = array.filter { element in
                        if let reference = element.string { return !removed.contains(reference) }
                        // `projectReferences` lists dictionaries of a subproject and its product group.
                        if let entry = element.dictionary {
                            return !entry.values.contains { $0.string.map(removed.contains) == true }
                        }
                        return true
                    }
                    if filtered.count != array.count { updated[key] = .array(filtered) }
                default:
                    break
                }
            }
            if updated != object { objects[other] = updated }
        }
    }

    /// Appends `id` to the array property `key` of `owner` unless it is already listed.
    public mutating func append(_ id: String, to key: String, of owner: String) {
        guard var object = objects[owner] else { return }
        var values = object[key]?.array ?? []
        guard !values.contains(.string(id)) else { return }
        values.append(.string(id))
        object[key] = .array(values)
        objects[owner] = object
    }

    /// Build configuration identifiers of a target or the project, keyed by configuration name.
    public func configurations(of owner: String) -> [String: String] {
        guard let list = objects[owner]?.string("buildConfigurationList") else { return [:] }
        var result: [String: String] = [:]
        for id in objects[list]?.strings("buildConfigurations") ?? [] {
            if let name = objects[id]?.string("name") { result[name] = id }
        }
        return result
    }
}
