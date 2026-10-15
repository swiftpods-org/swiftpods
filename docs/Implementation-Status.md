# Engine architecture

SwiftPods uses a Swift engine for dependency resolution, downloads, caching,
lockfiles, Xcode project generation and integration. An external CRuby executes
Podfiles, podspecs, helpers, plugins and hooks through the SwiftPods adapter.
The distribution contains the executable and adapter; Ruby is installed
separately.

## Installation pipeline

The engine evaluates declarations, combines requirements and resolves the
selected dependency graph. It preserves applicable version, source and revision
pins. It fetches and verifies source artifacts, prepares independent working
copies, selects files and builds project variants for the consumers.

Variants account for platform, deployment minimum, selected subspecs, linkage
and packaging. Compatible consumers share products; incompatible build
requirements produce separate variants or a diagnostic. Swift version
requirements must have a valid intersection.

The project generator writes pod targets, aggregate targets, support files,
configurations, resources and schemes. Integration connects those products to
the user projects and workspace. It preserves existing Swift package objects
and records ownership of managed files for later updates and deintegration.

## Source and artifact handling

Source adapters support local directories, Git, HTTP archives, SVN and
Mercurial. Specification repositories use CDN or Git access. Revision pins,
specification checksums and artifact digests protect distinct parts of the
installation. Raw and prepared caches verify content before reuse. Local
working directories remain development sources rather than cached copies.

Binary validation checks Mach-O payloads and XCFramework metadata. Slice
selection includes the platform and variant in addition to architecture.
Linking, embedding, resources and signing follow the selected product type.

## Ruby host and hooks

One Ruby host remains alive throughout an installation. Closures, helper state
and public objects retain their identity across the four hook phases.
Project operations are applied through the Swift project model and saved at the
appropriate phase. Hook file accessors use the same file-selection rules as the
project generator.

The adapter validates declarations, installation options and specification
attributes. Plugins run with explicitly configured gem environments. Unsupported
operations fail with a diagnostic. A plugin's private implementation is not a
public API contract.

## Build integration

The generator handles headers and modules, ARC, prefix headers, xcconfig,
conditional configurations, resources, bundles, localization, privacy manifests
and on-demand resources. Library, test and app specs produce separate targets
with their own dependency and resource scopes.

Multiple generated projects use explicit cross-project dependencies. Custom
configurations apply consistently to linking, embedding and resource copying.
User xcconfig includes and inherited settings remain part of the consumer's
configuration. CMake-generated projects can be reintegrated after regeneration.

## Commands and recovery

Lint uses isolated Xcode builds. Repository publication validates the spec,
preserves published versions and leaves the registered checkout unchanged when
a push is rejected. Graph inspection, integrity checks, cache management and
project diagnostics use the same native models as installation.

Mutating operations use locks and a recovery journal. Cancellation reaches
owned child process groups and bounds cleanup. The engine checks managed files
for external changes before overwriting them. Recovery distinguishes completed
operations from interrupted ones and reports effects outside managed state.

## Verification

Run the full corpus against a distribution with:

```sh
python3 scripts/check.py --full --package dist/SwiftPods
```

Compilation finishes before fixtures execute. The runner verifies native
behavior, input contracts, project effects and the packaged executable.
`--skip-apple` omits required checks and cannot establish stable acceptance.

The [input contract](Compatibility.md) describes supported behavior;
[full acceptance](Full-Acceptance.md) defines current-evidence requirements.
Reports apply only to their recorded source, package, toolchain and executed
scope. Source changes invalidate earlier evidence. Required external gates
remain unverified until their dedicated checks have passed.
