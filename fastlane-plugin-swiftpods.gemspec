require 'json'

profile = JSON.parse(File.read(File.join(__dir__, 'Profiles/baseline.json')))

Gem::Specification.new do |spec|
  spec.name = 'fastlane-plugin-swiftpods'
  spec.version = profile.fetch('swiftpods_version')
  spec.authors = ['SwiftPods']
  spec.summary = 'Install Apple project dependencies with SwiftPods from Fastlane'
  spec.description = 'Provides the swiftpods action and installs a pinned SwiftPods release when needed.'
  spec.homepage = 'https://swiftpods.org'
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 3.0'
  spec.files = Dir.glob('lib/**/*.{rb,json}', base: __dir__) + ['scripts/install.py', 'LICENSE', 'docs/Fastlane.md']
  spec.require_paths = ['lib']
  spec.metadata = {
    'source_code_uri' => 'https://github.com/swiftpods-org/swiftpods',
    'bug_tracker_uri' => 'https://github.com/swiftpods-org/swiftpods/issues',
    'documentation_uri' => 'https://github.com/swiftpods-org/swiftpods/blob/main/docs/Fastlane.md',
    'allowed_push_host' => 'https://rubygems.org'
  }

  spec.add_development_dependency 'minitest', '~> 5.25'
end
