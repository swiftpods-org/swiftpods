# SwiftPods design

This document replaces the 0.1 specification and every earlier architecture
decision. Where an older document disagrees, this one wins.

## Nested binary resources

A binary may explicitly select a `.bundle` inside one of its selected
`.xcframework` directories. The framework and the standalone resource have
different generated destinations: the latter is copied under `Resources/` for
embedding in the app. Permit this only within the same binary selection, not
between declarations. Framework/framework and resource/resource overlap,
duplicate sources and colliding output names remain errors. Selected resources
are disjoint, so no source can be copied more than twice through this exception.

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
- Catalogs are cached as bare Git repositories, one per origin, and entries are
  read directly from committed blobs. No checkout means hooks, smudge filters,
  untracked files and working-tree symlinks cannot change an entry. Git runs with
  the user's own configuration, credentials and SSH settings. An explicit
  `source …, revision:` uses a complete 40- or 64-character commit object ID;
  an existing `SwiftPods.lock` pins an unpinned catalog during ordinary installs;
  `install --update-sources` explicitly refreshes it and writes the reviewed result.
- A catalog-backed lookup writes `SwiftPods.lock`: the exact commit of every
  catalog consulted (preserving source precedence) and SHA-256 of every raw
  entry used. Ordinary install and `check` read it before catalog resolution and
  keep existing revisions; `--update-sources` explicitly resolves newer metadata
  without using the current lock. Check leaves it unchanged, and install updates it.
  Keeping the file in version control
  is optional; do it when clean checkouts must reproduce the same metadata.
  Deployment requires the matching file to be present (not necessarily committed),
  requires complete evidence, rejects entry drift and never writes the lock. A Podfile
  with only ordinary explicit packages and binaries does not create or require
  this lock. `Package.resolved` remains its only dependency lock.
- An entry may also list releases of a prebuilt SDK, each an archive URL with
  its SHA-256, plus how to link it. A Podfile then writes
  `binary 'HyprMX', '6.4.2'`. One name can have both a package and binary
  releases, when only older versions are archives. The binary cache keeps one
  entry per SHA-256 in a versioned subdirectory; layouts of older releases stay in
  theirs, so the first install with a new layout must run online.
- The public catalog accepts entries by reviewed pull request, checked by
  `swiftpods catalog lint`. Whoever controls a catalog controls where names
  point, so redirects are reviewed like new entries.

## ADR-012: threat model

SwiftPods trusts the machine it runs on and the user who runs it. What comes from
elsewhere is not trusted:

- A binary archive must match the Podfile's SHA-256 before it is used, and is
  unpacked only inside its cache entry: absolute paths, `..`, links pointing
  outside, writing through a link, special files and encrypted entries are
  rejected. A remote repository tree for an override is checked the same way.
- Catalog revisions and override commits are full commit IDs, recorded with
  content digests in `SwiftPods.lock`.
- The Podfile is parsed as data and never executed.

SwiftPods does not defend against another process of the same user changing
files while it runs: such a process can already edit the Podfile or the generated
build scripts. Earlier releases did (descriptor-anchored paths, ctime, ACL and
extended-attribute snapshots, a crash-recovery journal, a sandboxed archive
worker, work budgets, DNS pinning). That code was most of the tool, caused most of
its bugs, and rejected legitimate setups such as internal Git servers and
`~/.ssh/config`; it was removed.

## ADR-013: pinned local package overrides

`spm '<Git URL>', revision: '<full commit ID>', override: true` installs a local
SwiftPM package in `SwiftPods/Overrides/<identity>`. The directory name gives
Xcode the identity of the remote package it replaces throughout that project's
graph. Declare `products:` to link directly from a target. An override without
products contributes only the package reference. Xcode resolves the remaining
graph and omits the local identity from `Package.resolved`.

- The override requires an exact 40- or 64-character commit ID and a supported
  HTTPS or SSH URL. SwiftPods reads the complete tree through its bare Git
  cache. It preserves regular file bytes and the executable bit and
  accepts relative links that resolve inside the managed tree.
- `submodules: true` on an override permits one level of gitlinks. Each must
  have a corresponding path and absolute HTTPS or SSH URL in the committed
  `.gitmodules`. The gitlink selects the exact child commit. Nested gitlinks are
  rejected.
- SwiftPods stages the complete override directory with the other generated
  files. `SwiftPods.lock` records the origin, commit, submodule option and
  SHA-256 of the materialized tree, including any tracked paths in `.swiftpm`
  and `.build`. The lock lists those paths, so other entries Xcode creates in
  those directories do not change the digest.
- Ordinary install creates or restores the tree. `--offline` can restore it
  from the warmed bare cache, which retains each used revision across fetches.
  Deployment requires the matching lock and
  materialized tree, verifies the digest and leaves the override payload
  untouched. It still asks Xcode to validate the remaining frozen graph.

## Supported scenarios

1. Declare remote and local Swift packages and the products each target links.
2. Declare prebuilt `.xcframework` SDKs by URL and SHA-256 (or local path);
   SwiftPods turns them into a generated local Swift package. Their resource
   bundles are copied into the app bundle, where those SDKs look for them.
3. Share declarations between projects (`include`) and targets (`group`, target
   nesting, `abstract_target`).
4. Declare build settings and script phases per target.
5. Reproduce the integration in CI: `install --deployment` requires a matching
   `Package.resolved` for remote dependencies, including those of local
   packages. Catalog entries and package overrides also require a matching `SwiftPods.lock`. The command verifies
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
or the target's object identifier and the script phase name). An object is
SwiftPods' own exactly when its identifier matches that derivation, so a fresh
clone, a deleted cache, a renamed target or a hand-edited project never loses
track of what SwiftPods manages, and objects users create in Xcode are never
touched. Identifiers of releases that derived them from target names are still
recognized and replaced on the next install.

**Products are direct target dependencies.** Each remote or local Swift package
product is attached directly to its Xcode target. A generated wrapper package
cannot provide the same result: Swift can see some transitive modules, but
Objective-C and Objective-C++ compilation does not receive the underlying
module maps or generated Swift headers. Direct products make module visibility
an Xcode responsibility for every supported source language. Xcode omits those
generated module maps from Clang's search path for native static-library
targets, so their Prepare phase publishes a target-scoped external module map
for linked products that actually generated one. App and framework targets with
ordinary linked products keep Xcode's native path.

**Compile-only products are target dependencies.** `link: false` is represented
by a `PBXTargetDependency` with a package `productRef`, outside both Frameworks
and `packageProductDependencies`. The latter causes Xcode to include SDK objects
in static archives even when no Frameworks entry exists. The application links
the SDK normally; static plugins only compile against it. Product and dependency
IDs are deterministic and recognized through both target relationship lists, so
reinstalling, changing linkage, updating/removing products and deintegrating also
remove obsolete dependency objects while preserving user-owned target dependencies.

Xcode does not impart package compiler settings through these build dependencies.
For targets using this mode, Prepare generates a target-scoped external module
map and Clang response file. Xcode's current `DependencyStaticMetadataFileList`
and `DependencyMetadataFileList` select the actual transitive module closure,
including products whose names differ from their modules. Generated maps supply
Swift Objective-C interfaces and default Clang maps; package target PIF records
locate explicit source module maps and their public include paths. Prepare reads
the current build description selected by Xcode's `prior-build-descriptions.txt`,
including its compiler arguments and response-file attachments. Only source maps
and include roots used by that description are accepted from PIF, and generated
maps must belong to its outputs. This excludes cached records from other checkout
roots even when their module names and module-map contents match. Header/umbrella
declarations in generated maps supply the remaining public include directories.
Old maps outside the current closure are excluded and the
outputs are rebuilt on every Prepare. Conflicting source-map candidates fail
explicitly rather than choosing a cached version. The host helper is generated
Swift source compiled by the selected Xcode in the target's temporary directory;
only its declared map and response outputs go into DerivedSources. Script
sandboxing remains enabled. Empty binary containers for compile-only static
targets remain build dependencies, avoiding empty archive-member warnings.
Compile-only targets enable recursive script inputs so the declared module-map
and XCBuildData directories also grant read access to their contents.

Compile-only framework and Swift module searches use the shared package products
at `$(BUILD_DIR)/$(CONFIGURATION)$(EFFECTIVE_PLATFORM_NAME)` and its
`PackageFrameworks` directory. Static plugins may override
`CONFIGURATION_BUILD_DIR`, so their `BUILT_PRODUCTS_DIR` is insufficient during
archive. Generated search paths retain inherited values and quote each path.
Archive's live XCBuildData remains the source of truth even when PIF records
reside in the shared intermediates directory above `ArchiveIntermediates`.
Both caches are filtered against that live description, including when a stale
archive-local cache exists. Prepare declares the shared PIF cache separately for
script sandboxing; its path follows `OBJROOT`, including custom intermediates
locations, rather than assuming the default DerivedData directory.

The project also references `SwiftPods/SwiftPodsDependencies` by a file
reference and each target links its stable binary-container product
`SwiftPods-<Target>`. Each target has a generated settings file and the phases
`[SwiftPods] Prepare` and `[SwiftPods] Finish`. Changing Swift package
declarations updates the project's package references and product links;
binary contents, scripts and settings change under `SwiftPods/`. The scripts
run script phases, copy binary resource bundles and check `Podfile.sha256` so
that a build after an uninstalled Podfile change stops. A file reference rather
than an `XCLocalSwiftPackageReference` also avoids a crash in Xcode 26.2 when the
generated package graph shrinks during resolution. A target that embeds a framework target
of the Podfile, such as Unity's app, gets the Finish phase too, whether the
Podfile declares it or not; it embeds the dynamic frameworks Xcode leaves out,
which a build-time script finds without knowing the packages in advance.
Application settings include the platform's bundle-relative Frameworks runtime
search path, so removing a CocoaPods base configuration cannot leave embedded
dynamic frameworks reachable only through a build-machine path.

**Binary packaging.** SDK archives are used as published, except that
SwiftPods normalizes, in its own copy, the iOS framework slices Xcode would embed
incorrectly (versioned bundles, single-architecture universal static libraries,
missing `Info.plist`), and reports each repair. A signed XCFramework is left
unmodified, since Xcode verifies its signature; the note names the repair it
needed. Finder AppleDouble entries (`__MACOSX` and `._*`) are not unpacked.

**Transactions.** Generated folders are rendered into a staging directory inside
`SwiftPods/` and swapped into place by rename. Project files are written
atomically after them, followed by `SwiftPods.lock`. A failed command attempts to
restore what it replaced. If any restore fails, the error identifies the failed
paths and any staging directory with generated backups. A later install can
regenerate the output and leaves staging directories that still contain backups
available for recovery.

SIGINT, SIGTERM and SIGHUP fail the command the same way. SwiftPods passes the
signal to the process group of the tool it is running and stops any processes
remaining in that group before rolling back. A relay in the foreground group
reports SIGINT and SIGHUP received by that group, including a Ctrl-C. SwiftPods
ends by the received signal if it interrupted the operation before the final
transaction check. Past that check, the command reports the committed result.
A calling script receives SwiftPods' termination status.
Another signal, such as SIGKILL, or a crash can still leave a change half applied.

## Process rules

- A new decision is a short ADR here, reviewed before code, checked against the
  ones above.
- Changes are small and single-purpose.
- Acceptance is the real-project corpus (Murka games, Mengine) plus unit tests,
  not suite counts.
- Published versions are immutable; every build that ships gets a new version.
