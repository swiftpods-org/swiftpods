import Foundation

enum NativeSpecKind: String { case library, test, app }
enum NativeTestType: String {
    case unit, ui
    var label: String { self == .unit ? "Unit" : "UI" }
    var productType: String {
        self == .unit ? "com.apple.product-type.bundle.unit-test" : "com.apple.product-type.bundle.ui-testing"
    }
}

extension NativeDependency {
    func expandedSelections() throws -> [NativeDependency] {
        var base = self
        for field in ["subspecs", "testspecs", "appspecs"] { base.options.removeValue(forKey: field) }
        var result: [NativeDependency] = options["subspecs"] == nil ? [base] : []
        for field in ["subspecs", "testspecs", "appspecs"] {
            guard let value = options[field] else { continue }
            guard let names = value as? [String], names.allSatisfy({ !$0.isEmpty }) else {
                throw Diagnostic(
                    "SP-SPEC-SELECTION", stage: "resolve", "\(field) must be an array of spec names", file: name)
            }
            result += try names.map {
                try NativeDependency(
                    ["name": name + "/" + $0, "requirements": requirements, "options": base.options],
                    platform: platform, deployment: deployment)
            }
        }
        return result
    }
}

extension NativeSpec {
    func nodes(_ fullname: String) throws -> [(kind: NativeSpecKind, data: [String: Any])] {
        guard NativePodName.components(fullname).first == name else {
            throw Diagnostic("SP-SPEC-SUBSPEC", stage: "resolve", "Spec does not belong to \(name)", file: fullname)
        }
        var path: [(kind: NativeSpecKind, data: [String: Any])] = [(.library, data)]
        for part in NativePodName.components(fullname).dropFirst() {
            var matches: [(kind: NativeSpecKind, data: [String: Any])] = []
            for (field, kind): (String, NativeSpecKind) in [
                ("subspecs", .library), ("testspecs", .test), ("appspecs", .app),
            ] {
                matches += (path.last!.data[field] as? [[String: Any]] ?? []).filter {
                    $0["name"] as? String == String(part)
                }.map { (kind, $0) }
            }
            guard matches.count == 1 else {
                throw Diagnostic(
                    "SP-SPEC-SUBSPEC", stage: "resolve", "Missing or ambiguous spec \(fullname)", file: name)
            }
            try NativeSpecSchema.validate(matches[0].data)
            path.append(matches[0])
        }
        return path
    }
    func kind(_ fullname: String) throws -> NativeSpecKind { try nodes(fullname).last!.kind }
    func testType(_ fullname: String, platform: String) throws -> NativeTestType {
        let value = try supplementaryAttributes(fullname, platform: platform)["test_type"] ?? "unit"
        guard let name = value as? String, let type = NativeTestType(rawValue: name) else {
            throw Diagnostic("SP-TEST-TYPE", stage: "resolve", "Unknown test type \(value)", file: fullname)
        }
        return type
    }
    func supplementaryAttributes(_ fullname: String, platform: String) throws -> [String: Any] {
        let path = try nodes(fullname)
        // These attributes inherit in the fixed behaviour profile. Sources,
        // resources, script phases and Info.plist entries belong to this spec.
        let inherited = NativeAttributeContract.inherited
        func merge(_ old: [String: Any], _ new: [String: Any]) -> [String: Any] {
            var result = Self.merge(old, new)
            if path.last!.kind != .library {
                for key in ["xcconfig", "pod_target_xcconfig", "user_target_xcconfig"] {
                    if let values = new[key] as? [String: Any] {
                        result[key] = (old[key] as? [String: Any] ?? [:]).merging(values) { _, last in last }
                    }
                }
            }
            return result
        }
        var attributes: [String: Any] = [:]
        for node in path.dropLast() {
            attributes = merge(attributes, node.data.filter { inherited.contains($0.key) })
            attributes = merge(
                attributes,
                (node.data[platform] as? [String: Any] ?? [:]).filter {
                    inherited.contains($0.key) || $0.key == "deployment_target"
                })
        }
        attributes = merge(attributes, path.last!.data)
        if let specific = path.last!.data[platform] as? [String: Any] { attributes = merge(attributes, specific) }
        return attributes
    }
    func validateSupplementary(_ request: NativeDependency) throws {
        let kind = try kind(request.name)
        guard kind != .library else { return }
        let attributes = try supplementaryAttributes(request.name, platform: request.platform)
        if kind == .test {
            _ = try testType(request.name, platform: request.platform)
            guard attributes["requires_app_host"] == nil || attributes["requires_app_host"] is Bool else {
                throw Diagnostic(
                    "SP-TEST-HOST", stage: "resolve", "requires_app_host must be boolean", file: request.name)
            }
            if let host = attributes["app_host_name"] {
                guard let host = host as? String, attributes["requires_app_host"] as? Bool == true else {
                    throw Diagnostic(
                        "SP-TEST-HOST", stage: "resolve", "app_host_name requires requires_app_host = true",
                        file: request.name)
                }
                if NativePodName.components(host).first == name {
                    guard try self.kind(host) == .app else {
                        throw Diagnostic("SP-TEST-HOST", stage: "resolve", "Host must identify an app spec", file: host)
                    }
                }
                let dependencies = attributes["dependencies"] as? [String: Any] ?? [:]
                guard dependencies[host] != nil else {
                    throw Diagnostic(
                        "SP-TEST-HOST", stage: "resolve", "Test spec must depend on its named app host",
                        file: request.name)
                }
            }
        }
        if let info = attributes["info_plist"], !(info is [String: Any]) {
            throw Diagnostic("SP-SPEC-PLIST", stage: "resolve", "info_plist must be a dictionary", file: request.name)
        }
        if let scheme = attributes["scheme"] as? [String: Any] {
            try NativeSchemeOptions.validate(scheme, file: request.name)
        } else if attributes["scheme"] != nil {
            throw Diagnostic("SP-SPEC-SCHEME", stage: "resolve", "scheme must be a dictionary", file: request.name)
        }
    }
}
