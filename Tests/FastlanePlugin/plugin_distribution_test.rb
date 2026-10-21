require_relative 'test_helper'
require 'open3'
require 'rbconfig'
require 'rubygems/package'

class SwiftpodsPluginDistributionTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  NAME = 'fastlane-plugin-swiftpods'.freeze

  def setup
    @temporary = File.realpath(Dir.mktmpdir('swiftpods plugin '))
    @profile = JSON.parse(File.read(File.join(ROOT, 'Profiles/baseline.json')))
    @version = @profile.fetch('swiftpods_version')
  end

  def teardown
    FileUtils.remove_entry(@temporary)
  end

  def command(*arguments, directory: @temporary, environment: {})
    output, status = Bundler.with_unbundled_env do
      Open3.capture2e(environment, *arguments, chdir: directory)
    end
    assert status.success?, "#{arguments.first} failed (#{status.exitstatus}):\n#{output}"
    output
  end

  def test_gem_contains_the_action_without_the_native_engine_or_build_inputs
    specification = Gem.loaded_specs.fetch(NAME)
    archive = ENV.fetch('SWIFTPODS_PLUGIN_GEM', File.join(ROOT, 'dist/fastlane-plugin-swiftpods.gem'))
    contents = Gem::Package.new(archive).contents
    assert_equal Gem::Version.new(@version), specification.version
    assert_equal specification.version.to_s, Fastlane::Swiftpods::VERSION
    assert_equal ['fastlane'], specification.runtime_dependencies.map(&:name)
    assert_equal ['lib'], specification.require_paths
    assert_includes contents, 'lib/fastlane/plugin/swiftpods.rb'
    assert_includes contents, 'lib/fastlane/plugin/swiftpods/actions/swiftpods_action.rb'
    assert_includes contents, 'lib/fastlane/plugin/swiftpods/release.json'
    assert_includes contents, 'scripts/install.py'
    assert_equal File.join(specification.full_gem_path, 'scripts/install.py'), Fastlane::Swiftpods::Executable::INSTALLER_PATH
    assert contents.none? { |path| path.start_with?('Sources/', 'Runtime/', 'Profiles/', 'Tests/') }
    unpacked = File.join(@temporary, 'unpacked')
    Gem::Package.new(archive).extract_files(unpacked)
    contents.each do |path|
      assert_equal File.binread(File.join(ROOT, path)), File.binread(File.join(unpacked, path)), path
    end
  end

  def test_the_gemspec_reads_the_shared_release_version_independently_of_working_directory
    FileUtils.mkdir_p(File.join(@temporary, 'Profiles'))
    FileUtils.cp(File.join(ROOT, NAME + '.gemspec'), @temporary)
    File.write(File.join(@temporary, 'Profiles/baseline.json'), JSON.generate('swiftpods_version' => '42.17.9'))
    specification = Gem::Specification.load(File.join(@temporary, NAME + '.gemspec'))
    assert_equal Gem::Version.new('42.17.9'), specification.version
  end

  def test_bundler_loads_the_installed_gem_and_executes_the_action_automatically
    verify_bundler("gem #{NAME.inspect}, #{@version.inspect}\n")
  end

  def test_bundler_loads_the_plugin_from_a_git_release_tag
    repository = File.join(@temporary, 'plugin-repository')
    FileUtils.mkdir_p(repository)
    ['lib', 'Profiles', 'scripts/install.py', 'LICENSE', 'docs/Fastlane.md', NAME + '.gemspec'].each do |path|
      target = File.join(repository, path)
      FileUtils.mkdir_p(File.dirname(target))
      FileUtils.cp_r(File.join(ROOT, path), target)
    end
    command('git', 'init', '--quiet', repository)
    command('git', 'add', '--', 'lib', 'Profiles', 'scripts', 'LICENSE', 'docs', NAME + '.gemspec', directory: repository)
    command('git', '-c', 'user.name=SwiftPods Fixture', '-c', 'user.email=fixture@example.invalid',
            '-c', 'commit.gpgsign=false', '-c', 'core.hooksPath=/dev/null',
            'commit', '--quiet', '-m', 'Package plugin fixture', directory: repository)
    command('git', '-c', 'tag.gpgsign=false', 'tag', 'v' + @version, directory: repository)
    verify_bundler("gem #{NAME.inspect}, git: #{repository.inspect}, tag: #{('v' + @version).inspect}\n")
  end

  def test_the_runner_rejects_a_successful_process_that_executes_zero_tests
    repository = File.join(@temporary, 'empty-suite')
    ['scripts', 'dist', 'Tests/FastlanePlugin'].each do |path|
      FileUtils.mkdir_p(File.join(repository, path))
    end
    FileUtils.cp(File.join(ROOT, 'scripts/fastlane_plugin_tests.rb'), File.join(repository, 'scripts'))
    archive = ENV.fetch('SWIFTPODS_PLUGIN_GEM', File.join(ROOT, 'dist/fastlane-plugin-swiftpods.gem'))
    FileUtils.cp(archive, File.join(repository, 'dist/fastlane-plugin-swiftpods.gem'))
    File.write(File.join(repository, 'Tests/FastlanePlugin/empty_test.rb'), "require 'minitest/autorun'\n")
    output, status = Bundler.with_unbundled_env do
      Open3.capture2e(RbConfig.ruby, File.join(repository, 'scripts/fastlane_plugin_tests.rb'))
    end
    refute status.success?, output
    assert_includes output, '0 runs, 0 assertions'
    assert_includes output, 'nonempty suite'
  end

  private

  def verify_bundler(declaration)
    project = File.join(@temporary, 'consumer')
    FileUtils.mkdir_p(File.join(project, 'fastlane'))
    File.write(File.join(project, 'fastlane/Pluginfile'), declaration)
    File.write(File.join(project, 'Gemfile'), <<~RUBY)
      source 'https://rubygems.org'
      gem 'fastlane'
      eval_gemfile File.join(__dir__, 'fastlane/Pluginfile')
    RUBY
    File.write(File.join(project, 'Podfile'), "platform :ios, '15.4'\n")
    executable = File.join(project, 'swiftpods fixture')
    capture = File.join(project, 'invocation.json')
    File.write(executable, <<~RUBY)
      #!#{RbConfig.ruby}
      require 'json'
      File.write(ENV.fetch('SWIFTPODS_PLUGIN_CAPTURE'), JSON.generate('cwd' => Dir.pwd, 'arguments' => ARGV))
    RUBY
    File.chmod(0o700, executable)
    File.write(File.join(project, 'fastlane/Fastfile'), <<~RUBY)
      platform :ios do
        lane :verify_plugin do
          swiftpods(podfile: 'Podfile', clean_install: true, deployment: true)
        end
      end
    RUBY
    environment = {
      'BUNDLE_GEMFILE' => File.join(project, 'Gemfile'),
      'BUNDLE_APP_CONFIG' => File.join(project, '.bundle'),
      'SWIFTPODS_EXECUTABLE' => executable,
      'SWIFTPODS_PLUGIN_CAPTURE' => capture
    }
    command(RbConfig.ruby, '-S', 'bundle', 'install', '--local', directory: project, environment: environment)
    output = command(RbConfig.ruby, '-S', 'bundle', 'exec', RbConfig.ruby, Gem.bin_path('fastlane', 'fastlane'), 'ios', 'verify_plugin',
                     directory: project, environment: environment)
    refute_includes output, 'Error loading plugin'
    refute_includes output, 'No actions found'
    assert_equal({ 'cwd' => project, 'arguments' => ['install', '--clean-install', '--deployment'] },
                 JSON.parse(File.read(capture)))
    refute File.exist?(File.join(project, 'fastlane/actions/swiftpods.rb'))
    assert File.file?(File.join(project, 'Gemfile.lock'))
  end
end
