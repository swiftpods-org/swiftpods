import Foundation

/// A reusable installed tree must describe exactly the checkout that produced it.
enum NativeSourceState {
    static func metadata(identity: String, fingerprint: String, checkout: [String: String]) throws -> [String: Any] {
        let value: [String: Any] = ["identity": identity, "fingerprint": fingerprint, "checkout": checkout]
        return value.merging(["schema_version": 1, "state_sha256": try digest(jsonData(value))]) { _, new in new }
    }

    static func checkout(_ metadata: [String: Any], pin: [String: String]?) throws -> [String: String]? {
        // Legacy state is reinstalled through the normal verified source path.
        guard metadata["schema_version"] as? Int == 1 else { return nil }
        guard let identity = metadata["identity"] as? String, let fingerprint = metadata["fingerprint"] as? String,
            let checkout = metadata["checkout"] as? [String: String],
            metadata["state_sha256"] as? String
                == (try digest(
                    jsonData([
                        "identity": identity, "fingerprint": fingerprint, "checkout": checkout,
                    ]))),
            pin.map({ pin in pin.allSatisfy { checkout[$0.key] == $0.value } }) ?? true
        else {
            throw Diagnostic(
                "SP-CACHE-INTEGRITY", stage: "download",
                "Installed source provenance changed; reinstall with --clean-install")
        }
        return checkout
    }
}
