require_relative 'test_helper'

class SwiftpodsActionTest < Minitest::Test
  def setup
    @temporary = File.realpath(Dir.mktmpdir('swiftpods action '))
    @project = File.join(@temporary, "project 'with spaces")
    FileUtils.mkdir_p(@project)
    @podfile = File.join(@project, 'Podfile')
    File.write(@podfile, "target 'App' do\nend\n")
    @capture = File.join(@temporary, 'arguments.json')
    @executable = File.join(@temporary, "swiftpods ' $(touch injected)")
    File.write(@executable, "#!/usr/bin/env ruby\nrequire 'json'\nFile.write(#{@capture.inspect}, JSON.generate(ARGV))\n")
    File.chmod(0o700, @executable)
  end

  def teardown
    FileUtils.remove_entry(@temporary)
  end

  def run_action(options = {})
    configuration = FastlaneCore::Configuration.create(
      Fastlane::Actions::SwiftpodsAction.available_options, { podfile: @podfile, executable: @executable }.merge(options)
    )
    Fastlane::Actions::SwiftpodsAction.run(configuration)
    JSON.parse(File.read(@capture))
  end

  def test_runs_install_for_the_podfile_directory
    assert_equal ['install', '--project-directory', @project], run_action
    refute File.exist?(File.join(@temporary, 'injected'))
  end

  def test_forwards_options_as_flags
    arguments = run_action(podfile: @project, deployment: true, resolve: true, adopt: true, offline: true, update_sources: true)
    assert_equal ['install', '--project-directory', @project, '--deployment', '--resolve', '--adopt', '--offline', '--update-sources'],
                 arguments
  end

  def test_rejects_a_missing_podfile
    error = assert_raises(FastlaneCore::Interface::FastlaneError) { run_action(podfile: File.join(@temporary, 'missing')) }
    assert_match(/Podfile not found/, error.message)
  end
end
