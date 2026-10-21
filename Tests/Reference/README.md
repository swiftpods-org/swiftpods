# Behaviour reference

The vendored sources and their licenses are retained exclusively as a test
reference. They are excluded from SwiftPods execution, bootstrap and release
archives. The Python runners in this directory compare the native engine with
the frozen CocoaPods reference in an isolated temporary environment.

The production engine is implemented in `Sources/SwiftPodsCore/Native*`.
