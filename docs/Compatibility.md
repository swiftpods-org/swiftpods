# Input and project compatibility

SwiftPods accepts Podfiles, podspecs, JSON specifications and Podfile.lock files.
The input contract covers dependency declarations, target inheritance, sources,
build settings and supported public hooks. Installation resolves dependencies,
fetches their sources and integrates the resulting products into Xcode.

## Manifests and Ruby

Podfiles and Ruby podspecs execute with an external CRuby through the SwiftPods
DSL adapter. Ruby helpers can use `require_relative`, methods, variables and
closures. JSON specifications use the same specification model.

Ruby is a separate dependency. Homebrew installs it alongside SwiftPods;
manual and CI installations select a compatible executable with
`SWIFTPODS_RUBY`. SwiftPods checks the runtime's version, ABI and architecture
before executing project code. User gems and plugins require an explicitly
imported environment rather than an implicit selection of global gems.

The versioned API registry in `Profiles/contract.json` maps Podfile methods,
installation options, podspec attributes and public hook operations to checks.
Unsupported declarations and operations produce a diagnostic rather than a
successful no-op. Private monkey patches and unverified plugin internals require
an additional supported profile.

## Versions, sources and lockfiles

`swiftpods install` preserves locked versions and spec sources when the manifest
and lockfile are unchanged. Changes to requirements must satisfy the remaining
pins. `swiftpods update NAME` unlocks the selected dependency and the necessary
transitive dependencies while retaining unrelated pins.

Resolution considers combined version requirements, explicit prereleases,
subspec selections and deployment minimums. Warning and configuration options
do not grant permission to select prerelease versions.

Sources include local directories, Git, HTTP archives, SVN and Mercurial.
Specifications can come from CDN or Git repositories, with an explicit source
selected per dependency. Lockfiles retain version, source, revision and checksum
information. Compatible metadata fields and identifiers are accepted for
existing projects. Additional integrity metadata verifies artifacts without
replacing dependency resolution.

`swiftpods install --deployment` rejects changes requiring a new lockfile.
`--offline` requires cached specifications and sources. A missing or corrupted
cache entry is an error; it does not authorize selecting another version.

## Hooks and project objects

The four installation hooks run in order: `pre_install`, `pre_integrate`,
`post_install` and `post_integrate`. Supported installer, sandbox, specification,
target, file accessor and Xcode project objects retain their identity between
phases. Targets with the same name in different projects remain distinct.

Hooks can inspect selected files and resources, change build settings, create
project groups and phases, and save supported project mutations. The file
selection model is shared with project generation so hooks observe the same
public, private and project headers, source files and resource bundles.

Plugins use declared options and explicit gem profiles. Each supported plugin
version needs checks for its public operations, phase ordering and saved effects.

See [project hooks](Projects-and-Configurations.md#project-hooks) and
[script phases](Script-Phases.md).

## Xcode integration

The build contract covers static libraries, static frameworks and dynamic
frameworks, with source and binary dependencies. Device, simulator and Mac
Catalyst destinations select distinct binary slices, even when they share a CPU
architecture. Dynamic products are embedded; static products are linked.

File patterns, exclusions, header visibility, module maps, ARC, prefix headers,
conditional xcconfig settings, include chains and `$(inherited)` retain their
meaning. Custom configurations control the products linked, embedded and copied
into each consumer. Resources include bundles, localization, asset catalogs,
privacy manifests and on-demand resource tags.

Library, test and app specs have their own dependencies and products. Selected
tests can use generated hosts or declared app specs. Multiple generated projects
preserve cross-project dependencies and project ownership.

Existing Swift package references and `Package.resolved` are preserved. CMake
projects can be regenerated and then reintegrated with `swiftpods install`.
Repeated installation avoids duplicate references and phases. Deintegration
removes recognized managed integration while preserving user-owned content.
External edits to managed files are detected before replacement.

See [projects and configurations](Projects-and-Configurations.md),
[test and app specs](Test-and-App-Specs.md) and [BridgeSupport](BridgeSupport.md).

## Verifying a release

A successful parse is insufficient: acceptance checks the chosen graph, hook
results, generated files, builds, resources, applications and repeat installs.
The [specification](SwiftPods-Specification-v0.1.md) defines T-001–T-025 and
AC-001–AC-010. [Full acceptance](Full-Acceptance.md) describes the reproducible
runner and evidence format.

Reports identify the source revision, contract digest, distribution, toolchain
and actual platform matrix. A mapped test does not establish every combination
of inputs. Signing, notarization, physical devices, Intel execution, the minimum
macOS and clean installations require their own evidence. An unavailable or
skipped required check remains unverified.
