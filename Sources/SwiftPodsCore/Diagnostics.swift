import Foundation

public struct Diagnostic: Codable, Error {
    public let code: String
    public let stage: String
    public let message: String
    public var file: String?
    public var line: Int?
    public var state: String?
    public var backtrace: [String]
    public var dependencyChain: [String]

    public init(_ code: String, stage: String, _ message: String, file: String? = nil,
                line: Int? = nil, state: String? = nil, backtrace: [String] = [], dependencyChain: [String] = []) {
        self.code = code; self.stage = stage; self.message = message
        self.file = file; self.line = line; self.state = state
        self.backtrace = backtrace; self.dependencyChain = dependencyChain
    }
}

public struct Redactor {
    private let secrets: [String]
    public init(environment: [String: String]) {
        let pattern = "TOKEN|PASSWORD|SECRET|CREDENTIAL|PRIVATE_KEY|API_KEY|ACCESS_KEY"
        secrets = environment.filter { $0.key.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil }
            .flatMap { [$0.value] + $0.value.components(separatedBy: .newlines) }
            .filter { $0.count >= 4 }.sorted { $0.count > $1.count }
    }
    public func scrub(_ text: String) -> String {
        var value = text
        for secret in secrets { value = value.replacingOccurrences(of: secret, with: "[REDACTED]") }
        value = value.replacingOccurrences(of: #"(?i)(https?|ssh|git)://[^\s/@]+(?::[^\s/@]*)?@"#,
                                          with: "$1://[REDACTED]@", options: .regularExpression)
        return value.replacingOccurrences(of: #"(?i)([?&](?:access_token|token|api_key|password)=)[^&\s]+"#,
                                         with: "$1[REDACTED]", options: .regularExpression)
    }
    public func scrubObject(_ object: Any) -> Any {
        if let value = object as? String { return scrub(value) }
        if let values = object as? [Any] { return values.map(scrubObject) }
        if let values = object as? [String: Any] {
            return values.reduce(into: [String: Any]()) { $0[scrub($1.key)] = scrubObject($1.value) }
        }
        return object
    }
}

public func jsonData(_ object: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
}

func readObject(_ url: URL) throws -> [String: Any] {
    guard let result = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
        throw Diagnostic("SP-STATE-INVALID", stage: "read", "Expected a JSON object", file: url.path)
    }
    return result
}
