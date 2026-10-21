require_relative 'test_helper'

class SwiftpodsActionTest < Minitest::Test
  def setup
    @environment = %w[
      SWIFTPODS_EXECUTABLE SWIFTPODS_PODFILE
      SWIFTPODS_ACTION_CAPTURE SWIFTPODS_ACTION_EXIT
    ].to_h { |key| [key, ENV[key]] }
    @environment.each_key { |key| ENV.delete(key) }
    @original_directory = Dir.pwd
    @temporary = File.realpath(Dir.mktmpdir('swiftpods action '))
    @project = File.join(@temporary, "project 'with spaces")
    FileUtils.mkdir_p(@project)
    @podfile = File.join(@project, 'Podfile')
    File.write(@podfile, "platform :ios, '15.4'\n")
    @capture = File.join(@temporary, 'invocation.json')
    ENV['SWIFTPODS_ACTION_CAPTURE'] = @capture
    @executable = File.join(@temporary, "swiftpods ' $(touch injected)")
    File.write(@executable, <<~PYTHON)
      #!/usr/bin/env python3
      import json, os, sys
      with open(os.environ['SWIFTPODS_ACTION_CAPTURE'], 'w') as output:
          json.dump({'cwd': os.getcwd(), 'arguments': sys.argv[1:]}, output)
      sys.exit(int(os.environ.get('SWIFTPODS_ACTION_EXIT', '0')))
    PYTHON
    File.chmod(0o700, @executable)
  end

  def teardown
    Dir.chdir(@original_directory)
    @environment.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
    FileUtils.remove_entry(@temporary)
  end

  def run_action(options = {})
    configuration = FastlaneCore::Configuration.create(
      Fastlane::Actions::SwiftpodsAction.available_options,
      { podfile: @podfile, executable: @executable }.merge(options)
    )
    Fastlane::Actions::SwiftpodsAction.run(configuration)
  end

  def invocation
    JSON.parse(File.read(@capture))
  end

  def test_forwards_install_options_and_handles_shell_characters_safely
    run_action(clean_install: true, repo_update: true)

    assert_equal @project, invocation['cwd']
    assert_equal ['install', '--clean-install', '--repo-update'], invocation['arguments']
    assert_equal @original_directory, Dir.pwd
    refute File.exist?(File.join(@project, 'injected'))
    refute File.exist?(File.join(@temporary, 'injected'))
  end

  def test_accepts_a_directory_and_offline_deployment
    run_action(podfile: @project, deployment: true, offline: true)

    assert_equal @project, invocation['cwd']
    assert_equal ['install', '--deployment', '--offline'], invocation['arguments']
  end

  def test_uses_environment_options_and_defaults_without_extra_flags
    ENV['SWIFTPODS_EXECUTABLE'] = @executable
    ENV['SWIFTPODS_PODFILE'] = @podfile
    configuration = FastlaneCore::Configuration.create(
      Fastlane::Actions::SwiftpodsAction.available_options, {}
    )
    Fastlane::Actions::SwiftpodsAction.run(configuration)

    assert_equal ['install'], invocation['arguments']
    assert_equal @project, invocation['cwd']
  end

  def test_explicit_executable_overrides_the_environment
    ENV['SWIFTPODS_EXECUTABLE'] = '/missing/swiftpods'
    run_action

    assert_equal ['install'], invocation['arguments']
  end

  def test_default_action_installs_the_pinned_executable_before_entering_the_project
    setup = Minitest::Mock.new
    setup.expect(:resolve, @executable, offline: false)
    Fastlane::Swiftpods::Executable.stub(:new, setup) do
      run_action(executable: nil)
    end
    setup.verify
    assert_equal @project, invocation['cwd']
  end

  def test_offline_action_passes_offline_to_cli_setup
    setup = Minitest::Mock.new
    setup.expect(:resolve, @executable, offline: true)
    Fastlane::Swiftpods::Executable.stub(:new, setup) do
      run_action(executable: nil, offline: true)
    end
    setup.verify
    assert_equal ['install', '--offline'], invocation['arguments']
  end

  def test_defaults_to_the_podfile_in_the_current_directory
    configuration = FastlaneCore::Configuration.create(
      Fastlane::Actions::SwiftpodsAction.available_options,
      executable: @executable
    )
    Dir.chdir(@project) do
      Fastlane::Actions::SwiftpodsAction.run(configuration)
      assert_equal @project, Dir.pwd
    end

    assert_equal @project, invocation['cwd']
    assert_equal ['install'], invocation['arguments']
  end

  def test_resolves_relative_paths_before_changing_directory
    Dir.chdir(@temporary) do
      run_action(
        podfile: File.join(File.basename(@project), 'Podfile'),
        executable: File.join('.', File.basename(@executable))
      )
      assert_equal @temporary, Dir.pwd
    end

    assert_equal @project, invocation['cwd']
    assert_equal ['install'], invocation['arguments']
  end

  def test_propagates_cli_failure_and_restores_the_working_directory
    ENV['SWIFTPODS_ACTION_EXIT'] = '37'
    error = assert_raises(FastlaneCore::Interface::FastlaneShellError) { run_action }

    assert_includes error.message, '37'
    assert_equal @original_directory, Dir.pwd
    assert File.exist?(@capture)
  end

  def test_missing_podfile_fails_before_running_the_cli
    File.delete(@podfile)
    error = assert_raises(FastlaneCore::Interface::FastlaneError) { run_action }

    assert_includes error.message, 'Podfile not found'
    refute File.exist?(@capture)
    assert_equal @original_directory, Dir.pwd
  end

  def test_custom_filename_is_rejected_instead_of_installing_a_different_podfile
    custom = File.join(@project, 'OtherPodfile')
    File.write(custom, '')
    error = assert_raises(FastlaneCore::Interface::FastlaneError) do
      run_action(podfile: custom)
    end

    assert_includes error.message, 'requires a file named Podfile'
    refute File.exist?(@capture)
  end

  def test_plugin_action_runs_from_an_ios_lane_without_local_actions
    Dir.chdir(@temporary) do
      fastfile = Fastlane::FastFile.new.parse(<<~RUBY)
        platform :ios do
          lane :verify_swiftpods do
            swiftpods(
              podfile: #{@podfile.inspect},
              executable: #{@executable.inspect},
              clean_install: true,
              repo_update: true
            )
          end
        end
      RUBY
      fastfile.runner.execute(:verify_swiftpods, :ios)
    end

    assert_equal @project, invocation['cwd']
    assert_equal ['install', '--clean-install', '--repo-update'], invocation['arguments']
  end
end
