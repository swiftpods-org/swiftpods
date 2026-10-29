require_relative 'test_helper'

class ExecutableTest < Minitest::Test
  VERSION = '9.8.7'
  CHECKSUM = 'a' * 64

  def setup
    @temporary = Dir.mktmpdir('swiftpods-executable')
    @calls = File.join(@temporary, 'installer-calls')
    # Stands in for scripts/install.py: lays out a release the way the installer does.
    @installer = File.join(@temporary, 'install.py')
    File.write(@installer, <<~PYTHON)
      import json, os, sys
      arguments = dict(zip(sys.argv[1::2], sys.argv[2::2]))
      prefix = arguments['--prefix']
      os.makedirs(os.path.join(prefix, 'bin'))
      executable = os.path.join(prefix, 'bin', 'swiftpods')
      with open(executable, 'w') as output:
          output.write('#!/bin/sh\\necho \\'{"version": "%s"}\\'\\n' % arguments['--version'])
      os.chmod(executable, 0o755)
      with open(os.path.join(prefix, '.installation.json'), 'w') as output:
          json.dump({'version': arguments['--version'], 'manifest_sha256': arguments['--manifest-sha256']}, output)
      with open(#{@calls.inspect}, 'a') as output:
          output.write('installed\\n')
    PYTHON
  end

  def teardown
    FileUtils.remove_entry(@temporary)
  end

  def executable(release = { 'version' => VERSION, 'manifest_sha256' => CHECKSUM })
    Fastlane::Swiftpods::Executable.new(release: release, cache_root: File.join(@temporary, 'cache'), installer: @installer)
  end

  def test_installs_once_and_reuses_the_cache
    path = nil
    _, _ = capture_io { path = executable.resolve }
    assert_equal File.join(@temporary, 'cache', VERSION, CHECKSUM, 'bin/swiftpods'), path
    assert_equal path, executable.resolve(offline: true)
    assert_equal 1, File.readlines(@calls).count
  end

  def test_offline_needs_a_cached_release
    error = assert_raises(RuntimeError) { executable.resolve(offline: true) }
    assert_match(/not cached/, error.message)
  end

  def test_rejects_a_cache_of_another_release
    capture_io { executable.resolve }
    receipt = File.join(@temporary, 'cache', VERSION, CHECKSUM, '.installation.json')
    File.write(receipt, JSON.generate('version' => VERSION, 'manifest_sha256' => 'b' * 64))
    error = assert_raises(RuntimeError) { executable.resolve }
    assert_match(/different release/, error.message)
  end

  def test_rejects_invalid_pins
    assert_raises(RuntimeError) { executable('version' => 'latest', 'manifest_sha256' => CHECKSUM) }
    assert_raises(RuntimeError) { executable('version' => VERSION, 'manifest_sha256' => 'abc') }
  end

  def test_the_bundled_pin_is_valid
    release = JSON.parse(File.read(Fastlane::Swiftpods::Executable::RELEASE_PATH))
    assert_match(/\A\d+\.\d+\.\d+\z/, release['version'])
    assert_match(/\A[0-9a-f]{64}\z/, release['manifest_sha256'])
  end
end
