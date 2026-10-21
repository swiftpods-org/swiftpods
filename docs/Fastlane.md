# Fastlane

The `fastlane-plugin-swiftpods` plugin provides the `swiftpods(...)` action.
The action installs its pinned SwiftPods CLI automatically, verifies the release
checksums, and reuses it from `~/Library/Caches/SwiftPods/tools`. Setup requires
Python 3.9+ and a compatible Ruby. No installer file is needed in your project or CI.

To use an existing executable, pass `executable: 'swiftpods'` or set
`SWIFTPODS_EXECUTABLE`. Set `SWIFTPODS_TOOL_CACHE_ROOT` to change the CLI cache.

Add the plugin to `fastlane/Pluginfile`, selecting its `fastlane-vVERSION` release
tag in place of `PLUGIN_RELEASE_TAG`:

```ruby
gem 'fastlane-plugin-swiftpods',
    git: 'https://github.com/swiftpods-org/swiftpods.git',
    tag: 'PLUGIN_RELEASE_TAG'
```

Your `Gemfile` must load the `Pluginfile`:

```ruby
source 'https://rubygems.org'
gem 'fastlane'

plugins_path = File.join(__dir__, 'fastlane', 'Pluginfile')
eval_gemfile(plugins_path) if File.exist?(plugins_path)
```

Run `bundle install` and commit the resulting `Gemfile.lock` to pin the plugin
revision and Ruby dependencies. Run your lanes with `bundle exec fastlane`.
The action is loaded automatically; no local `fastlane/actions/swiftpods.rb`
is needed.

```ruby
platform :ios do
  lane :build do
    swiftpods(
      podfile: 'src/MyApp/Podfile',
      clean_install: true,
      repo_update: true
    )
  end
end
```

The `podfile` option accepts a `Podfile` or its containing directory. Relative
paths are resolved from the lane's current working directory. You can also set
`SWIFTPODS_PODFILE`.

Use `deployment: true` to preserve the dependency lock, or `offline: true` to
use cached dependencies and the cached CLI. Run once online to populate both
caches. SwiftPods setup and installation failures fail the lane.
The action supports iOS and macOS lanes.
