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
| `SwiftPodsKit` | Installation: project integration, binary packages, `Package.resolved`. |
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
