# SwiftPods design

This document replaces the 0.1 specification and every earlier architecture
decision. Where an older document disagrees, this one wins.

## Resolver-owned package metadata

Xcode may create or update top-level `.swiftpm` and `.build` directories in
generated local Swift packages. These are derived state, not SwiftPods payload.
After each resolver invocation (including failures), the transaction may advance
its snapshots only if every managed member and the package root identity,
permissions and security metadata are unchanged. Derived roots must be real
directories, never symbolic links. The updated *complete* tree is then durably
recorded and used for exact commit, rollback and cleanup comparisons. Derived
state is not excluded from destructive-operation checks; a crash before the new
snapshot is recorded or a later concurrent edit preserves evidence and fails
closed. Ordinary validation also permits Xcode's group-writable derived state
without relaxing ownership or permissions for managed package contents.

## Nested binary resources

A binary may explicitly select a `.bundle` inside one of its selected
`.xcframework` directories. The framework and the standalone resource have
different generated destinations: the latter is copied under `Resources/` for
embedding in the app. Permit this only within the same binary selection, not
between declarations. Framework/framework and resource/resource overlap,
duplicate sources and colliding output names remain errors. Selected resources
are disjoint, so no source can be copied more than twice through this exception.
Charge the additional nested-resource traversal and bytes against the aggregate
work budget; local artifact snapshots already charge each selected copy.

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
- Catalogs are cached as exact-origin bare Git repositories and entries are
  read directly from committed blobs. No checkout means hooks, smudge filters,
  untracked files and working-tree symlinks cannot change an entry. An explicit
  `source …, revision:` uses a complete 40- or 64-character commit object ID;
  an existing `SwiftPods.lock` pins an unpinned catalog during ordinary installs;
  `install --update-sources` explicitly refreshes it and writes the reviewed result.
  Fetches retain a pack under a kernel-enforced 512 MiB per-file limit; a
  bounded post-fetch scan also rejects excessive aggregate bytes, objects or entries
  before the staging repository becomes durable cache.
- A catalog-backed lookup writes `SwiftPods.lock`: the exact commit of every
  catalog consulted (preserving source precedence) and SHA-256 of every raw
  entry used. Ordinary install and `check` read it before catalog resolution and
  keep existing revisions; `--update-sources` explicitly resolves newer metadata
  without using the current lock. Check leaves it unchanged, and install updates it.
  Keeping the file in version control
  is optional; do it when clean checkouts must reproduce the same metadata.
  Deployment requires the matching file to be present (not necessarily committed),
  requires complete evidence, rejects entry drift and never writes the lock. A Podfile
  whose packages and binaries all have explicit locations does not create or
  require this lock; `Package.resolved` remains its only dependency lock.
- An entry may also list releases of a prebuilt SDK, each an archive URL with
  its SHA-256, plus how to link it. A Podfile then writes
  `binary 'HyprMX', '6.4.2'`. One name can have both a package and binary
  releases, when only older versions are archives. Binary cache transactions live
  in a versioned private subdirectory of the configured cache. SwiftPods does not
  mutate or delete the layout used by an older executable during a rolling upgrade;
  the first install with a new cache version must run online to warm that namespace,
  while the old namespace can be removed later when no older SwiftPods process uses it.
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
5. Reproduce the integration in CI: `install --deployment` requires a present
   `Package.resolved` that satisfies every declared requirement and, only when
   catalog entries are used, a matching `SwiftPods.lock`. The command verifies
   contents, not whether either file is committed; version-control them only
   when a clean checkout must be reproducible. Xcode then
   validates the complete transitive graph with automatic resolution and
   package updates disabled; changing `Package.resolved` is an error.
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
| `SwiftPodsKit` | Integration plan, binary packages, `Package.resolved` and `SwiftPods.lock` checks, Xcode invocations. |
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
missing `Info.plist`), and reports each repair. Finder AppleDouble entries
(`__MACOSX` and `._*`) are still parsed, authenticated and charged to archive
work limits, but are not materialized because Foundation hides them from normal
filesystem enumeration and neither SwiftPM nor Xcode consumes them. Physical
tree walks never call `skipDescendants()` for a symbolic link: Foundation does
not follow links, and skipping one can hide later siblings such as a framework's
`Versions` directory.

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
