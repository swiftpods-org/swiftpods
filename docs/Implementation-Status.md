# Native engine implementation

SwiftPods resolves and installs dependencies, writes lockfiles, and generates and
integrates Xcode projects in its own Swift engine. The production bundle contains
that executable and our Ruby DSL adapter. Ruby is installed separately and is
used for user Podfiles, podspecs, helpers, plugins and hooks. The bundle contains
no reference engine, third-party installation gems or Ruby interpreter.

The compatibility profile remains experimental until stable acceptance is
established. Passing fixtures certify the scope recorded in their reports.

Implemented functionality includes:

- Native version comparison, requirements and backtracking; default and explicit
  subspec selections; platform constraints; targeted updates that unlock
  transitive dependencies while preserving unrelated pins.
- Local, Git, HTTP archive, SVN and Mercurial source adapters; CDN and Git spec
  repositories; multiple sources and explicit source identity; revision and
  checksum pins; integrity-checked raw and prepared caches; offline installs.
  External podspec checksums use the profile serialization without repeating Ruby
  evaluation; legacy raw checksums remain accepted for the same input.
- All 26 baseline Podfile methods, 15 installation options and 53 declared
  podspec attributes in the Ruby adapter. Unknown declarations fail explicitly.
  Inheritance, platform setters, defaults and consumer values are compared with
  an independently executed reference.
- Native effects for Swift version requirements, modules, nested public/private
  headers, ARC, prefix headers, xcconfig, library/framework linkage, resources,
  bundles, localization, privacy manifests and on-demand resource tags.
- Variants for selected subspecs, packaging, linkage, platforms and deployment
  requirements. Compatible consumers share targets. Swift versions satisfy the
  intersection of consumer constraints. Scope labels follow the reference
  algorithm, including abbreviated long suffixes.
- Xcode projects, custom configurations and schemes; multiple generated projects
  and custom pod project names; explicit cross-project dependencies; conditional
  resources and binaries; consumer project analysis and aggregate xcconfig files.
- Mach-O and XCFramework validation, destination slice selection, static linking
  and dynamic embedding. Device, simulator and Mac Catalyst are distinct.
- Library, test and app specs with isolated dependencies, resources and scripts;
  standalone/hosted XCTest, app-spec hosts and UI runners; generated schemes.
- Four ordered Ruby hook phases with stable public installer/spec/target objects,
  typed build types, live project objects and preserved project mutations.
  Skipped project generation retains consumer objects and the correct hook order;
  BridgeSupport uses the Apple metadata tool for aggregate declarations.
  Declared plugins use explicit isolated gem environments.
- Native spec/lib lint with isolated real Xcode builds; publication to registered
  Git spec repositories; immutable published versions; rejected pushes leave the
  registered checkout unchanged. Repository updates use fast-forward merges.
- Inspection, graph, why, outdated, doctor, integrity, cache/repo management,
  deintegration, journal/recovery and concurrent mutation protection. Cancellation
  forwards signals to owned process groups and escalates bounded cleanup.
- CMake regeneration/reintegration and coexistence with existing Swift packages,
  preserving package objects and Package.resolved. Known duplicate SDK identities
  fail explicitly. SwiftPM DSL additions remain opt-in.

Run the complete native corpus with:

```sh
python3 scripts/check.py --full --package dist/SwiftPods
```

The full runner prepares isolated frozen reference gems, finishes compilation
before fixtures, and verifies the assembled distribution. `--skip-apple` is an
explicitly incomplete smoke check. See [full acceptance](Full-Acceptance.md).
Each report records the source digest, host, toolchain, exact verified scope and
remaining limits. A source change invalidates earlier evidence. Packaging attaches
only passing reports for the packaged source snapshot.

[Compatibility verification](Compatibility.md) maps scenarios to their checks.
Reference code and gems live only under test storage and are excluded from
runtime preparation and distribution packaging.

Remaining acceptance boundaries are remote authenticated operations, actual
Homebrew installation, distribution signing/notarization, physical devices,
Intel execution, Swift binary module stability and supplementary hosts across
every Apple platform. The Mercurial adapter requires external `hg` and has local locked-revision,
selected-update, cache-integrity and offline fixtures. Arbitrary private plugin APIs and unknown SDK identities hidden
inside Swift packages are outside the supported profile. Exact Xcode project
bytes are not an acceptance claim.
