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

    public var file: URL { path.appendingPathComponent("project.pbxproj") }

    public init(path: URL) throws(XcodeError) {
        let file = path.standardizedFileURL.appendingPathComponent("project.pbxproj")
        let text: String
        do { text = try String(contentsOf: file, encoding: .utf8) } catch {
            throw XcodeError("Cannot read the project: \(error.localizedDescription)", file: file.path)
        }
        try self.init(path: path, text: text)
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
    }

    /// The file format version; Xcode 15 introduced 60.
    public var objectVersion: Int? { root["objectVersion"]?.string.flatMap { Int($0) } }

    /// The project's directory: where `<group>` and `SOURCE_ROOT` paths start.
    public var sourceRoot: URL { path.deletingLastPathComponent() }

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

    /// Writes atomically when something changed. Returns whether it wrote.
    @discardableResult
    public func save() throws(XcodeError) -> Bool {
        guard hasChanges else { return false }
        do {
            try Data(serialized().utf8).write(to: file, options: .atomic)
        } catch {
            throw XcodeError("Cannot write the project: \(error.localizedDescription)", file: file.path)
        }
        return true
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

    /// Removes an object and every array reference to it.
    public mutating func remove(_ id: String) {
        objects[id] = nil
        for (other, object) in objects {
            var updated = object
            var changed = false
            for (key, value) in object {
                guard let array = value.array, array.contains(.string(id)) else { continue }
                updated[key] = .array(array.filter { $0 != .string(id) })
                changed = true
            }
            if changed { objects[other] = updated }
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
