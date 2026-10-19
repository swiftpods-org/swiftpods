# Development

SwiftPods separates the command envelope, installation workflow, source adapters,
project builders and Ruby API. Input formats, compatibility aliases and persisted
schemas are contracts; moving code between components does not change them.

## Reading the engine

Start with `CLI.swift` and `NativeEngine.swift`. The engine creates a new
`NativeCommandSession` for each execution; that session owns events, diagnostics
and output flags. `NativeCommandRequest` validates the common command envelope
before project code runs.

`CommandOptions` validates value options against the original argument list,
then removes global options. `CLIContext` holds the resulting command and its
immutable dependencies. Its dispatcher selects the environment, inspection and
storage handlers in `CLI+Environment.swift`, `CLI+Inspection.swift` and
`CLI+Storage.swift`. Engine commands return to `CLI.swift`, which owns cancellation,
the project journal and recovery. `graph/why --refresh` follow that same installation
transaction; `repo push` keeps the engine's validation and publication workflow.

| Responsibility | Entry points |
| --- | --- |
| CLI options and command dispatch | `CommandOptions.swift`, `CLIContext.swift`, `CLI+*.swift` |
| Command routing and output | `NativeCommandSession.swift` |
| Installation pipeline | `NativeInstallation.swift` |
| Lock parsing, pins and serialization | `NativeLock.swift` |
| Version and requirement values | `NativeVersion.swift` |
| Dependency and specification models | `NativeDependency.swift`, `NativeSpec.swift` |
| Backtracking resolution | `NativeResolver.swift` |
| Source catalog and candidate selection | `NativeSources.swift` |
| Downloads, checkouts and archive preparation | `NativeDownload.swift`, `NativeCheckout.swift`, `NativeArchive.swift`, `NativeSourceInstallation.swift` |
| Live Ruby hooks and project callbacks | `NativeHookRunner.swift`, `NativeHookBridge.swift` |
| PBX graph and round trips | `NativePBX.swift` |
| Dependency project builders | `NativeXcodeGeneration.swift`, `NativeXcodeLibraryTarget.swift` |
| User project integration | `NativeXcodeIntegration.swift` |
| Native Swift package references | `NativeSwiftPackageIntegrator.swift` |
| Ruby API and transport | `Runtime/runtime.rb`, `Runtime/session.rb`, `Runtime/dsl.rb` |
| Verification lifecycle and process ownership | `scripts/reporting.py`, `scripts/processes.py`, `scripts/check.py` |

The engine is a facade. The installation pipeline orders concrete services;
source and DSL adapters isolate external formats; builders construct the project
graph; version and requirement types carry their own invariants. Introduce a
protocol when multiple implementations or a test boundary need it. An extra
factory, base class or wrapper without a distinct responsibility makes the code
harder to follow.

Keep helpers near the responsibility that owns them. Extensions split project
building from integration while retaining one graph and its identity. Shared
archive preparation and process execution belong to dedicated services rather
than copied loops. The Ruby API can be loaded without starting the protocol
session, which makes public-object regressions independently testable.
Cache path selection belongs to `RuntimeBundle.cacheRootPath(from:)`; the command
handlers and engine use the same precedence as the runtime environment without
reading a required value back from a dictionary.

## Style

First-party Swift and C use four spaces. Ruby uses two spaces; Python uses four.
`.editorconfig`, `.swift-format`, `.clang-format` and `ruff.toml` record the rules.
Keep a statement on its own line, use descriptive names and extract a cohesive
operation before adding another nested branch. Comments explain invariants and
reasons that the code alone cannot show.

Format first-party source and tests, including `Package.swift`. Do not rewrite
`Tests/Reference/vendor`, `Sources/ProcessSupport/ArchiveHeaders`, frozen evidence,
generated projects or distribution payloads.

Swift uses the Xcode `swift-format` executable with the repository configuration:

```sh
xcrun swift-format format --in-place --recursive --configuration .swift-format \
  Package.swift Sources Tests/SwiftPodsCoreTests
xcrun swift-format lint --strict --recursive --configuration .swift-format \
  Package.swift Sources Tests/SwiftPodsCoreTests
```

C uses `clang-format`:

```sh
clang-format -i Sources/ProcessSupport/*.c Sources/ProcessSupport/include/*.h
clang-format --dry-run --Werror \
  Sources/ProcessSupport/*.c Sources/ProcessSupport/include/*.h
```

Install Python formatting tools into an ignored local environment. The product
installer continues to support Python 3.9; the tooling adds no runtime dependency:

```sh
python3 -m venv .build/python-tools
.build/python-tools/bin/pip install ruff==0.14.14
.build/python-tools/bin/ruff format scripts
.build/python-tools/bin/ruff check scripts
.build/python-tools/bin/ruff format --check scripts
```

Ruby formatting uses Rufo 0.18.2, installed only for development. With the selected
external Ruby and its `gem` executable on `PATH`:

```sh
gem install --install-dir .build/ruby-format-gems rufo --version 0.18.2 --no-document
GEM_HOME="$PWD/.build/ruby-format-gems" GEM_PATH="$PWD/.build/ruby-format-gems" \
  ruby .build/ruby-format-gems/bin/rufo --check Runtime scripts/ruby_adapter_tests.rb
```

Omit `--check` to format. The standalone Ruby regression runner itself requires
no test gems.

## Verification

Compiler warnings are failures. Start with the native unit corpus and the
verification harness's own regressions:

```sh
swift test -Xswiftc -warnings-as-errors -Xcc -Wall -Xcc -Wextra -Xcc -Werror
python3 scripts/acceptance_tests.py
```

The standard `check.py` also runs `scripts/ruby_adapter_tests.rb` using the
selected external Ruby and a sanitized environment before integration fixtures.
Bootstrap and compilation finish before fixtures run; do not rebuild or edit
source while those fixtures execute.

```sh
python3 scripts/check.py --full --package dist/SwiftPods-review
```

Use `--reference-gem-home PATH` for an already prepared isolated test environment.
A missing required environment remains a failed or unverified check. See
[full acceptance](Full-Acceptance.md) for report identity, external gates and the
difference between local verification and release acceptance.

For a behavior change, first preserve the failing input and its observable
result, then add a regression and fix the cause. Review the final semantic diff
separately from formatting. Check project effects and saved hook mutations;
parsing the DSL alone does not prove a successful application build.
