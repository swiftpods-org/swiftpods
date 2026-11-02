# Fastlane

The `fastlane-plugin-swiftpods` plugin runs `swiftpods install` from a lane. It
installs the SwiftPods release pinned in the plugin version once per machine,
verified by its release manifest checksum, so CI needs no separate setup step.

Add it to `fastlane/Pluginfile`, pinned to a release tag:

```ruby
gem 'fastlane-plugin-swiftpods',
    git: 'https://github.com/swiftpods-org/swiftpods.git',
    tag: 'fastlane-v0.3.8'
```

Run Bundler once and commit `Gemfile.lock`: the tag selects the release, while
the lock records the exact Git commit and every transitive gem checksum. For a
repository that does not commit a Bundler lock, use a reviewed 40-character
`ref:` commit instead of `tag:`.

The plugin supports Ruby 3.0 and later and does not force a Fastlane version.
On Ruby 3.0, keep a project lock that selects Fastlane and transitive gems whose
own Ruby requirements include 3.0; the SwiftPods repository tests that contract
against its frozen Ruby-3.0-compatible development graph.

Then call the action from a lane:

```ruby
swiftpods(podfile: 'src/MyApp/Podfile')
swiftpods(podfile: 'src/MyApp/Podfile', deployment: true)
```

The action returns what the Podfile declares, so a lane can depend on it without
reading the Podfile itself:

```ruby
dependencies = swiftpods(podfile: 'src/MyApp/Podfile')
setup_ad_review if dependencies.include?('AppLovinSDK')
```

`include?` matches package and binary SDK names from any target, ignoring case;
`packages` and `binaries` list them.

| Option | Meaning |
| --- | --- |
| `podfile` | The Podfile or its directory (default `Podfile`). |
| `deployment` | Require `Package.resolved` and, when catalog metadata is used, a matching `SwiftPods.lock`; have Xcode validate the complete package graph without updates. |
| `resolve` | Resolve packages with Xcode afterwards; deployment validation stays frozen and never performs a second mutable resolve. |
| `adopt` | Manage package references that were added without SwiftPods. |
| `offline` | Use verified cached binary archives, catalogs and the pinned CLI only. |
| `update_sources` | In a non-deployment install, explicitly resolve newer catalog metadata and write the resulting `SwiftPods.lock`; deployment remains frozen. |
| `allow_external_file_lists` | Trust Podfile-declared script file lists outside the Podfile directory. Keep disabled unless those external files are controlled by the build. |
| `executable` | Use this explicitly trusted SwiftPods executable instead of the pinned release. Fastlane launches this custom path directly. |

The plugin needs Python 3.9 or later for the installer. Every reuse verifies
the complete cached CLI payload against authenticated release metadata before
copying the verified executable into a private, read-only runtime directory.
The installer starts and authenticates that runtime itself while retaining its
file descriptor; Ruby and Fastlane never receive a pathname that they could
reopen after verification. Cache directories must be owned by the current
user, must not be symbolic links, and must not be group- or world-writable.
The supervised CLI keeps project context such as `HOME`, Xcode toolchain
selection and `SSH_AUTH_SOCK`, while executable-loader, Git, shell, archive and
TLS override variables are removed before launch.
The CLI is cached in
`~/Library/Caches/SwiftPods/tools` (or `SWIFTPODS_TOOL_CACHE_ROOT`). Each SwiftPods
release gets a `fastlane-vX.Y.Z` tag whose plugin pins that release.
That annotated tag contains the plugin code from the matching source release
commit plus only its verified `release.json` pin; later changes on `main` cannot
leak into an older plugin tag.
