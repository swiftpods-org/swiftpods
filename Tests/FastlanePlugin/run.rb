#!/usr/bin/env ruby
# Runs the plugin tests against the installed fastlane and minitest gems.
$LOAD_PATH.unshift(File.expand_path('../../lib', __dir__))
Dir[File.join(__dir__, '*_test.rb')].sort.each { |file| require file }
