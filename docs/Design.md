# SwiftPods design

This document replaces the 0.1 specification and every earlier architecture
decision. Where an older document disagrees, this one wins.

## ADR-010: product thesis

SwiftPods is a declarative dependency manifest for Xcode projects, built on
Swift Package Manager. A `Podfile` describes which targets use which Swift
packages, prebuilt binary SDKs, build settings and script phases. SwiftPods
writes those declarations into the Xcode project and nothing else.

- **No CocoaPods compatibility.** Pods, podspecs, spec repositories, the
  CocoaPods resolver, `Pods.xcodeproj`, `Podfile.lock` and install hooks are
  removed. CocoaPods trunk becomes read-only in December 2026; new SDK versions
  arrive as Swift packages or binary archives.
- **No Ruby.** The `Podfile` keeps the familiar Podfile syntax, but SwiftPods
  parses it as data and never executes it. Variables, methods, conditionals and
  `require` are rejected; `include` and `group` replace them.
- **Xcode and SwiftPM decide.** Package versions are resolved by Xcode and
  recorded in its `Package.resolved`. SwiftPods does not predict build settings.
- **Explicit over silent.** A declaration SwiftPods cannot honour is an error
  with its file, line and a fix, never a no-op.

ADR-001 to ADR-009 of the 0.1 specification are withdrawn.

## ADR-011: package catalog

A Podfile can name a package instead of spelling out its repository:
`spm 'Datadog', '~> 3.15'`. Names are looked up in catalogs: Git repositories
with one `<Name>.podfile` per package under `Packages/`, holding only the
repository and default products. Subfolders may group entries; names are unique
across a catalog. Versions stay in the Podfile, because Swift Package Manager
reads them from the package's tags; a package is registered once, not per release.

- `source 'url'` declares catalogs, in lookup order. Without any, SwiftPods uses
  the public catalog `swiftpods-org/swiftpods-catalog`; declared sources replace it unless
  it is listed too, as in CocoaPods.
- Catalogs are cached. `install` uses the cache; `--update-sources` refreshes it;
  `source …, revision:` pins a commit. `--deployment` fails when a catalog now
  resolves a name to a repository the committed `Package.resolved` does not pin.
- An entry may also list releases of a prebuilt SDK, each an archive URL with
  its SHA-256, plus how to link it. A Podfile then writes
  `binary 'HyprMX', '6.4.2'`. One name can have both a package and binary
  releases, when only older versions are archives.
- The public catalog accepts entries by reviewed pull request, checked by
  `swiftpods catalog lint`. Whoever controls a catalog controls where names
  point, so redirects are reviewed like new entries.

## Supported scenarios

1. Declare remote and local Swift packages and the products each target links.
2. Declare prebuilt `.xcframework` SDKs by URL and SHA-256 (or local path);
   SwiftPods turns them into a generated local Swift package. Their resource
   bundles are copied into the app bundle, where those SDKs look for them.
3. Share declarations between projects (`include`) and targets (`group`, target
   nesting, `abstract_target`).
4. Declare build settings and script phases per target.
5. Reproduce the integration in CI: `install --deployment` requires a committed
   `Package.resolved` that satisfies every declared requirement.
6. Migrate: `deintegrate --cocoapods` removes a CocoaPods or SwiftPods 0.1
   integration without CocoaPods or Ruby, and `install --adopt` takes over package
   references another tool added.

Not goals: dependency resolution of its own, a package registry, generating
targets for user code, per-configuration linking (Xcode cannot express it).

## Architecture

```
Podfile ─► Manifest (parse, include, evaluate) ─► Plan ─► Apply
                                                   ▲        │
                    Xcode project (read) ──────────┘        ├─ SwiftPods/ (staged, swapped atomically)
                    binary archives (fetch, verify, cache)  └─ project.pbxproj (one atomic write)
```

| Module | Responsibility |
| --- | --- |
| `SwiftPodsManifest` | Podfile syntax, `include`, groups, inheritance, requirements. Pure; no IO except reading included files through an injected reader. |
| `SwiftPodsXcode` | Reading and writing `project.pbxproj`, typed values, deterministic object identifiers. |
| `SwiftPodsKit` | Integration plan, binary packages, `Package.resolved` checks, Xcode invocations. |
| `swiftpods` | Command line. |

**Ownership without a receipt.** Every object SwiftPods adds to a project has
an identifier derived from what it is (for example the canonical package URL,
or the target and script phase name). An object is SwiftPods' own exactly when
its identifier matches that derivation, so a fresh clone, a deleted cache or a
hand-edited project never loses track of what SwiftPods manages, and objects
users create in Xcode are never touched.

**A project that does not follow the Podfile.** The project references one
generated local package, `SwiftPods/SwiftPodsDependencies`, by a file reference
to its folder, and each target links its product `SwiftPods-<Target>` and has a
generated settings file and the phases `[SwiftPods] Prepare` and
`[SwiftPods] Finish`, which run generated scripts. None of this depends on what
the Podfile declares, so the Podfile changes alone: the package lists
requirements and products, the scripts run script phases, copy binary resource
bundles and check `Podfile.sha256` so that a build after an uninstalled Podfile
change stops, as CocoaPods' manifest check does. A file reference rather than an
`XCLocalSwiftPackageReference` also avoids a crash in Xcode 26.2 when the
package graph shrinks during resolution. A target that embeds a framework target
of the Podfile, such as Unity's app, gets the Finish phase too, whether the
Podfile declares it or not; it embeds the dynamic frameworks Xcode leaves out,
which a build-time script finds without knowing the packages in advance.

**Binary packaging.** SDK archives are used as published, except that
SwiftPods normalizes, in its own copy, the iOS framework slices Xcode would embed
incorrectly (versioned bundles, single-architecture universal static libraries,
missing `Info.plist`), and reports each repair.

**Transactions.** Generated files are rendered into a staging directory and
swapped into place; the project file is written once, atomically, after
everything else succeeded. A failed command leaves the previous state.

## Process rules

- A new decision is a short ADR here, reviewed before code, checked against the
  ones above.
- Changes are small and single-purpose.
- Acceptance is the real-project corpus (Murka games, Mengine) plus unit tests,
  not suite counts.
- Published versions are immutable; every build that ships gets a new version.
