# Projects and configurations

Declare custom Xcode configurations with their build type:

```ruby
project 'MyApp.xcodeproj',
        'Debug' => :debug,
        'Staging' => :debug,
        'Release' => :release

platform :ios, '15.0'

target 'MyApp' do
  use_frameworks! :linkage => :static
  pod 'Networking', :path => './Modules/Networking'
  pod 'DebugTools', :path => './Modules/DebugTools',
      :configurations => ['Debug', 'Staging']
end
```

Generated pod targets include the configurations found in the user projects.
Explicit mappings select debug optimization and testability settings. A pod's
`configurations` option controls consumer linking; its transitive dependencies
follow the same selection. Dynamic frameworks, vendored SDKs, direct resources
and resource bundles are linked, embedded or copied only in the selected
configurations. Xcode compiles localized resources and asset catalogs and selects
the appropriate XCFramework slice. Exclusions use full managed paths and preserve
the user's existing `EXCLUDED_SOURCE_FILE_NAMES` setting.

Projects with `projectDirPath` resolve source files and configurations from that
directory. Target xcconfig can override the project's SDK; explicit target
build settings keep their priority.

A Podfile can declare targets from different projects and Apple platforms.
Generated products, dependencies and public header directories are separated by
platform. Conflicting variants of one pod within the same platform still require
separate installations.

Use abstract targets to share declarations:

```ruby
abstract_target 'Shared' do
  pod 'Networking', :path => './Modules/Networking'

  target 'MyApp' do
    project 'MyApp.xcodeproj'
    target 'HeaderConsumer' do
      project 'HeaderConsumer.xcodeproj'
      inherit! :search_paths
    end
  end

  target 'IndependentApp' do
    project 'IndependentApp.xcodeproj'
    inherit! :none
    pod 'Utilities', :path => './Modules/Utilities',
        :configurations => ['Debug', 'Release']
  end
end
```

The default `:complete` mode inherits dependencies. `:search_paths` exposes
a concrete parent target's dependencies to compilation without adding consumer
link or resource entries. An abstract target does not create an aggregate project
from which to inherit search paths. `:none` keeps only the target's own dependency
declarations; search paths inherited through earlier ancestors can remain.
With `:none`, declare configurations explicitly for dependencies that should
link. Dependencies without a configuration whitelist still resolve but do not
link, matching the selected compatibility contract.

## Separate pod projects

Generate one project per pod:

```ruby
install! 'swiftpods', :generate_multiple_pod_projects => true
```

Each `Pods/Name.xcodeproj` contains that pod's library, selected tests/apps and
resource bundles. Dependencies on other pods use references to their projects.
`Pods/Pods.xcodeproj` contains aggregate targets and shared schemes that point to
the owning child project. The generated workspace includes the child projects.
Original Xcode projects shipped inside a pod's sources are preserved.

Root build settings and groups belong to their project. Hooks can use
`add_dependency` and `dependency_for_target` for targets in referenced child
projects; adding the same dependency again does not create a duplicate. Hook changes to one
project are retained when other projects are saved. `installer.generated_projects`
contains the child projects; a post-install plugin context also provides
`pod_target_subprojects` and `generated_projects`, which includes the main project.

When dependencies or selected specs are removed, unchanged generated project and
scheme files are deleted. Edited stale files remain on disk and their workspace
references are removed. Reinstallation records the generated files explicitly.

Hardened JSON accepts the same boolean installation options through `options`,
including `generate_multiple_pod_projects`. It runs without Ruby or hooks.
Dependencies can declare `"configurations": ["Debug", "Staging"]` in their
`pods` entry to apply the same asset and link filtering.

## Files and resources

Podspecs support recursive file patterns, including multiple `**` components,
brace alternatives and exclusions. Use `public_header_files`,
`private_header_files` and `project_header_files` to declare visibility.
`requires_arc` accepts a boolean or file patterns; matching Objective-C files
compile with ARC and the remaining files compile without ARC. Prefix headers
can be declared through `prefix_header_file` or `prefix_header_contents`.

Direct resources support localized variant groups, asset catalogs, files and
folders. Dynamic frameworks contain their direct resources; static libraries
and static frameworks add them to the consumer's resource build phase.
`resource_bundles` generate independent bundle targets.
Dynamic libraries contain their resource bundles inside the framework; static
libraries and static frameworks copy bundles into the consumer.

Test and app schemes accept action-specific configuration mappings:

```ruby
s.test_spec 'Tests' do |t|
  t.source_files = 'Tests/*.swift'
  t.scheme = {
    :build_configurations => { 'Test' => 'Staging', 'Archive' => 'Release' }
  }
end
```

## Project hooks

Hook objects remain live across installation phases. Common project operations
include changing build settings, creating groups/files and build phases, and
opening an existing project with `Xcodeproj::Project.open`. `save` immediately
persists changes through SwiftPods' project writer.

Changes to managed Swift package objects made through successful hooks are
recorded for the next installation, including explicit `project.save` calls.
External edits to those objects are detected before hooks run.

```ruby
post_install do |installer|
  installer.generated_projects.each do |project|
    project.targets.each do |target|
      target.build_configurations.each do |configuration|
        configuration.build_settings['SWIFT_VERSION'] = '5.0'
      end
    end
    project.save
  end
end
```

When multiple pod projects are enabled, `generated_projects` contains the pod
subprojects; `pods_project` identifies the aggregate project. Public plugin
contexts support pre-install, source-provider and post-install callbacks with
the declared plugin options. Private plugin APIs need separate verification.

## Inspecting and removing integration

```sh
swiftpods ipc podfile Podfile
swiftpods ipc spec Modules/Networking/Networking.podspec
swiftpods spec cat Networking --version 1.0.0 --sources /path/to/specs
swiftpods spec which Networking --sources /path/to/specs
swiftpods repo add private-specs git@example.org:team/specs.git main
swiftpods repo list
swiftpods repo update private-specs
swiftpods cache list Networking
swiftpods cache clean Networking
swiftpods deintegrate
```

`deintegrate` removes generated links, phases, resource references and workspace
references. It restores settings recorded before integration and preserves later
user changes. Source files and lockfiles remain available for the next install.
Swift package attachments created by SwiftPods are removed; user-owned packages
and references still used by other targets are preserved.

`--project-directory=PATH` and `--project-directory PATH` select the same directory,
including a relative path beginning with a Unicode combining mark. Empty, missing
or repeated directory values are rejected before project state is created.
For value options, a following token beginning with `-` is another option, except
for the single `-` value. Use `--project-directory=-name` or
`--project-directory ./-name` for a directory whose name begins with a hyphen.
The ASCII hyphen also starts an option when followed by a Unicode combining mark.
Use an explicit relative path such as `./-́Kit.podspec` for positional filenames
beginning with a hyphen. Lint and repository publication validate their options
before evaluating a podspec.

Global `--project-directory`, `--environment` and `--json` options may appear
before the command, between a command and its action, or after its arguments.
They are validated against the original tokens and removed before dispatch;
their values do not become command arguments. The installation journal retains
the original request and tracks the dispatched operation, including `init` when
global options precede it.

`recover`, `cache verify`, `runtime verify` and `version` reject extra arguments
with `SP-CLI-ARGUMENT`. In particular, an unsupported `recover --dry-run` does not
perform recovery or change the journal, backups or project files.
If no journal exists, recovery returns `SP-RECOVER-NOT-NEEDED` without creating
private project state.

Private installation state is stored in `.swiftpods/` at the nearest Git repository
root. Multiple Podfiles use separate directories inside `.swiftpods/projects/`,
with independent process locks, reports and recovery backups. Add `/.swiftpods/`
to the repository's `.gitignore`. Outside Git, state stays beside the Podfile.
Existing per-project state is moved to the repository directory on the next
mutation; inspection commands can read it without moving files.

Environment import requires a readable Gemfile and lock file. Invalid inputs fail
with `SP-ENV-INPUT` before private state is created. `.swiftpods`, its `environments`
directory and profile directories must be real directories; symlinks fail with
`SP-ENV-PATH`. A failed import removes its own new profile and empty directories
it created, preserving existing profiles and state.

Podspec file paths and glob patterns must not contain NUL. SwiftPods rejects
these declarations with `SP-SPEC-PATH` before hooks or project writes. NUL in
`prepare_command` fails with `SP-SPEC-SCRIPT`; script phase file/path lists reject
CRLF as well as individual line breaks. Ordinary Unicode paths remain supported.

Scheme `environment_variables` names must be nonempty and contain neither `=`
nor NUL. Library, test and app specs reject invalid names with `SP-SPEC-SCHEME`
before hooks or project writes. Valid Unicode names and empty, multiline or
literal `=` values reach the launched process unchanged.

Dictionary keys must remain distinct under Unicode canonical equivalence.
For example, a scheme cannot declare both `CAFÉ` and `CAFE` followed by U+0301;
SwiftPods reports `SP-DATA-KEY` before either declaration is lost. Either spelling
is supported individually and is preserved exactly.

Paths in `#include` and `#include?` cannot contain NUL. An invalid include reports
`SP-XCCONFIG-INCLUDE` at its original file and line, including nested includes,
before hooks or project integration. Literal `%00` is an ordinary part of a
filename and is supported alongside Unicode include paths.

Concurrent tool subprocesses preserve their own stdin, stdout and stderr, including
closed standard descriptors and rejected process inputs. Closed stdin supplies EOF.
Cancellation preserves the interrupted caller's `errno` while forwarding signals.

Dependency and podspec source strings, HTTP headers and global `source`
declarations cannot contain NUL. They fail with `SP-DSL-POD-OPTION` before hooks,
preparation or project writes. Literal `%00` in a source path remains supported;
NUL cannot select that directory by implicit URL encoding.

PBX `path`, `projectDirPath` and `projectRoot` fields cannot contain NUL.
SwiftPods reports `SP-XCODE-PATH` before using or saving these values, including
graphs returned by hooks. Invalid inventory paths report `SP-XCODE-INVENTORY`
before cleanup. A literal `%00` in a filename remains an ordinary filename.
Unicode shared scheme names, including an initial combining mark, retain their
identity in the project inventory and during lockfile parsing on reinstall.
Shared schemes also preserve relative references to Unicode child projects in
multiple-project installations.

Relative project declarations remain portable when the directory containing the
Podfile and its projects is moved or copied. Reinstall with `--deployment --offline`
updates generated configuration references while keeping the lockfile unchanged.
Deintegration restores the recorded settings in the relocated projects and
preserves later user edits. Explicit absolute external projects retain their
selected locations. Legacy metadata that cannot identify an external project
reports `SP-INTEGRATION-LOCATION`; run install using its original relative or
absolute project declarations before deintegrating.

Existing lockfiles with historical absolute evaluated project paths are accepted
only when their remaining evaluated declarations still match. Changing dynamic
dependency requirements continues to fail deployment validation.

Project and generated project paths may begin with a Unicode combining mark.
Generated relative workspace references use a dot component when required for
Xcode to discover the consumer scheme.
Repository updates and removal reject local changes. Cache cleanup removes only
managed entries and verifies their integrity first. A named cleanup matches the
pod name exactly and preserves entries belonging to other pods.
Git cleanup covers both selector and commit copies of the checkout.
Registered spec repository snapshots use the same verified Git receipt. Legacy
snapshots are rebuilt locally from the pinned registered checkout.

Local repository publication prepares its commit in a temporary copy, preserving
Git hooks and configuration. A rejected commit leaves the registered checkout
clean so the command can be retried after correcting the cause.

Git sources record their resolved commit in the lockfile. A regular install
keeps that revision even when an upstream branch advances. Use `update POD` to
refresh the selected dependency.

Git cache entries include a receipt for both their files and resolved revision.
If an older entry lacks this receipt, refresh it with `swiftpods install
--repo-update` while online. After a failed installation that requires recovery,
run `swiftpods recover` before retrying. A cache integrity failure does not replace
the pinned revision in the lockfile.

Updating one pod preserves a shared dependency pinned by another unchanged pod.
Update all affected parents, or explicitly include the shared dependency in the
update command, to unlock it.

For nonlocal sources, `swiftpods integrity record` seals the installed source trees;
`swiftpods integrity verify` checks their recorded contents. Root aliases must stay
inside Pods and seal the target tree. An older receipt that recorded only an alias
must be recreated after installing the intended graph; regular directory receipts
remain compatible.
