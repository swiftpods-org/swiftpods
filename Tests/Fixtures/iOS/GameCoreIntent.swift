import AppIntents

@available(iOS 16.0, *)
public struct GameCoreFixtureIntent: AppIntent {
    public static var title: LocalizedStringResource { "GameCore Fixture" }
    public init() {}

    public func perform() async throws -> some IntentResult {
        .result()
    }
}
