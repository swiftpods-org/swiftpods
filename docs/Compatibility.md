# Compatibility verification

The compatibility target is the observable behaviour of the 1.17.0 reference.
The reference implementation is used only in isolated tests. Production
resolution, installation, lockfile and Xcode integration execute our Swift code.

`swift test` covers native versions, requirements, resolution/backtracking,
subspec cycles, platform checks, lock pins, project round trips and the existing
integrity, graph, lock and recovery infrastructure.
It also checks XCFramework metadata against Mach-O payloads, device/simulator
selection with identical arm64 architectures, rejected slices/paths and legacy
ARM architecture names.
Script-phase units cover option validation, execution positions, stable updates,
removal, non-inherited subspec phases and nested hardened restrictions.
Supplementary units cover selector expansion, default exclusion, inheritance,
dependency isolation, host validation and independent deployment minimums.

`scripts/native_integration.py` exercises real Ruby Podfile/podspec helpers,
prepare and four live hooks, native project generation, mixed-language macOS
build/run with static framework, dynamic framework and static library, localized resources, privacy manifests and offline deployment reinstall.
It explicitly rejects attempts to load the reference engine. No runtime gems are
needed. The native test report records its exact executed scope and limitations.

`scripts/native_vendor_tests.py` builds actual SDKs with different macOS, iOS
device and simulator binary values and headers. It checks raw static/dynamic
frameworks and static libraries, framework/library XCFrameworks, three source
wrapper linkage modes, transitive binary pods from pinned Git, dynamic embedding,
SDK removal, missing SDK rejection and preserved pod search paths. macOS and iOS
simulator consumers execute; the unsigned iOS device consumer builds from the
same install. `native-vendor.json` records this separate scope. Producer fixtures
and Xcode projects are built without reference-engine or Ruby project libraries.

`scripts/native_script_phase_tests.py` builds and runs a generated-header consumer
with static library/static framework/dynamic framework pods. It checks all five
positions, podspec aliases and platform/subspec declarations, Podfile scripts,
native build environment, file lists/dependency files, no-op and changed-input
builds, always-out-of-date execution, declared sandbox inputs/outputs, removal
preserving unrelated user scripts, build failure propagation and rejection of
invalid phases before managed changes. Hardened JSON rejects nested script
declarations without a Ruby interpreter. Install/reinstall never executes the
declared build phases. Evidence is recorded in `native-script-phases.json`.

`scripts/native_supplementary_tests.py` builds and executes actual macOS XCTest
cases and app-spec executables with static frameworks, dynamic frameworks and
static libraries. It checks default exclusion and explicit selection, own sources,
Info.plist and resources, resource bundles, test-only/app-only dependencies,
consumer isolation, scheme environment, higher test deployment minimums,
generated/named app hosts, offline deployment reinstall and managed scheme
removal. Hardened JSON selects tests/apps and executes XCTest without Ruby.
Selecting an unknown test type fails before managed changes.
`native-supplementary.json` records these checks and remaining platform limits.

`scripts/native_ui_tests.py` runs actual UI interaction on a disposable iOS
simulator, using Swift tests and a Swift app spec. The test launches its named
app host, reads a library-derived value, taps a button and verifies the new value.
The suite also executes a generated UIKit UI host, standalone/hosted Swift unit
tests, own resources/Info.plist entries and scheme environment. It checks UI
runner host associations separately from unit-test bundle loading, three library
linkage modes, consumer isolation, removal, offline reinstall and hardened JSON
selection without Ruby. Simulator products use ad-hoc signing; this does not
certify distribution signing or physical-device execution. The suite owns and
removes its simulator. Evidence is `native-ui.json`; `--bundle PATH` runs the
packaged binary and records `native-packaged-ui.json`.

The legacy corpus under `Tests/Reference/LegacyHarness` needs adaptation to
independent native/reference runs. It is not included in the native passed count.
Full DSL/API parity, complete Apple/Intel matrices, physical devices, signing and release acceptance
remain separate requirements. See `Implementation-Status.md` for implementation
boundaries. Unsupported features must fail rather than silently disappear.

`scripts/reference_compare.py --gem-home PATH` runs the independent 1.17.0
reference with separately prepared test gems and compares the mixed-language
fixture. This optional test environment is never copied into a native release.

`scripts/script_phase_reference.py --gem-home PATH` compares independently
generated pod/Podfile phase order and all options against the 1.17.0 reference.
Both engines build/run the same fixture, skip its generator on a no-op rebuild
and regenerate after an input-file-list dependency changes. This comparison
has its own `native-script-reference.json` evidence and the same isolated test
gem boundary.

`scripts/supplementary_reference.py --gem-home PATH` compares selected spec names
and test/app product types against isolated 1.17.0 projects. Both engines execute
the same XCTest assertions and app-spec program, checking dependency/resource
isolation, Info.plist entries and the test scheme environment. Its evidence is
`native-supplementary-reference.json`; hosted tests and exact project/lock bytes
are outside this reference comparison.

`scripts/ui_reference.py --gem-home PATH` independently installs native and
1.17.0 iOS UI projects, compares test product types and named/generated host
associations, and executes the same button interaction in both engines. It also
checks Swift app/test sources, UI resources, Info.plist and scheme environment.
Its evidence is `native-ui-reference.json`; generated host implementation parity
and other UI execution platforms remain outside this comparison.
Both UI executions set `TOOLCHAIN_DIR` to the toolchain containing the installed
`swiftc`. This avoids Xcode 27 expanding reference Swift library search paths
through the separate Metal toolchain, which has no Swift runtime libraries.
Compiler and linker diagnostics remain enabled.

`scripts/native_batch_tests.py` checks custom Debug/Staging/Release configurations,
all three library linkage modes, target inheritance, per-file ARC, prefix/header
rules, direct localized resources and asset catalogs, multiple pod projects and
multi-platform macOS/iOS builds. It verifies live DSL project saves, hook saves and
execution, object identity, byte-stable offline deployment, deintegration with
preserved settings/user edits, reinstall and stale workspace cleanup.
`--bundle PATH` repeats these checks using a packaged executable.

`scripts/native_management_tests.py` checks Git revision pins across a fresh cache
and branch advance, selected update, offline deployment, repo/cache commands,
inspection, plugin contexts/options/source providers/whitelist/lifecycle, and
disabled project generation. These tests use isolated caches and Git repositories.

`scripts/batch_reference.py --gem-home PATH` independently runs the combined fixture
with multiple pod projects in both engines. Debug/Staging/Release executable
results, inheritance, ARC, prefix headers, resources and hook behavior must match.
Its evidence is `native-batch-reference.json`; exact project bytes, private plugin
APIs and the complete platform matrix are outside this comparison.

`scripts/native_layout_tests.py` runs macOS test/app specs with isolated pod
projects in all three linkage modes, including generated/named unit-test hosts.
It also runs iOS UI interaction with named/generated hosts, hosted unit tests and
hardened split-project installation without Ruby. It checks immediate hook saves,
project/configuration identity, root settings that affect compilation, plugin
project lists, source project preservation, byte-stable offline deployment and
receipt-based cleanup preserving edited files. `--bundle PATH` verifies the
packaged executable. Reports are `native-layout.json` and
`native-packaged-layout.json`.

`scripts/layout_reference.py --gem-home PATH` compares independently generated
child ownership and scheme containers, live hook objects, public context project
lists, real macOS XCTest/app results and named-host iOS UI interaction against the
isolated reference. Its evidence is `native-layout-reference.json`. Exact project
bytes, complete APIs and other destination/linkage combinations remain outside
this comparison. Configuration objects remain live; a reference sort can replace
their build-settings Hash, so Hash identity is not a shared compatibility claim.

`scripts/native_configuration_tests.py` exercises configuration-filtered SDK
linking/embedding and direct, localized, compiled and bundled resources. macOS
Debug/Staging/Release applications run with static framework, dynamic framework
and static library pods. Raw SDKs and XCFrameworks include static/dynamic
frameworks and archives. The fixture checks paths with spaces, same-configuration
incremental exclusion, preserved user resources/exclusions, offline deployment,
deintegration and hardened JSON without Ruby. Enabled/disabled iOS applications
execute on an owned simulator. `--bundle PATH` repeats the suite on the release
binary. Evidence is `native-configuration.json` or
`native-packaged-configuration.json`.

`scripts/configuration_reference.py --gem-home PATH` independently installs both
engines and checks the same macOS Debug/Staging/Release outputs and iOS enabled/
disabled simulator results. Static XCFramework and dynamic raw-framework pod
scenarios compare compiled/localized/direct resources, bundles and SDK link/embed
behaviour. Evidence is `native-configuration-reference.json`; other resource
formats, destination/linkage combinations and distribution signing remain outside
this comparison.
The shared fixture hook marks reference copy/embed scripts as always run to give
empty-output configurations an explicit scheduling contract. Xcode diagnostics
remain enabled; reference incremental script scheduling is not compared.


`scripts/native_variant_tests.py` runs six simultaneous macOS consumers with
five variants of one pod and four variants of its transitive dependency. The
matrix covers different subspecs, archive/static/dynamic framework packaging,
consumer deployment requirements, isolated public headers, XCFrameworks,
framework embedding and direct/bundled resources. It executes
Debug/Staging/Release applications and independent test/app spec variants;
offline deployment preserves project bytes. Reinstall changes split projects to
a single project and replaces old explicit variant dependencies. Deintegration
and reintegration use the same user projects and build outputs. `--bundle PATH`
checks the packaged executable. Reports are `native-variants.json` and
`native-packaged-variants.json`.

`scripts/variant_reference.py --gem-home PATH` compares independently installed
graphs: variant counts, source sets, packaging/linkage, build minima, test/app
scheme counts and hook settings. Evidence is `native-variant-reference.json`.
This comparison does not execute reference variant products: the simultaneous
reference XCFramework fixture produces duplicate copy outputs. Reference archive
header isolation, identical project bytes and other destination/API combinations are not certified.


## Complete contract and operational checks

The current corpus includes these independent checks:

| Report | Executed scope |
|---|---|
| `native-contract-reference.json` | All 26 baseline Podfile methods, 15 installation options and 53 attribute declarations/consumer values; defaults, inheritance, platform setters, aliases, negative types and hook calls |
| `native-contract.json` | Real Swift language-mode selection, nested framework/archive headers, stable typed public hook objects, live pod/consumer mutations, scheme sharing, aggregate xcconfig, lint builds, publication and rejected-push preservation, iOS ODR asset packs |
| `native-runtime.json` | SIGINT with resistant Ruby descendants, bounded cleanup, status 130, busy mutation rejection/recovery, overlapping HTTP downloads, clean/preserve/permissions/incremental source options |
| `native-source-contract.json` | HTTP headers/checksum, external archive snapshots, offline/deployment lock preservation, tampering detection, targeted cleanup, fresh-cache SVN pins and updates, imported Bundler version checks |
| `native-ecosystem.json` | Real CMake Xcode generation/regeneration and app runs; existing local Swift package build/link, PBX and Package.resolved preservation, duplicate detection, platform-aware init and silent/verbose/outdated output, generation-skip hook semantics and BridgeSupport metadata |
| `native-ecosystem-reference.json` | The same ecosystem checks, return to the upstream installer after explicit native deintegration, then direct native replacement, byte-preserved 1.16.2/1.17.0 deployment without Pods, app runs and separately compared BridgeSupport metadata |
| `native-platforms.json` | 60 Debug/Release builds across three linkage modes and ten destinations; 18 separate unsigned device/macOS/Mac Catalyst archives; real XCFramework slices including watchOS arm64_32 |
| `native-variant-reference.json` | Exact library target labels as well as selected sources, packaging/linkage, minima, supplementary scheme counts and hook settings |

The SDK matrix uses the installed Xcode default toolchain explicitly. Simulator
builds are distinct from unsigned device archives. These checks do not establish
physical-device execution, signed distribution, Swift binary module stability,
every supplementary host/destination combination, Intel or remote CI acceptance.
Mercurial requires external `hg`; its independent fixture checks pinned checkout,
selected update, fresh-cache reinstall, offline deployment and cache integrity.

The complete native runner requires Xcode, CMake, Subversion and Mercurial alongside Swift
and external Ruby. Isolated comparisons additionally require separately prepared
reference-only test gems. Production commands never activate those gems.

The required corpus maps to the native suites as follows:

| Specification corpus | Evidence suites |
|---|---|
| T-001–T-004: manifests, helpers, DSL and attributes | sources, integration, contract, contract-reference, supplementary, scripts |
| T-005–T-008: versions, repositories and source pins | units, sources, management, runtime, source-contract |
| T-009–T-014: targets, hooks, binaries, languages, resources and settings | batch, layout, variants, configuration, vendor, platforms, contract, supplementary, UI and their reference comparisons |
| T-015–T-016: legacy locks and no-op installs | units, management, variants, configuration, layout, source-contract |
| T-017–T-018: CMake and existing SwiftPM | ecosystem and ecosystem-reference |
| T-019: external Ruby and distribution | runtime selection units, source-contract, distribution; remote Homebrew/signing acceptance remains separate |
| T-020–T-024: offline, integrity, failure/recovery and restrictions | sources, management, runtime, source-contract, integration, layout, configuration |
| T-025: upstream return | ecosystem-reference after explicit deintegration |

An attribute registry comparison proves declaration/consumer semantics. Actual
build effects are proved by the separate build fixtures, within their recorded
scope. Neither a registry count nor one successful build certifies every possible
combination of attributes, plugins and destinations.


BridgeSupport comparisons run both installers with the same Apple-tool environment,
without reference-only Bundler variables leaking into that external tool. The
reference currently supplies a nonexistent aggregate header path; the native
installer supplies its generated header. This output difference is recorded and
blocks baseline parity. A failed
tool invocation is tested separately in both engines; it warns and retains the
missing resource reference. No direct-tool fallback is counted as installer parity.

The authoritative aggregate is `test-results/check.json`, produced by
`check.py --full --package PATH`. It records source/contract digests, revision,
executable hashes, host/toolchain, requirement/API mappings and external gates.
Missing, stale, skipped or replaced evidence is rejected. Local passing reports
never imply stable acceptance while an external gate is unverified.

Additional regressions are `native-compatibility-reference.json` (locked sources,
hard version constraints, prerelease options, empty public-header patterns and
FileAccessor/project operations), `native-resolver-reference.json` (32 seeded
dependency graphs), `native-xcconfig-reference.json` (external projects and user
include-chains), `native-swift-binary.json` (public swiftinterface consumption,
Debug/Release builds and executed applications), `native-benchmarks.json` (three
local cold/warm/no-op/update samples and unchanged build-input timestamps), and
`native-acceptance-harness.json` (rejected incomplete or tampered evidence).
Supplementary reference fixtures also compare actual installation-result objects
and preserve mutations made through their test/app native targets.

See [Full acceptance](Full-Acceptance.md) for the reproducible invocation and
remaining infrastructure requirements.
