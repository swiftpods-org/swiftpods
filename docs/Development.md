# Development

You need macOS 13 or later and Xcode with its command-line tools selected.

```sh
git clone https://github.com/swiftpods-org/swiftpods.git
cd swiftpods
swift build -c release
.build/release/swiftpods --help
```

## Layout

| Module | Contents |
| --- | --- |
| `SwiftPodsManifest` | Podfile lexer, parser and evaluator; the typed `Manifest`. |
| `SwiftPodsXcode` | `project.pbxproj` reading and minimal-diff writing. |
| `SwiftPodsKit` | Installation: project integration, binary packages, `Package.resolved`, catalog provenance in `SwiftPods.lock`. |
| `swiftpods` | Command line. |

See [Design](Design.md) for the decisions behind them.

## Tests

```sh
swift test -Xswiftc -warnings-as-errors
```

Two suites are opt-in:

- `SWIFTPODS_E2E=1 swift test --filter EndToEndTests` installs into a sample iOS
  app and builds it with Xcode. It needs an iOS SDK and access to GitHub.
- `SWIFTPODS_PBX_CORPUS=/path/to/projects swift test --filter testCorpusRoundTrip`
  checks that real `project.pbxproj` files (any file names in that directory)
  round-trip byte for byte. Keep private projects outside the repository.

Compiler warnings are errors in CI. Keep changes small and single-purpose, and
record new design decisions in [Design](Design.md) before implementing them.

## Fastlane plugin

The plugin supports Ruby 3.0 and later. Its development dependencies are
separate from the gem's runtime contract: `Gemfile.lock` pins a graph whose gem
metadata accepts both Ruby 3.0 and Ruby 4.0, including Fastlane 2.237.0 and
Bundler 2.5.23. CI runs the complete plugin suite at both ends of that range
with frozen mode enabled, so neither job may rewrite the lock.

The plugin declares `fiddle` as a runtime dependency for its ACL checks because
Ruby 4 no longer includes it as a default gem. Bundler installs it for consumers
as well as for the test suite.

When changing plugin dependencies, regenerate the lock with the minimum Ruby
version, retain a SHA-256 entry for every remote gem, and run both matrix jobs.
Do not raise `required_ruby_version` merely to accommodate the newest Fastlane
development dependency.
