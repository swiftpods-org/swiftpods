#!/usr/bin/env ruby
require 'open3'
require 'rbconfig'
require 'rubygems/package'
require 'tmpdir'

root = File.expand_path('..', __dir__)
archive = File.join(root, 'dist/fastlane-plugin-swiftpods.gem')
specification = Gem::Package.new(archive).spec

Dir.mktmpdir('swiftpods-plugin-tests-') do |temporary|
  gemfile = File.join(temporary, 'Gemfile')
  declarations = ["source 'https://rubygems.org'", "gem #{specification.name.inspect}, #{specification.version.to_s.inspect}"]
  specification.development_dependencies.each do |dependency|
    requirements = dependency.requirement.as_list.map(&:inspect).join(', ')
    declarations << "gem #{dependency.name.inspect}, #{requirements}"
  end
  File.write(gemfile, declarations.join("\n") + "\n")
  environment = { 'BUNDLE_GEMFILE' => gemfile, 'BUNDLE_APP_CONFIG' => File.join(temporary, '.bundle') }
  installed = system(environment, RbConfig.ruby, '-S', 'bundle', 'install', '--local', chdir: root)
  abort 'Plugin test dependencies could not be resolved' unless installed

  loader = 'Dir["Tests/FastlanePlugin/*_test.rb"].sort.each { |file| require_relative file }'
  output, status = Open3.capture2e(
    environment, RbConfig.ruby, '-S', 'bundle', 'exec', RbConfig.ruby, '-e', loader, chdir: root
  )
  puts output
  summaries = output.scan(/(\d+) runs, (\d+) assertions, (\d+) failures, (\d+) errors, (\d+) skips/)
  abort 'Plugin tests failed or did not execute exactly one nonempty suite' unless
    status.success? && summaries.length == 1 && summaries.first[0].to_i.positive? &&
    summaries.first.drop(2).all? { |count| count.to_i.zero? }
end
