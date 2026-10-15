import AppIntents

@available(iOS 16.0, *)
struct SwiftPodsFixtureIntent: AppIntent {
    static var title: LocalizedStringResource { "SwiftPods Fixture" }

    func perform() async throws -> some IntentResult {
        .result()
    }
}
