# SwiftPods

SwiftPods is a dependency manager for Apple platform projects. Describe your
dependencies in a Podfile, install them, and build your app in Xcode.

[Website](https://swiftpods.org) ·
[Installation and CI](docs/Release.md) ·
[GitHub](https://github.com/swiftpods-org/swiftpods-code)

## Installation

```sh
brew install swiftpods
```

Homebrew installs a compatible Ruby as a separate dependency.

Upgrade with:

```sh
brew upgrade swiftpods
```

## Getting started

Create a `Podfile` next to your Xcode project:

```ruby
platform :ios, '15.0'

target 'MyApp' do
  use_frameworks!
  pod 'Alamofire', '~> 5.0'
end
```

Install your dependencies:

```sh
swiftpods install
```

Open the generated `.xcworkspace` in Xcode. Commit `Podfile` and `Podfile.lock`
so your team uses the same dependency versions.

Existing Podfiles, podspecs, Ruby helpers and install hooks can be used directly.
Dependencies can come from spec repositories, Git repositories or local paths.

## Updating dependencies

Update a specific dependency or the whole project:

```sh
swiftpods update Alamofire
swiftpods update
```

## Continuous integration

Install the versions recorded in your lockfile:

```sh
swiftpods install --deployment
```

See [Installation and CI](docs/Release.md) for pinned releases and runner setup.

## Projects and configurations

Use custom build configurations, shared target declarations and project hooks.
See [Projects and configurations](docs/Projects-and-Configurations.md) for
examples, source repositories, cache management and removing integration.

## Project tools

Inspect the installed dependency graph and check your project:

```sh
swiftpods graph --json
swiftpods why Alamofire --json
swiftpods doctor --static --platform ios --variant simulator --arch arm64
```

Use cached dependencies without network downloads, or verify installed artifacts:

```sh
swiftpods install --offline
swiftpods install --integrity
swiftpods integrity verify
```

Offline installation requires the dependencies and metadata to be cached first.

## Swift packages

Declare Swift packages alongside pods in the same target:

```ruby
target 'MyApp' do
  pod 'Networking', :path => './Modules/Networking'
  spm 'swift-collections',
      :git => 'https://github.com/apple/swift-collections.git',
      :from => '1.0.0',
      :products => ['Collections']
end
```

SwiftPods adds package and product references to your Xcode project. Xcode
resolves Swift package versions.

## Build scripts

Declare build scripts in a Podfile or podspec to generate code and process files
with Xcode. [Script phases](docs/Script-Phases.md) support declared inputs and
outputs, file lists and incremental builds.

## Tests and example apps

Define tests and example applications alongside a library using `test_spec` and
`app_spec`. Select them in your Podfile to generate their Xcode targets and shared
schemes. See [Test and app specs](docs/Test-and-App-Specs.md) for declarations,
resources and test hosts.

## Help

```sh
swiftpods --help
```

Visit [swiftpods.org](https://swiftpods.org) for the project website.
