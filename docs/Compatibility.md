# Input and project compatibility

SwiftPods accepts Podfiles, podspecs, JSON specifications and Podfile.lock files.
The input contract covers dependency declarations, target inheritance, sources,
build settings and supported public hooks. Installation resolves dependencies,
fetches their sources and integrates the resulting products into Xcode.

## Manifests and Ruby

Podfiles and Ruby podspecs execute with an external CRuby through the SwiftPods
DSL adapter. Ruby helpers can use `require_relative`, methods, variables and
closures. JSON specifications use the same specification model.

JSON dependency requirements and deployment minimums accept numeric values as
versions. Swift version arrays can mix strings and numbers; the legacy singular
`swift_version` field also accepts a number. Hooks retain the original attribute
values. Malformed containers and source options fail before installation hooks.

Numeric Git tags and commits retain their scalar spelling: `1` and `1.0` select
different refs. Integral floating values retain their type through hooks and
saved JSON specifications. Ordinary installation preserves the locked checkout;
an explicit update resolves the selector again.
Large fractional selectors also retain Ruby's decimal spelling, so a numeric
tag such as `3826980940661245.5` selects the existing ref without rewriting it.

Ruby is a separate dependency. Homebrew installs it alongside SwiftPods;
manual and CI installations select a compatible executable with
`SWIFTPODS_RUBY`. SwiftPods checks the runtime's minimum version and architecture
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

Deployment upgrades recognize older analyzed manifests that omit inferred
extension safety. Migration records the current context; subsequent dependency
or safety-context changes still require updating the lockfile.

`update` refreshes spec repositories and CDN indexes by default;
`--no-repo-update` uses their cached state. `install --repo-update` refreshes
those catalogs while preserving locked source payloads. Offline operations use
cached catalogs and sources without fetching them.

`outdated` distinguishes the installed version, the version allowed by the
manifest and the latest published version. `--ignore-prerelease` limits the
latest-version check to stable releases. Quick lint checks types throughout
nested library, test and app specifications without building their sources.

Full lint retains Xcode's optional AppIntents extraction skip message as a note
when no AppIntents dependency exists. Compiler warnings and other metadata
warnings remain failures.

Resolution considers combined version requirements, explicit prereleases,
subspec selections and deployment minimums. Warning and configuration options
do not grant permission to select prerelease versions.
An existing prerelease pin remains valid after compatible requirement changes;
updating that pod requires explicit prerelease permission to select it again.
This differs from CocoaPods 1.17.0, which rejects installation after prerelease
permission is removed. The unchanged-input comparison is recorded as
`Resolver.compatible_prerelease_pins` in the compatibility contract.

Explicitly selected `.C` and `.M` sources compile as C++ and Objective-C++.
Pod identities accept Unicode and graphic symbols while rejecting hidden names,
whitespace, control characters and path separators. Module names use valid C99
identifiers derived from the pod identity or an explicit `module_name`.

Sources include local directories, Git, HTTP archives, SVN and Mercurial.
Specifications can come from CDN or Git repositories, with an explicit source
selected per dependency. Lockfiles retain version, source, revision and checksum
information. Compatible metadata fields and identifiers are accepted for
existing projects. Additional integrity metadata verifies artifacts without
replacing dependency resolution.

`swiftpods install --deployment` rejects changes requiring a new lockfile.
`--offline` requires cached specifications and sources. A missing or corrupted
cache entry is an error; it does not authorize selecting another version.
Content-cache inputs may be symbolic links to regular files; publication stores
an independent immutable snapshot without changing the source file's permissions.
Archive validation accounts for case and canonical Unicode path aliases on macOS.
It rejects conflicting link entries, writes through link ancestors and hardlinks
that would relocate symbolic links, before extraction begins.

## Hooks and project objects

The four installation hooks run in order: `pre_install`, `pre_integrate`,
`post_install` and `post_integrate`. Supported installer, sandbox, specification,
target, file accessor and Xcode project objects retain their identity between
phases. Targets with the same name in different projects remain distinct.

Hooks can inspect selected files and resources, change build settings, create
project groups and phases, and save supported project mutations. The file
selection model is shared with project generation so hooks observe the same
public, private and project headers, source files and resource bundles.

Specification metadata getters provide Symbol keys for sources and licenses.
Consumers retain version objects, normalized metadata and stable identity per
specification/platform. Consumer selection uses a platform name; explicit
platform support checks can also consider a deployment minimum.

Plugins use declared options and explicit gem profiles. Each supported plugin
version needs checks for its public operations, phase ordering and saved effects.

See [project hooks](Projects-and-Configurations.md#project-hooks) and
[script phases](Script-Phases.md).

## Xcode integration

Consumer labels and build configuration names must be single filename components.
Path separators, null bytes and the `.` and `..` components fail with a diagnostic
before generated support files are written, including in hardened mode.

The build contract covers static libraries, static frameworks and dynamic
frameworks, with source and binary dependencies. Device, simulator and Mac
Catalyst destinations select distinct binary slices, even when they share a CPU
architecture. Dynamic products are embedded; static products are linked.
Dynamic pods with static source dependencies are rejected to prevent duplicate
code and state in their consumers; use static linkage for that dependency graph.
If two dynamic pods independently load the same static binary SDK in one
consumer configuration, integration fails with `SP-XCODE-STATIC-SDK-CONFLICT`;
use static linkage for that consumer. Separate consumers and mutually exclusive
configurations may each use their own copy.

File patterns, exclusions, header visibility, module maps, ARC, prefix headers,
conditional xcconfig settings, include chains and `$(inherited)` retain their
meaning. Custom configurations control the products linked, embedded and copied
into each consumer. Resources include bundles, localization, asset catalogs,
privacy manifests and on-demand resource tags.

Pod target names that collide with the project, aggregate targets or consumer
resource targets receive stable suffixes. Their module names stay unchanged;
their build configurations, hooks and support files remain independent.
Case variants such as `Foo` and `foo` also receive distinct target labels and
archive names, including when a literal target already uses a generated suffix.
Unicode equivalents such as `Straße` and `STRASSE` use the same protection.
Consumer aggregate names and their `-Resources` names are allocated together,
including consumers with the same name in different projects.
App/test specs and generated app hosts also reserve the existing target namespace.
Pod resource bundles also reserve aggregate and consumer resource target names,
keeping their configurations and resource build phases separate.
Bundle products that differ only in case are rejected when they share a build
output or a consumer destination, preventing resources from being overwritten.
The final copy plan also rejects conflicts between generated bundles and loose
resources, and between embedded SDK filenames, within each build configuration.

Xcconfig selectors accept whitespace before and between conditions; whitespace
within a condition's name or pattern remains literal. Embedded NUL cannot cause
patterns or contexts to match a truncated prefix. Include directives accept
whitespace after `#` and validate the complete directive, including trailing
comments. Include paths are literal: `$(NAME)`, `${NAME}` and `$(SRCROOT)` select
those filesystem names. Missing optional literal paths are skipped. Malformed
conditions and include tokens report their source file and physical line before
hooks or managed writes; invalid xcconfig attribute keys are rejected before
integration.

Glob character classes consume one character within a path segment. Literal
`[` via `[[]`, escaped class members and ampersands keep glob semantics;
regular-expression escapes and set operations are not enabled. Matching covers
the complete filename, including any final newline. These rules apply to source
selection, exclusions, header visibility and resources.

Range endpoints are case-folded before comparison. Matching uses canonical NFC
views of filesystem names while preserving the original paths; component
boundaries remain valid before leading combining marks.

Ruby 3.4.11 implicitly includes `]` in some literal classes and inconsistently
folds literal members and mixed-case ranges. SwiftPods preserves declared members
and consistent case-insensitive selection. These observed differences are recorded
as `Glob.character_class_matching` against the unchanged reference inputs.

Library, test and app specs have their own dependencies and products. Selected
tests can use generated hosts or declared app specs. Multiple generated projects
preserve cross-project dependencies and project ownership.

Scheme arguments and environment values retain tabs, line feeds and carriage
returns through XML character references. CocoaPods 1.17.0 writes these characters
literally, allowing XML attribute normalization to replace them with spaces.
SwiftPods preserves the unchanged input; this reference bug fix is recorded as
`Scheme.XML_whitespace` in the compatibility contract. Characters that XML 1.0
cannot represent fail with `SP-SPEC-SCHEME` before hooks and managed writes.

Declare Swift packages with `spm` alongside pods in the same target. SwiftPods
adds native package and product references; Xcode resolves package versions.
Requirements use exactly one of `exact`, `from`, `range`, `branch` or `revision`.
Versions and selectors are strings; range bounds must increase. Invalid types
and unknown options fail before installation hooks and project writes.
Products accept a name or an array of names. Omitting products keeps the package
reference without attaching a product to the target. Removing the declaration
removes its unused managed reference.
Existing Swift package references are preserved. Xcode updates `Package.resolved`
when resolving product requirements. CMake projects can be regenerated and then
reintegrated with `swiftpods install`.
Repeated installation avoids duplicate references and phases. Deintegration
removes recognized managed integration while preserving user-owned content.
External edits to managed files are detected before replacement.

Package products group targets and may have different names from their modules.
When a consumer has pods and package products, SwiftPods resolves the selected
package targets and checks their modules regardless of the product names.
Module checks follow transitive platform conditions and custom Clang module
maps; host macros and plugins are excluded. Offline installation reuses a
matching resolved package graph from the SwiftPods cache.
Linked Swift packages retain their module aliases during duplicate checks.
Alias propagation follows dependency products reachable from package roots,
using enabled traits and explicit Xcode trait selections. Sibling public product
declarations can rename a dependency shared by other consumers.
Private unused targets and test targets do not introduce public module aliases.
Independent consumers assigning different aliases to the same physical module
receive a conflict diagnostic. A more-dependent rename may resolve that conflict.
Pod custom module maps supply their declared module names; nonmodular static
pods do not claim a module just because their podspec has a module name.
Vendored SDK checks use the selected slice's Clang module map and Swift module
names, independently of the binary product's filename.
Dynamic pod wrappers force-load static SDKs once while retaining XCFramework
slice preparation. Consumer copy phases inspect nested framework and resource
contents on each build, using checksums to refresh files with unchanged timestamps.
Embedded frameworks retain relative internal links; absolute internal links are
rewritten to the embedded copy before thinning or signing. Links outside the
source framework fail the build instead of exposing or changing external files.
Header destination collisions are checked without case distinctions before
installing links. Generated umbrella headers receive names that do not overlap
authored public headers, including a library's own `NAME-umbrella.h`.

Xcconfig assignments use `=`. Xcode rejects `+=` and `?=` during a build,
even when `-showBuildSettings` succeeds. SwiftPods rejects them before hooks
and managed writes with `SP-XCCONFIG-SYNTAX`, preserving the source file and
line in the diagnostic. Use `VALUE = $(inherited) extra` to append values.

Workspace serialization preserves tab, LF and CR in attribute values using XML
character references. Existing user references and managed references remain
resolvable after install, reinstall and deintegrate. The lifecycle regression
checks Xcode scheme discovery for each whitespace character and real Debug/Release
builds of a project with a tab in its parent directory.

See [projects and configurations](Projects-and-Configurations.md),
[test and app specs](Test-and-App-Specs.md) and [BridgeSupport](BridgeSupport.md).

Filesystem selection, directory exclusions, header mappings, Xcode groups,
resource copying and downloaded-source cleanup use path components. A component
starting with a Unicode combining mark retains its complete filename and its
directory boundary. Symlink integrity walks filesystem components before `..`
and checks physical containment, including dangling targets inside the pod.
File matching preserves lexical paths across filesystem aliases, including
dangling generated links during development-pod reinstalls. Downloaded-source
cleanup retains the internal targets and intermediate links needed by selected
files and directories before removing unused payloads.
Regression fixtures compare public file selection with CocoaPods and build and
execute Debug/Release consumers with offline deployment reinstall checks.

Recovery journals, generated project ownership, XCFramework metadata and runtime
containment preserve the same Unicode path boundaries. Relative project
declarations support relocation without changing a deployment lock; owned settings
remain removable afterward. Legacy absolute evaluated project checksums remain
compatible without ignoring dynamic declaration changes. Runtime and packaged
checks reject forbidden engine directories and bundled Ruby before a Ruby probe
executes. SDK metadata rejects CR/LF paths, including a CRLF grapheme.

Pod/subspec identity uses scalar separators throughout resolution, lockfiles,
Xcode variants and lint. Leading combining marks in direct, nested and default
subspec names retain their full names and inherited attributes. Native/reference
fixtures compare the selected file owners; consumers build and execute in both
configurations with stable offline deployment reinstall.
Inline CLI values preserve the same Unicode boundaries. Split and inline project
directory forms select the same directory; malformed or duplicate directory
options fail before creating project state.

Integrity validates declared and physical source boundaries, including Unicode
pod roots and aliases. Contained root aliases seal their target contents;
historical alias-only receipts require an explicit record after installing the
intended graph. Ordinary directory receipts retain their fingerprint format.
Doctor rejects paths or aliases escaping SDK/framework/application containers
while supporting Unicode names, contained aliases and versioned frameworks.

## Paths and build settings

Glob operators remain syntax before combining marks. Literal runs retain NFC
matching, while class members keep their declared scalars. Native/reference
fixtures compare wildcard, class, brace, recursive and escaped patterns; real
Debug/Release consumers verify every selected source and offline reinstall.

Paths and file patterns cannot contain NUL. Invalid declarations fail before
hooks, preparation and project writes; process inputs reject NUL before OS
serialization. Script phase input/output paths reject CR, LF and CRLF.

Environment variable names must be nonempty and contain neither `=` nor NUL.
Schemes validate these names before hooks or project writes; child processes
validate them before OS serialization. Unicode and whitespace in valid names,
empty values and literal `=` in values retain their meaning. Tool execution
captures inherited stdin before allocating output pipes and supplies EOF when
stdin is closed.

Concurrent tool calls retain separate captured streams when standard descriptors
are closed and when an input is rejected. Cancellation shares signal state safely
between child management and the monitor thread, and preserves the interrupted
caller's `errno` when signal forwarding fails.

Child process groups are signalled while their PID remains owned. Reaping waits
for pending signal readers; unknown or duplicate waits return an error without
signalling another process group. Source locations, selectors and headers reject
embedded NUL before filesystem or process interpretation. Literal `%00` and valid
Unicode paths retain their declared meaning.

Dictionary keys with distinct Unicode spellings that are canonically equivalent
are rejected with `SP-DATA-KEY` before conversion to Swift dictionaries. This
applies to parsed JSON, DSL messages and existing project graphs. Individual
Unicode spellings and distinct keys are retained without normalization.
Xcconfig include paths reject embedded NUL with `SP-XCCONFIG-INCLUDE`, identifying
the containing file and line. Optional and nested includes use the same check;
literal `%00` and Unicode filenames remain supported.

PBX path fields and generated project inventory paths reject embedded NUL before
URL conversion or cleanup. Hook graphs are validated before application and
saving. Literal `%00` and Unicode paths remain supported, including shared
scheme filenames beginning with combining marks. Lockfile YAML recognizes
structural separators independently of adjacent combining marks and preserves
the original Unicode strings during offline deployment installs.
Shared scheme container references keep a separate prefix when a child project
name starts with a combining mark, so Xcode resolves the intended build target.

Lockfile YAML preserves inline comments during unchanged installs, plain scalar
types, flow collection shapes, multiline folding, and block scalar chomping.
Malformed delimiters, Unicode escapes, raw non-printable characters, excessive
nesting, and numbers outside the supported exact range have explicit diagnostics.
A lockfile contains one YAML document; additional documents are rejected instead
of merging data that the Ruby reader would ignore. Tags and aliases remain
unsupported. The emitter validates dictionary keys before bridging and escapes
controls and Unicode line separators without normalizing filesystem names.

U+2028/U+2029 in build settings are kept in the project graph, where Xcode can
represent them, rather than written into physical xcconfig lines. This preserves
merged consumer flags and PODS_ROOT. NEL remains part of an xcconfig value, matching
Xcode's reader. Literal CR/LF source paths retain their existing diagnostic and
recovery behavior.

Git and Mercurial source locations recognize colon and slash delimiters as
Unicode scalars, including beside combining characters. Local sources resolve
relative to the manifest and use physical symlink identity in the shared cache.
Distinct projects cannot reuse an unresolved relative source identity. Lockfile
source declarations retain their original spelling. SCP-style Git addresses
remain remote when their path begins with a combining character.

SDK conditions use the selected bundle's canonical versioned name, matching
Xcode's SDK_NAME, while SDKROOT retains its declared spelling. Available bundle
metadata also identifies the platform through SDK aliases. Symbolic SDK lookup
uses the command's developer environment without a process-global SDK cache;
bundle metadata is read afresh. Missing SDKs retain lexical fallback only for
platform analysis. Specific SDK patterns require a resolved bundle and do not
match its nonexistent basename. A single `*` condition is universal, including
unknown axes and unavailable SDKs; `**` and other patterns still need a context.
Missing or explicitly empty SDKROOT uses the default macOS SDK for conditions
without inventing a declared SDKROOT. Literal `auto` has no SDK identity. Quoted
SDKROOT values remain literal rather than being unquoted into bundle paths.

Project settings expose the standard source-root, project, configuration, and
target variables used by SDKROOT expressions. User declarations retain their raw
values and overrides; SOURCE_ROOT follows SRCROOT by default. Relative SDK paths
resolve from the selected project's structural source root, independently of the
CLI working directory and an explicit PROJECT_DIR override. Project-file paths
and redirected source roots remain distinct. Unknown macros cannot select SDK
conditions through the last component of an unresolved path. Xcconfig include
paths retain their literal semantics. PBX base configuration references expand
the standard project, target, and configuration variables in both macro forms;
expanded paths containing NUL receive an explicit diagnostic. Target base-file
references use the project scope, including its xcconfig values and conditions,
before target overrides. A project cannot locate its own base file through a
variable declared by that project, and target-only variables cannot locate the
target base file. The target name default follows project settings and precedes
target declarations. Referenced variable cycles receive an explicit diagnostic.

Build-setting expressions keep literal built-in values separate from source
expressions: names and filesystem roots containing `$(...)`, `${...}`, `$NAME`
or `$$` are not expanded a second time. Missing names evaluate as empty for
SDK selection and PBX base-file references; ordinary declaration queries keep
unknown references. Platform inference uses the effective SDK when metadata
confirms it, or when the expression is entirely empty. An unresolved directory
cannot infer a platform from an unavailable SDK basename through lexical fallback. Nested names, short dollar references, escaped dollars and
retrieval/replacement modifiers are covered by recorded Xcode observations.
Recognized modifiers include case conversion, identifier transforms, lexical path
operations, quote, defaults, relative paths and ancestor tests. Unsupported
modifiers leave known operands unchanged, matching the selected Xcode runtime.
A literal macro in a configuration name is compared in its original context;
the executable fixture uses a safe CONFIGURATION output name because the
selected Xcode reparses its own linker search directories (also reproduced
without SwiftPods). This does not establish unrestricted builds for such names.
The runtime corpus, rather than newer upstream behavior, defines the tested
modifier set (for example, `truncatedversion` remains unchanged in this runtime).
Generated literal PBX paths and filesystem build settings encode dollar signs
once, while authored build-setting expressions retain their syntax. Native
readers decode generated references before filesystem lookup, resource tagging
and relocation. Includes continue to use literal filenames. See the primary
[Swift Build macro model](https://github.com/swiftlang/swift-build/blob/main/SwiftBuild.docc/Core/macro-evaluation.md)
and Apple's [build-setting examples](https://developer.apple.com/videos/play/wwdc2021/10210/?time=738).

Named references to an active definition use that definition's preceding
assignment, including references reached through another setting. `SDKROOT`
can inherit the global macOS default without creating a raw declaration.
SDK guesses made before loading a base file or conditional definition are
provisional; the complete scope still rejects genuine cycles. PBX path
expressions have no synthetic variable visible to the author's expression.
Unknown short `$NAME` references remain literal, unlike unknown bracketed
references during SDK/path evaluation. Unresolved SDK prefixes cannot supply a
platform, and an evaluated NUL in SDKROOT is rejected before hooks or writes.

Generated PODS_* scalar paths respect list-parser backslash escaping while PBX
references retain string-expression encoding. Header lookups containing such
roots use string form. Legacy raw support-file paths are normalized before
analysis and hooks, using the original root and surviving physical support
files to distinguish their spelling; ownership is retained during normalization.
The permanent corpus checks upgrades, offline repeat installs and exact graph
restoration after two deintegrations.

The selected Xcode/LLVM loses literal backslashes in compiler response-file
arguments, independently reproduced in a project that never invokes SwiftPods.
Backslash-root executable fixtures set `CLANG_USE_RESPONSE_FILE=NO`; SDK and
header settings are otherwise unchanged and compiler warnings remain errors.
These fixtures prove generated settings and builds with direct arguments;
unrestricted default-response-file builds of these paths remain an external
limitation. The independent control records whether a newer toolchain fixes it.

Declaration parser types are read from the selected Xcode's option/property
specifications, including scalar strings, paths, booleans, enumerations and
specialized signing fields. Untyped options inherit an existing declaration or
use the string default; undeclared user settings retain list parsing. Core
context variables have explicit types. Namespace selection follows DEVELOPER_DIR
and propagates through SDK, project, target, standalone xcconfig and PBX file
reference evaluation. Unsupported or conflicting option types have an explicit
SP-XCODE-SETTING-TYPE diagnostic when evaluated. The installed runtime is the
oracle for array values; newer generic upstream array parsing is not imported
without a matching project-boundary reproduction.

Generated configuration ownership does not depend on which neighboring file
exists. Current receipts record the literal-path encoding version. Older
installations use retained generated-project reference IDs or physical target
labels/configuration names to establish identity. When producer evidence is
missing, ordinary PBX expression encoding is preserved. Missing support files
are regenerated without borrowing another dollar-spelled configuration. Unknown
receipt encoding versions fail before hooks or managed changes. Upgrade tests
include random UUIDs, raw historical paths, relocated projects, missing generated
projects and unrelated neighboring support files.

## Verify your installation

Check the SwiftPods executable and its Ruby adapter:

```sh
swiftpods runtime verify --json
```

From your Xcode project directory, check installed dependencies against their
recorded checksums:

```sh
swiftpods integrity verify
```

See [Installation and CI](Release.md) for pinned downloads and checksum checks.
