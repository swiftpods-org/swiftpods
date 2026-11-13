# SwiftPods

SwiftPods gives Xcode projects a declarative dependency manifest. A `Podfile`
says which targets use which Swift packages, prebuilt binary SDKs, build
settings and script phases; `swiftpods install` adds Swift package products
directly to their Xcode targets and generates a local package for binary SDKs.
Xcode and Swift Package Manager resolve and build everything.

The `Podfile` keeps the Podfile syntax you know, but it is read as data: there is
no Ruby, no CocoaPods and no `Pods` project.

[Website](https://swiftpods.org) · [Podfile reference](docs/Podfile.md) ·
[Design](docs/Design.md) · [Installation and releases](docs/Release.md)

## Installation

```sh
brew tap swiftpods-org/swiftpods https://github.com/swiftpods-org/swiftpods.git
brew install swiftpods-org/swiftpods/swiftpods
```

Or [build from source](docs/Development.md).

## Getting started

Create a `Podfile` next to your Xcode project:

```ruby
platform :ios, '15.0'

target 'MyApp' do
  spm 'https://github.com/Alamofire/Alamofire.git', '~> 5.9'
  spm 'Networking', path: 'Modules/Networking'
  binary 'AdsSDK', url: 'https://example.com/AdsSDK-2.1.0.zip',
                   sha256: '3f1c…', linker_flags: ['-ObjC']

  target 'MyAppTests' do
    spm 'https://github.com/pointfreeco/swift-snapshot-testing.git', exact: '1.18.0',
        products: ['SnapshotTesting']
  end
end
```

Then:

```sh
swiftpods install --resolve
```

The first install adds direct Swift package products, one generated binary
container product, a settings file and two Run Script phases to each target.
Binary SDKs, settings and scripts live in the generated `SwiftPods/` directory:
add it to `.gitignore`, and commit the `Podfile`, project changes and, for pinned
transitive versions, `Package.resolved`. As with `pod install`, run
`swiftpods install` after the `Podfile` changes; until then the build stops and
says so.

## Sharing declarations

Groups replace Ruby helper methods, and `include` replaces `require_relative`,
so several projects can share one list of SDKs:

```ruby
# ../Shared/ads.podfile
group :ads do
  spm 'https://github.com/AppLovin/AppLovin-MAX-Swift-Package.git', '~> 13.6',
      products: ['AppLovinSDK']
end
```

```ruby
# Podfile
include '../Shared/ads.podfile'

target 'Game' do
  use :ads
  settings 'OTHER_LDFLAGS' => '$(inherited) -ObjC'
end
```

Well-known packages can be named without their repository; SwiftPods looks
them up in the [public catalog](https://github.com/swiftpods-org/swiftpods-catalog):

```ruby
spm 'Datadog', '~> 3.15'
spm 'Firebase', '~> 13.0', products: %w[FirebaseCore FirebaseAnalytics]
```

See the [Podfile reference](docs/Podfile.md) for target inheritance,
`abstract_target`, version requirements, binaries, settings and script phases.

## Commands

```sh
swiftpods check                 # read the Podfile and show what each target gets
swiftpods search Datadog        # find a package in the catalog
swiftpods install               # write it into the Xcode projects
swiftpods install --deployment  # CI: verify dependency lock and any used catalog lock
swiftpods install --project ../Build/App.xcodeproj  # the project of targets that name none
swiftpods deintegrate           # remove everything SwiftPods added
swiftpods deintegrate --cocoapods  # also remove a CocoaPods or SwiftPods 0.1 integration
```

When a declaration is resolved through a catalog, `swiftpods install` writes
`SwiftPods.lock` with the catalog's complete Git commit ID and the SHA-256 of
the raw entry. Later installs and `swiftpods check` reuse that commit;
`--update-sources` is the explicit operation that resolves newer catalog metadata
without using the current lock. `check --update-sources` leaves the lock unchanged,
while `install --update-sources` updates it. Version-controlling
`SwiftPods.lock` together with `Package.resolved` is optional; do it when clean
checkouts must reproduce the same metadata. Without it, every clean checkout
resolves the catalog again and can select different dependency metadata.
`--deployment` verifies `Package.resolved` and, when catalog entries are used,
`SwiftPods.lock`; it asks Xcode to validate the complete package graph using
only `Package.resolved`, with automatic resolution and package updates disabled.
It requires a matching `SwiftPods.lock` to be present when
catalog entries are used, but does not require that file to be committed. It fails if Xcode
changes `Package.resolved`. A Podfile made only of
explicit `git`, `path` and binary `url` declarations neither creates nor
requires `SwiftPods.lock`.

`install` rewrites each generated package, settings and scripts folder as a whole,
so files written into one, such as build products, are removed.
`deintegrate` removes only SwiftPods' generated packages, settings, scripts and
ownership marker. Unknown files or directories inside `SwiftPods/` are preserved.

`--json` gives machine-readable output. In Fastlane lanes, use the
[SwiftPods plugin](docs/Fastlane.md); in Unity, the [SwiftPods package](docs/Unity.md).

## Coming from CocoaPods or SwiftPods 0.1

Replace each `pod` with the SDK's Swift package (`spm`) or its prebuilt archive
(`binary`), move `post_install` build settings into `settings`, and replace Ruby
helpers with `group`, `use` and `include`. Remove the old integration first with
`swiftpods deintegrate --cocoapods`, which needs neither CocoaPods nor Ruby.
Package references a previous tool added are taken over with
`swiftpods install --adopt`. Every CocoaPods construct SwiftPods does not
support fails with an error that names its replacement.

## License

SwiftPods is distributed under the [MIT License](LICENSE).
