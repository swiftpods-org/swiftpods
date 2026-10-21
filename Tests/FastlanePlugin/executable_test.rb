require_relative 'test_helper'
require 'digest'

class SwiftpodsExecutableTest < Minitest::Test
  def setup
    @root = File.realpath(Dir.mktmpdir('swiftpods executable '))
    @release = { 'version' => '0.1.0', 'manifest_sha256' => 'a' * 64 }
    @cache = File.join(@root, 'cache')
    @prefix = File.join(@cache, '0.1.0', 'a' * 64)
    @installer = File.join(@root, 'installer.py')
    File.write(@installer, <<~PYTHON)
      import argparse, pathlib, json, time
      p = argparse.ArgumentParser()
      for key in ('version', 'manifest-sha256', 'prefix'): p.add_argument('--' + key)
      a = p.parse_args()
      prefix = pathlib.Path(a.prefix)
      with open(#{File.join(@root, 'downloads').inspect}, 'a') as log: log.write('install\\n')
      time.sleep(0.05)
      (prefix / 'libexec/bin').mkdir(parents=True)
      executable = prefix / 'libexec/bin/swiftpods'
      executable.write_text(#{cli.inspect})
      executable.chmod(0o700)
      (prefix / 'bin').mkdir()
      (prefix / 'bin/swiftpods').symlink_to('../libexec/bin/swiftpods')
      (prefix / '.installation.json').write_text(json.dumps({'version': a.version, 'manifest_sha256': a.manifest_sha256}))
    PYTHON
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def cli(version = '0.1.0')
    "#!/usr/bin/env python3\nimport json, sys\nprint(json.dumps({'swiftpods_version': #{version.inspect}}))\n"
  end

  def setup_cli(release = @release)
    Fastlane::Swiftpods::Executable.new(release: release, cache_root: @cache, installer: @installer)
  end

  def test_first_install_is_reused_offline_without_downloading_again
    executable = setup_cli.resolve
    assert_equal File.join(@prefix, 'bin/swiftpods'), executable
    assert_equal executable, setup_cli.resolve(offline: true)
    assert_equal ["install\n"], File.readlines(File.join(@root, 'downloads'))
  end

  def test_uncached_offline_install_never_downloads
    error = assert_raises(RuntimeError) { setup_cli.resolve(offline: true) }
    assert_includes error.message, 'not cached'
    refute File.exist?(File.join(@root, 'downloads'))
  end

  def test_concurrent_processes_install_the_release_once
    children = 2.times.map do
      fork do
        setup_cli.resolve
        exit! 0
      rescue StandardError
        exit! 1
      end
    end
    children.each { |pid| assert Process.wait2(pid).last.success? }
    assert_equal ["install\n"], File.readlines(File.join(@root, 'downloads'))
  end

  def test_installer_failure_is_reported_and_does_not_create_an_installation
    File.write(@installer, "raise RuntimeError('fixture download failed')\n")
    error = assert_raises(RuntimeError) { setup_cli.resolve }
    assert_includes error.message, 'fixture download failed'
    refute File.exist?(@prefix)
  end

  def test_invalid_pin_fails_before_using_the_cache
    assert_raises(RuntimeError) { setup_cli(@release.merge('manifest_sha256' => 'latest')) }
    refute File.exist?(@cache)
  end

  def test_a_changed_receipt_is_rejected_without_redownloading
    setup_cli.resolve
    File.write(File.join(@prefix, '.installation.json'), JSON.generate(@release.merge('version' => '9.0.0')))
    error = assert_raises(RuntimeError) { setup_cli.resolve }
    assert_includes error.message, 'different release'
    assert_equal 1, File.readlines(File.join(@root, 'downloads')).length
  end

  def test_a_changed_launcher_is_rejected_before_execution
    executable = setup_cli.resolve
    File.unlink(executable)
    File.write(executable, '# changed')
    error = assert_raises(RuntimeError) { setup_cli.resolve }
    assert_includes error.message, 'launcher is missing or changed'
  end

  def test_a_changed_executable_version_is_rejected
    setup_cli.resolve
    File.write(File.join(@prefix, 'libexec/bin/swiftpods'), cli('9.0.0'))
    error = assert_raises(RuntimeError) { setup_cli.resolve }
    assert_includes error.message, 'differs from the pinned release'
  end
end
