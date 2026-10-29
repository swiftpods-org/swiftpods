# Podfile reference

A `Podfile` next to your Xcode project declares the Swift packages, binary SDKs,
build settings and script phases of each target. It uses Podfile syntax, but
SwiftPods reads it as data: nothing in it is executed and Ruby is not needed.

```ruby
platform :ios, '15.4'
project 'Game.xcodeproj'

include '../Shared/ads.podfile'        # groups shared by several projects

group :analytics do
  spm 'https://github.com/firebase/firebase-ios-sdk.git', '~> 13.0',
      products: %w[FirebaseCore FirebaseAnalytics FirebaseCrashlytics]
  script_phase name: 'Crashlytics',
               script: '"${BUILD_DIR%/Build/*}/SourcePackages/checkouts/firebase-ios-sdk/Crashlytics/run"',
               execution_position: :after_compile
end

target 'Game' do
  use :analytics, :ads
  spm 'Networking', path: 'Modules/Networking'
  settings 'OTHER_LDFLAGS' => '$(inherited) -ObjC'

  target 'GameTests' do
    inherit! :search_paths
  end
end
```

## Syntax

Statements are a name followed by arguments, optionally with a `do … end`
block. Values are strings (`'…'`, `"…"` without interpolation), symbols
(`:ios`), numbers, `true`, `false`, arrays (`[…]`, `%w[…]`, `%i[…]`) and hashes
(`key: value`, `:key => value`, `'KEY' => value`). Parentheses around
arguments are optional, `#` starts a comment, and a statement continues on the
next line after `,`, an opening bracket, `=>` or `\`.

Variables, `def`, `if`, `require` and string interpolation are rejected. Use
`include` and `group` to share declarations.

## Top level

| Statement | Meaning |
| --- | --- |
| `platform :ios, '15.0'` | Default platform and deployment target. Platforms: `ios`, `macos` (`osx`), `tvos`, `watchos`, `visionos`. |
| `project 'Path.xcodeproj'` | Default project. Without it, the only `.xcodeproj` next to the Podfile. |
| `source 'https://…/catalog.git'` | A catalog that resolves package names (see below). Without any, the public catalog. |
| `include 'path.podfile'` | Reads `platform`, `group` and `include` statements from another file, relative to the including file. |
| `group :name do … end` | Named declarations a target can `use`; it may take parameters (see below). |
| `target 'Name' do … end` | An existing Xcode target. |
| `abstract_target 'Name' do … end` | A scope whose declarations its nested targets inherit; no Xcode target. |

## Inside targets and groups

| Statement | Meaning |
| --- | --- |
| `spm …` | A Swift package and the products the target links. |
| `binary …` | A prebuilt SDK linked by the target. |
| `use :a, :b` | Applies groups. Groups can use other groups. |
| `use :a, flag: false` | Applies a group with parameter values. |
| `with :flag do … end` | Groups only. Declarations that apply while the parameter is true. |
| `settings 'KEY' => 'value'` | Build settings for the target; add `configurations: ['Debug']` to restrict them. |
| `script_phase name: …, script: …` | A Run Script phase on the target. |
| `inherit! :complete \| :search_paths \| :none` | Targets only. What a nested target takes from its parent (default `:complete`). |
| `platform`, `project` | Targets only. Override the defaults. |

A nested target inherits its parent's declarations: with `:complete` it links
them, with `:none` it ignores them. `:search_paths` (compile against the
parent's packages without linking them) is reserved and currently rejected.

### Group parameters

A group can declare true/false parameters with defaults; `with` blocks inside
it apply only while their parameter is true, and `use` can override each value:

```ruby
group :applovin_max, amazon: true do
  spm 'AppLovinSDK', '13.6.4'
  with :amazon do
    binary 'AppLovinMediationAmazonAdMarketplaceAdapter', '5.6.4.0'
  end
end

target 'Game' do
  use :applovin_max                   # amazon: true
end

target 'Lite' do
  use :applovin_max, amazon: false
end
```

### Swift packages

```ruby
spm 'Firebase', git: 'https://github.com/firebase/firebase-ios-sdk.git',
                exact: '13.0.1', products: %w[FirebaseCore]
spm 'https://github.com/Alamofire/Alamofire.git', '~> 5.9'     # product Alamofire
spm 'Networking', path: 'Modules/Networking'                    # local package
```

The first argument is a name or a Git URL; a URL's last path component (without
`.git`) becomes the name. `products` defaults to that name.

A name without `git`, `path` or URL is looked up in the catalogs, which supply
the repository and default products:

```ruby
spm 'Datadog', '~> 3.15'                                   # DatadogCore
spm 'Firebase', '~> 13.0', products: %w[FirebaseCore]      # no default products
```

Some catalog packages encode a longer vendor version in their major version,
as AppLovin MAX adapters do (adapter 13.9.0.0 is package version 13090000.0.0).
For those, write the vendor's version: `spm 'AppLovinMediationGoogleAdapter', '13.9.0.0'`
or `'~> 13.9.0.0'`; SwiftPods translates it.

The public catalog is [swiftpods-org/swiftpods-catalog](https://github.com/swiftpods-org/swiftpods-catalog).
`source` lines replace it with your own catalogs, searched in order; list it too
to keep using it. Catalogs are cached: `install --update-sources` fetches the
latest, and `source 'url', revision: 'a1b2c3d'` pins a commit. `swiftpods search
NAME` finds entries.

A remote package needs exactly one requirement:

| Requirement | Xcode requirement |
| --- | --- |
| `'1.2.3'`, `'= 1.2.3'`, `exact: '1.2.3'` | Exact version |
| `'~> 1.2'`, `'~> 1'`, `from: '1.2.0'`, `up_to_next_major: '1.2.0'` | Up to next major from 1.2.0 |
| `'~> 1.2.3'`, `up_to_next_minor: '1.2.3'` | Up to next minor from 1.2.3 |
| `'>= 1.2', '< 2.0'`, `range: ['1.2', '2.0']` | Range 1.2.0 ..< 2.0.0 |
| `branch: 'main'`, `revision: 'a1b2c3…'` | Branch or commit |

Versions must have at most three numeric components. A lower bound without an
upper bound is rejected. `link: false` adds the package without linking any
product into the target.

### Binary SDKs

Binaries in the catalog need only a version, as `binary 'HyprMX', '6.4.2'`; the
catalog supplies the archive, its checksum and how to link it.

```ruby
binary 'HyprMXAdapter',
       url: 'https://example.com/HyprMX-6.4.2.zip',
       sha256: '3f1c…',
       system_frameworks: %w[WebKit AVFoundation],
       libraries: %w[z c++],
       linker_flags: ['-ObjC']
binary 'Analytics', path: 'Vendor/Analytics.xcframework'
```

SwiftPods downloads the archive (`.zip`, `.tar.gz`, `.tgz`, `.tar.xz`), checks
its SHA-256, and exposes every `.xcframework` inside it as one product named
after the declaration. Use `xcframeworks: ['Path/In/Archive.xcframework']` (or just
`'Archive.xcframework'`, found at any depth) to choose some of them and `dependencies: ['OtherBinary']` when one binary
requires another. `resources: ['SDK/Resources.bundle']` copies resource bundles
into the app bundle of every target that links the binary, where SDKs that
shipped through CocoaPods expect them. Archives are cached by checksum.

Xcode embeds every framework of a binary package, which CocoaPods never did for
static ones. In its copy of an iOS framework, SwiftPods therefore moves a
versioned bundle's contents to the top level, unwraps a static library packed in
a single-architecture universal binary, and adds a minimal `Info.plist` when one
is missing. `swiftpods install` prints a note for each repair.

### Script phases

`name` and `script` are required. Optional: `shell_path`, `input_files`,
`output_files`, `input_file_lists`, `output_file_lists`,
`execution_position` (`:before_compile`, `:after_compile`, `:any`),
`based_on_dependency_analysis`, `show_env_vars_in_log`.

## Not supported

`pod`, `use_frameworks!`, `use_modular_headers!`,
`inhibit_all_warnings!`, `workspace`, `install!`, `plugin` and install hooks
(`pre_install`, `post_install`, `pre_integrate`, `post_integrate`) fail with an
error that names a replacement. Per-configuration linking is not supported
because Xcode cannot link a package product in some configurations only.
