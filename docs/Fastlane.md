# Fastlane

The `fastlane-plugin-swiftpods` plugin provides the `swiftpods(...)` action.
Install the [SwiftPods executable](Release.md) on your machine or CI runner first.
The plugin uses `swiftpods` from `PATH`, or the executable selected by
`SWIFTPODS_EXECUTABLE`.

Add the plugin to `fastlane/Pluginfile`, selecting a published SwiftPods release
tag in place of `RELEASE_TAG`:

```ruby
gem 'fastlane-plugin-swiftpods',
    git: 'https://github.com/swiftpods-org/swiftpods.git',
    tag: 'RELEASE_TAG'
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
use cached dependencies. SwiftPods installation failures fail the lane.
The action supports iOS and macOS lanes.
