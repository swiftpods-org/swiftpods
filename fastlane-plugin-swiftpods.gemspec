version = File.read(File.join(__dir__, 'Sources/swiftpods/main.swift'))[/^let version = "([^"]+)"/, 1]

Gem::Specification.new do |spec|
  spec.name = 'fastlane-plugin-swiftpods'
  spec.version = version
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
    'documentation_uri' => 'https://github.com/swiftpods-org/swiftpods/blob/main/docs/Fastlane.md'
  }
end
