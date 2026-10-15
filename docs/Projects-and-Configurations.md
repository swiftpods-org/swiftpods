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
Repository updates and removal reject local changes. Cache cleanup removes only
managed entries and verifies their integrity first.

Git sources record their resolved commit in the lockfile. A regular install
keeps that revision even when an upstream branch advances. Use `update POD` to
refresh the selected dependency.
