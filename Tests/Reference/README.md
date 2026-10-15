# Behaviour reference

The vendored sources and their licenses are retained exclusively as a test
reference. They are excluded from SwiftPods execution, bootstrap and release
archives. `LegacyRuntime` and `LegacyHarness` preserve the previous integration
for comparison; their old acceptance reports do not certify the Swift engine.

The production engine is implemented in `Sources/SwiftPodsCore/Native*`.
