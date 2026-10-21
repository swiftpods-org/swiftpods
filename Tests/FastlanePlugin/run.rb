#!/usr/bin/env ruby
require 'open3'
require 'rbconfig'
require 'rubygems/package'
require 'tmpdir'

root = File.expand_path('../..', __dir__)

Dir.mktmpdir('swiftpods-plugin-tests-') do |temporary|
  archive = ENV['SWIFTPODS_PLUGIN_GEM']
  unless archive
    archive = File.join(temporary, 'fastlane-plugin-swiftpods.gem')
    built = system(RbConfig.ruby, '-S', 'gem', 'build', 'fastlane-plugin-swiftpods.gemspec',
                   '--strict', '--output', archive, chdir: root)
    abort 'Plugin package could not be built' unless built
  end
  archive = File.expand_path(archive)
  specification = Gem::Package.new(archive).spec
  gemfile = File.join(temporary, 'Gemfile')
  declarations = ["source 'https://rubygems.org'", "gem #{specification.name.inspect}, #{specification.version.to_s.inspect}"]
  fastlane_version = ENV['SWIFTPODS_TEST_FASTLANE_VERSION']
  declarations << (fastlane_version ? "gem 'fastlane', #{fastlane_version.inspect}" : "gem 'fastlane'")
  specification.development_dependencies.each do |dependency|
    requirements = dependency.requirement.as_list.map(&:inspect).join(', ')
    declarations << "gem #{dependency.name.inspect}, #{requirements}"
  end
  File.write(gemfile, declarations.join("\n") + "\n")
  gem_home = File.join(temporary, 'gems')
  environment = {
    'GEM_HOME' => gem_home,
    'GEM_PATH' => ([gem_home] + Gem.path).join(File::PATH_SEPARATOR),
    'BUNDLE_GEMFILE' => gemfile,
    'BUNDLE_APP_CONFIG' => File.join(temporary, '.bundle'),
    'SWIFTPODS_PLUGIN_GEM' => archive
  }
  installed = system(environment, RbConfig.ruby, '-S', 'gem', 'install', archive,
                     '--local', '--ignore-dependencies', '--no-document', chdir: root)
  abort 'Plugin package could not be installed' unless installed
  installed = system(environment, RbConfig.ruby, '-S', 'bundle', 'install', '--local', chdir: root)
  abort 'Plugin test dependencies could not be resolved' unless installed

  loader = 'Dir["Tests/FastlanePlugin/*_test.rb"].sort.each { |file| require File.expand_path(file) }'
  output, status = Open3.capture2e(
    environment, RbConfig.ruby, '-S', 'bundle', 'exec', RbConfig.ruby, '-e', loader, chdir: root
  )
  puts output
  summaries = output.scan(/(\d+) runs, (\d+) assertions, (\d+) failures, (\d+) errors, (\d+) skips/)
  abort 'Plugin tests failed or did not execute exactly one nonempty suite' unless
    status.success? && summaries.length == 1 && summaries.first[0].to_i.positive? &&
    summaries.first.drop(2).all? { |count| count.to_i.zero? }
end
