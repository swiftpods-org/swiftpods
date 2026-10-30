# Fastlane

The `fastlane-plugin-swiftpods` plugin runs `swiftpods install` from a lane. It
installs the SwiftPods release pinned in the plugin version once per machine,
verified by its release manifest checksum, so CI needs no separate setup step.

Add it to `fastlane/Pluginfile`, pinned to a release tag:

```ruby
gem 'fastlane-plugin-swiftpods',
    git: 'https://github.com/swiftpods-org/swiftpods.git',
    tag: 'fastlane-v0.3.0'
```

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
| `deployment` | Require a committed `Package.resolved` that satisfies the Podfile. |
| `resolve` | Resolve packages with Xcode afterwards and check the result. |
| `adopt` | Manage package references that were added without SwiftPods. |
| `offline` | Use cached binary archives, catalogs and CLI only. |
| `update_sources` | Fetch the latest catalogs first. |
| `executable` | Use this SwiftPods executable instead of the pinned release. |

The plugin needs Python 3.9 or later for the installer. The CLI is cached in
`~/Library/Caches/SwiftPods/tools` (or `SWIFTPODS_TOOL_CACHE_ROOT`). Each SwiftPods
release gets a `fastlane-vX.Y.Z` tag whose plugin pins that release.
