require 'fileutils'
require 'minitest/autorun'
require 'tmpdir'
require 'timeout'
require_relative '../../lib/fastlane/plugin/swiftpods/helper/executable'

class ExecutableTest < Minitest::Test
  VERSION = '9.8.7'
  CHECKSUM = 'a' * 64

  def setup
    @temporary = Dir.mktmpdir('swiftpods-executable')
    @calls = File.join(@temporary, 'installer-calls')
    # Stands in for scripts/install.py and, importantly, remains the verifier on cache reuse.
    @installer = File.join(@temporary, 'install.py')
    File.write(@installer, <<~PYTHON)
      import json, os, shutil, sys
      forbidden = [
          'PYTHONHOME', 'PYTHONPATH', 'DYLD_INSERT_LIBRARIES', 'LD_PRELOAD', 'GIT_CONFIG_GLOBAL',
          'CURL_HOME', 'BASH_ENV', 'ENV', 'CDPATH', 'SSH_ASKPASS', 'TAR_OPTIONS', 'SSL_CERT_FILE'
      ]
      inherited = [name for name in forbidden if os.environ.get(name)]
      if inherited:
          raise RuntimeError('dangerous environment reached installer: ' + ','.join(inherited))
      arguments = {}
      execute = []
      index = 1
      while index < len(sys.argv):
          if sys.argv[index] == '--offline':
              arguments['--offline'] = True
              index += 1
          elif sys.argv[index] == '--execute':
              execute = sys.argv[index + 1:]
              break
          else:
              arguments[sys.argv[index]] = sys.argv[index + 1]
              index += 2
      prefix = arguments['--prefix']
      receipt = {'version': arguments['--version'], 'manifest_sha256': arguments['--manifest-sha256']}
      if os.path.exists(prefix):
          with open(os.path.join(prefix, '.installation.json')) as source:
              if json.load(source) != receipt:
                  raise RuntimeError('cache belongs to a different release')
      else:
          if arguments.get('--offline'):
              raise RuntimeError('SwiftPods is not cached')
          os.makedirs(os.path.join(prefix, 'bin'))
          executable = os.path.join(prefix, 'bin', 'swiftpods')
          with open(executable, 'w') as output:
              output.write('''#!/bin/sh
      if [ "$1" = check ]; then
          printf '%s\\n' '{"packages":[{"name":"AppLovinSDK"}],"binaries":[],"targets":[]}'
      elif [ "$1" = environment ]; then
          if [ -n "${PYTHONPATH-}${DYLD_INSERT_LIBRARIES-}${GIT_CONFIG_GLOBAL-}${BASH_ENV-}" ]; then
              printf '%s\\n' 'dangerous environment reached child' >&2
              exit 29
          fi
          printf '%s\\n' "$HOME" "$DEVELOPER_DIR" "$SSH_AUTH_SOCK" "$SWIFTPODS_PROJECT_CONTEXT" \\
              "$RUBYOPT" "$RUBYLIB" "$PERL5OPT" "$PERL5LIB" "$NODE_OPTIONS"
      elif [ "$1" = wait ]; then
          : > "$2"
          while [ ! -e "$3" ]; do /bin/sleep 0.01; done
          printf '%s\\n' done
      elif [ "$1" = fail ]; then
          printf '%s\\n' 'simulated failure' >&2
          exit 23
      else
          printf '%s\\n' "$@"
      fi
      ''')
          os.chmod(executable, 0o755)
          with open(os.path.join(prefix, '.installation.json'), 'w') as output:
              json.dump(receipt, output)
      runtime = arguments.get('--runtime-directory')
      with open(#{@calls.inspect}, 'a') as output:
          output.write(json.dumps({'execute': execute, 'runtime': runtime, 'offline': bool(arguments.get('--offline'))}) + '\\n')
      if not execute:
          sys.exit(0)
      if runtime is None:
          raise RuntimeError('--runtime-directory is required for execution')
      shutil.copy2(os.path.join(prefix, 'bin', 'swiftpods'), os.path.join(runtime, 'swiftpods'))
      os.chmod(os.path.join(runtime, 'swiftpods'), 0o500)
      runtime_executable = os.path.join(runtime, 'swiftpods')
      os.execv(runtime_executable, [runtime_executable] + execute)
    PYTHON
  end

  def teardown
    FileUtils.remove_entry(@temporary)
  end

  def executable(release = { 'version' => VERSION, 'manifest_sha256' => CHECKSUM }, cache_root: nil)
    Fastlane::Swiftpods::Executable.new(
      release: release, cache_root: cache_root || File.join(@temporary, 'cache'), installer: @installer
    )
  end

  def invoke(instance = executable, arguments: ['version', '--json'], offline: false)
    output, errors, status = instance.run(arguments, offline: offline)
    raise "SwiftPods setup failed (#{status.exitstatus}):\n#{errors}" unless status.success?

    output
  end

  def add_acl(path, rule)
    return if system('/bin/chmod', '+a', rule, path, out: File::NULL, err: File::NULL)

    skip 'The test filesystem does not support Darwin ACLs'
  end

  def add_acl_at(path, index, rule)
    return if system('/bin/chmod', '+a#', index.to_s, rule, path, out: File::NULL, err: File::NULL)

    skip 'The test filesystem does not support ordered Darwin ACLs'
  end

  def test_installs_once_and_verifies_every_cache_reuse
    capture_io { invoke }
    invoke(executable, offline: true)
    calls = File.readlines(@calls).map { |line| JSON.parse(line) }
    assert_equal 4, calls.count
    assert_equal 2, calls.count { |call| call.fetch('execute').empty? }
    assert_equal 2, calls.count { |call| !call.fetch('execute').empty? }
    assert_empty Dir.glob(File.join(@temporary, 'cache', VERSION, '.swiftpods-runtime-*'))
  end

  def test_offline_needs_a_cached_release
    error = assert_raises(RuntimeError) { invoke(executable, offline: true) }
    assert_match(/not cached/, error.message)
  end

  def test_rejects_a_cache_of_another_release
    capture_io { invoke }
    receipt = File.join(@temporary, 'cache', VERSION, CHECKSUM, '.installation.json')
    File.write(receipt, JSON.generate('version' => VERSION, 'manifest_sha256' => 'b' * 64))
    error = assert_raises(RuntimeError) { invoke }
    assert_match(/different release/, error.message)
  end

  def test_installer_executes_the_requested_command_without_returning_a_path
    output = nil
    capture_io { output = invoke(executable, arguments: ['install', '--project-directory', '/tmp/with spaces']) }
    assert_equal "install\n--project-directory\n/tmp/with spaces\n", output
    call = JSON.parse(File.readlines(@calls).last)
    assert_equal ['install', '--project-directory', '/tmp/with spaces'], call.fetch('execute')
    refute File.exist?(call.fetch('runtime'))
  end

  def test_preserves_child_stderr_and_exit_status
    _, errors, status = executable.run(['fail'])
    assert_equal 23, status.exitstatus
    assert_equal "simulated failure\n", errors
  end

  def test_rejects_group_or_world_writable_cache_directories
    unsafe = File.join(@temporary, 'unsafe-cache')
    Dir.mkdir(unsafe, 0o700)
    File.chmod(0o777, unsafe)
    error = assert_raises(RuntimeError) { invoke(executable(cache_root: unsafe)) }
    assert_match(%r{not group/world-writable}, error.message)
  end

  def test_rejects_an_existing_group_writable_release_prefix_before_verification
    capture_io { invoke }
    prefix = File.join(@temporary, 'cache', VERSION, CHECKSUM)
    File.chmod(0o777, prefix)
    error = assert_raises(RuntimeError) { invoke(executable, offline: true) }
    assert_match(%r{not group/world-writable}, error.message)
  end

  def test_rejects_a_symlinked_cache_root
    target = File.join(@temporary, 'target-cache')
    Dir.mkdir(target, 0o700)
    link = File.join(@temporary, 'linked-cache')
    File.symlink(target, link)
    error = assert_raises(RuntimeError) { invoke(executable(cache_root: link)) }
    assert_match(/Unsafe SwiftPods cache directory/, error.message)
  end

  def test_canonicalizes_an_intermediate_symlink_before_using_the_cache
    physical = File.join(@temporary, 'physical')
    Dir.mkdir(physical, 0o700)
    linked = File.join(@temporary, 'linked')
    File.symlink(physical, linked)
    capture_io do
      invoke(executable(cache_root: File.join(linked, 'nested', 'cache')))
    end
    runtime = JSON.parse(File.readlines(@calls).last).fetch('runtime')
    assert runtime.start_with?(File.realpath(physical) + File::SEPARATOR), runtime
    refute_includes runtime, File::SEPARATOR + 'linked' + File::SEPARATOR
  end

  def test_rejects_a_symlinked_cache_lock
    lock = File.join(@temporary, 'cache', VERSION, CHECKSUM) + '.lock'
    FileUtils.mkdir_p(File.dirname(lock))
    File.symlink(File.join(@temporary, 'other-lock'), lock)
    error = assert_raises(RuntimeError) { invoke }
    assert_match(/lock must not be a symlink/, error.message)
  end

  def test_rejects_a_lock_path_replacement_after_flock
    instance = executable
    lock = File.join(@temporary, 'cache', VERSION, CHECKSUM) + '.lock'
    acquired = instance.method(:acquire_lock)
    instance.define_singleton_method(:acquire_lock) do |descriptor|
      acquired.call(descriptor)
      File.rename(lock, lock + '.replaced')
      File.write(lock, '')
      File.chmod(0o600, lock)
    end

    error = assert_raises(RuntimeError) { invoke(instance) }
    assert_match(/lock changed while it was being acquired/, error.message)
    refute File.exist?(@calls)
  end

  def test_rejects_an_extended_acl_on_an_existing_cache_directory
    capture_io { invoke }
    cache = File.join(@temporary, 'cache')
    add_acl(cache, 'everyone allow list,search,add_file,add_subdirectory,delete_child')
    error = assert_raises(RuntimeError) { invoke(executable, offline: true) }
    assert_match(/extended ACL/, error.message)
  ensure
    system('/bin/chmod', '-N', cache, out: File::NULL, err: File::NULL) if cache && File.exist?(cache)
  end

  def test_rejects_an_allow_acl_on_a_cache_ancestor
    ancestor = File.join(@temporary, 'acl-ancestor')
    Dir.mkdir(ancestor, 0o700)
    add_acl(ancestor, 'everyone allow list,search,add_file,add_subdirectory,delete_child')
    error = assert_raises(RuntimeError) do
      invoke(executable(cache_root: File.join(ancestor, 'cache')))
    end
    assert_match(/ancestor grants access through an extended ACL/, error.message)
  ensure
    system('/bin/chmod', '-N', ancestor, out: File::NULL, err: File::NULL) if ancestor && File.exist?(ancestor)
  end

  def test_rejects_an_allow_acl_after_a_leading_deny_entry
    ancestor = File.join(@temporary, 'ordered-acl-ancestor')
    Dir.mkdir(ancestor, 0o700)
    add_acl_at(ancestor, 0, 'everyone deny delete_child')
    add_acl_at(ancestor, 1, 'everyone allow list,search')
    error = assert_raises(RuntimeError) do
      invoke(executable(cache_root: File.join(ancestor, 'cache')))
    end
    assert_match(/ancestor grants access through an extended ACL/, error.message)
  ensure
    system('/bin/chmod', '-N', ancestor, out: File::NULL, err: File::NULL) if ancestor && File.exist?(ancestor)
  end

  def test_clears_an_extended_acl_from_the_cache_lock
    lock = File.join(@temporary, 'cache', VERSION, CHECKSUM) + '.lock'
    FileUtils.mkdir_p(File.dirname(lock))
    File.write(lock, '')
    File.chmod(0o600, lock)
    add_acl(lock, 'everyone allow read,write')

    capture_io { invoke }
    File.open(lock, File::RDONLY) do |file|
      refute SwiftPodsDarwinACL.extended?(file.fileno)
    end
  end

  def test_cache_lock_wait_is_bounded
    lock = File.join(@temporary, 'cache', VERSION, CHECKSUM) + '.lock'
    FileUtils.mkdir_p(File.dirname(lock))
    File.open(lock, File::RDWR | File::CREAT, 0o600) do |holder|
      File.chmod(0o600, lock)
      assert holder.flock(File::LOCK_EX | File::LOCK_NB)
      resolver = Fastlane::Swiftpods::Executable.new(
        release: { 'version' => VERSION, 'manifest_sha256' => CHECKSUM },
        cache_root: File.join(@temporary, 'cache'),
        installer: @installer,
        lock_timeout: 0.05
      )
      error = assert_raises(RuntimeError) { invoke(resolver) }
      assert_match(/Timed out/, error.message)
    end
  end

  def test_cache_lock_is_released_before_the_authenticated_command_runs
    started = File.join(@temporary, 'command-started')
    release = File.join(@temporary, 'release-command')
    first_result = nil
    worker = Thread.new { first_result = executable.run(['wait', started, release]) }
    Timeout.timeout(5) { sleep 0.01 until File.exist?(started) }

    contender = Fastlane::Swiftpods::Executable.new(
      release: { 'version' => VERSION, 'manifest_sha256' => CHECKSUM },
      cache_root: File.join(@temporary, 'cache'), installer: @installer, lock_timeout: 0.05
    )
    assert_includes invoke(contender, arguments: ['check']), 'AppLovinSDK'
    File.write(release, '')
    assert worker.join(5), 'The first authenticated command did not finish'
    assert first_result[2].success?, first_result[1]
    assert_equal "done\n", first_result[0]
  ensure
    File.write(release, '') if release && !File.exist?(release)
    worker&.join(5)
  end

  def test_supervisor_filters_injection_variables_and_preserves_project_context
    dangerous = {
      'PYTHONHOME' => '/tmp/attacker-python',
      'PYTHONPATH' => '/tmp/attacker-module',
      'DYLD_INSERT_LIBRARIES' => '/tmp/attacker.dylib',
      'LD_PRELOAD' => '/tmp/attacker.so',
      'GIT_CONFIG_GLOBAL' => '/tmp/attacker-gitconfig',
      'CURL_HOME' => '/tmp/attacker-curl',
      'BASH_ENV' => '/tmp/attacker-bash',
      'ENV' => '/tmp/attacker-shell',
      'CDPATH' => '/tmp',
      'SSH_ASKPASS' => '/tmp/attacker-askpass',
      'TAR_OPTIONS' => '--use-compress-program=/tmp/attacker',
      'SSL_CERT_FILE' => '/tmp/attacker-cert'
    }
    preserved = {
      'HOME' => '/tmp/swiftpods-home',
      'DEVELOPER_DIR' => '/Applications/Xcode.app/Contents/Developer',
      'SSH_AUTH_SOCK' => '/tmp/swiftpods-agent.sock',
      'SWIFTPODS_PROJECT_CONTEXT' => 'project-specific-value',
      'RUBYOPT' => '--disable-gems',
      'RUBYLIB' => '/tmp/project-ruby',
      'PERL5OPT' => '-Mproject_context',
      'PERL5LIB' => '/tmp/project-perl',
      'NODE_OPTIONS' => '--max-old-space-size=4096'
    }
    previous = dangerous.merge(preserved).to_h { |name, _value| [name, ENV[name]] }
    dangerous.each { |name, value| ENV[name] = value }
    preserved.each { |name, value| ENV[name] = value }
    output = nil
    capture_io { output = invoke(executable, arguments: ['environment']) }
    assert_equal preserved.values.join("\n") + "\n", output
    assert File.exist?(@calls)
  ensure
    previous&.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
  end

  def test_rejects_invalid_pins
    assert_raises(RuntimeError) { executable({ 'version' => 'latest', 'manifest_sha256' => CHECKSUM }) }
    assert_raises(RuntimeError) { executable({ 'version' => VERSION, 'manifest_sha256' => 'abc' }) }
  end

  def test_rejects_invalid_command_arguments
    assert_raises(ArgumentError) { executable.run([]) }
    assert_raises(ArgumentError) { executable.run(['check', "bad\0argument"]) }
  end

  def test_the_bundled_pin_is_valid
    release = JSON.parse(File.read(Fastlane::Swiftpods::Executable::RELEASE_PATH))
    assert_match(/\A\d+\.\d+\.\d+\z/, release['version'])
    assert_match(/\A[0-9a-f]{64}\z/, release['manifest_sha256'])
  end
end
