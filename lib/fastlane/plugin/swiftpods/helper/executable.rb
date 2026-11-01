require 'json'
require 'fileutils'
require 'fiddle/import'
require 'open3'
require 'tmpdir'

if RUBY_PLATFORM.include?('darwin')
  module SwiftPodsDarwinACL
    extend Fiddle::Importer
    dlload Fiddle.dlopen(nil)
    extern 'void *acl_init(int)'
    extern 'void *acl_get_fd_np(int, int)'
    extern 'int acl_get_entry(void *, int, void *)'
    extern 'int acl_get_tag_type(void *, void *)'
    extern 'int acl_set_fd_np(int, void *, int)'
    extern 'int acl_free(void *)'

    ACL_TYPE_EXTENDED = 0x00000100
    ACL_EXTENDED_ALLOW = 0x00000001
    ACL_FIRST_ENTRY = 0
    ACL_NEXT_ENTRY = -1
    UNSUPPORTED_ERRORS = [
      Errno::ENOENT::Errno,
      (Errno::ENOTSUP::Errno if defined?(Errno::ENOTSUP)),
      (Errno::EOPNOTSUPP::Errno if defined?(Errno::EOPNOTSUPP))
    ].compact.uniq.freeze

    def self.extended?(descriptor)
      acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED)
      if acl.to_i.zero?
        return false if UNSUPPORTED_ERRORS.include?(Fiddle.last_error)

        raise 'Cannot inspect SwiftPods cache access controls'
      end
      begin
        entry = Fiddle::Pointer.malloc(Fiddle::SIZEOF_VOIDP)
        entry[0, Fiddle::SIZEOF_VOIDP] = "\0" * Fiddle::SIZEOF_VOIDP
        raise 'Cannot inspect SwiftPods cache access controls' unless acl_get_entry(acl, 0, entry).zero?

        !entry[0, Fiddle::SIZEOF_VOIDP].unpack1('J').zero?
      ensure
        acl_free(acl)
      end
    end

    def self.allows_access?(descriptor)
      acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED)
      if acl.to_i.zero?
        return false if UNSUPPORTED_ERRORS.include?(Fiddle.last_error)

        raise 'Cannot inspect SwiftPods cache ancestor access controls'
      end
      begin
        selector = ACL_FIRST_ENTRY
        loop do
          entry = Fiddle::Pointer.malloc(Fiddle::SIZEOF_VOIDP)
          entry[0, Fiddle::SIZEOF_VOIDP] = "\0" * Fiddle::SIZEOF_VOIDP
          Fiddle.last_error = 0
          result = acl_get_entry(acl, selector, entry)
          if result != 0
            break if selector == ACL_NEXT_ENTRY && Fiddle.last_error == Errno::EINVAL::Errno

            raise 'Cannot inspect SwiftPods cache ancestor access controls'
          end
          address = entry[0, Fiddle::SIZEOF_VOIDP].unpack1('J')
          break if address.zero?

          tag = Fiddle::Pointer.malloc(Fiddle::SIZEOF_INT)
          raise 'Cannot inspect SwiftPods cache ancestor access controls' unless acl_get_tag_type(address, tag).zero?
          return true if tag[0, Fiddle::SIZEOF_INT].unpack1('i') == ACL_EXTENDED_ALLOW

          selector = ACL_NEXT_ENTRY
        end
        false
      ensure
        acl_free(acl)
      end
    end

    def self.clear(descriptor)
      acl = acl_init(0)
      raise 'Cannot allocate SwiftPods cache access controls' if acl.to_i.zero?

      begin
        result = acl_set_fd_np(descriptor, acl, ACL_TYPE_EXTENDED)
        unless result.zero? || UNSUPPORTED_ERRORS.include?(Fiddle.last_error)
          raise 'Cannot remove inherited SwiftPods cache access controls'
        end
      ensure
        acl_free(acl)
      end
    end
  end
end

module Fastlane
  module Swiftpods
    # Installs the SwiftPods release pinned in release.json and asks the installer
    # to execute its authenticated runtime snapshot without exposing that path to Ruby.
    class Executable
      RELEASE_PATH = File.expand_path('../release.json', __dir__).freeze
      INSTALLER_PATH = File.expand_path('../../../../../scripts/install.py', __dir__).freeze
      PYTHON = '/usr/bin/python3'.freeze
      DEFAULT_LOCK_TIMEOUT = 120.0
      BLOCKED_ENVIRONMENT_PREFIXES = %w[GIT_ DYLD_ LD_ CURL_ BASH_FUNC_ PYTHON].freeze
      BLOCKED_ENVIRONMENT_NAMES = %w[
        BASH_ENV ENV CDPATH SSH_ASKPASS SHELLOPTS BASHOPTS BASH_XTRACEFD PS4 IFS
        TAR_OPTIONS TAR_READER_OPTIONS TAR_WRITER_OPTIONS GZIP GZIP_OPT BZIP2 BZIP2OPT
        XZ_OPT XZ_DEFAULTS LZMA_OPT ZSTD_CLEVEL ZSTD_NBTHREADS ZSTD_WINDOWLOG
        SSL_CERT_FILE SSL_CERT_DIR SSLKEYLOGFILE
      ].freeze

      def initialize(release: JSON.parse(File.read(RELEASE_PATH)), cache_root: nil, installer: INSTALLER_PATH,
                     lock_timeout: DEFAULT_LOCK_TIMEOUT)
        @installer = installer
        @version = release.fetch('version')
        @checksum = release.fetch('manifest_sha256')
        unless @version.match?(/\A\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?\z/) && @checksum.match?(/\A[0-9a-f]{64}\z/)
          raise 'Invalid pinned SwiftPods release'
        end
        cache_root ||= ENV['SWIFTPODS_TOOL_CACHE_ROOT'] || File.join(Dir.home, 'Library/Caches/SwiftPods/tools')
        @cache_root = File.expand_path(cache_root)
        @parent = nil
        @prefix = nil
        @cache_ancestors = nil
        @lock_timeout = Float(lock_timeout)
        raise 'Invalid SwiftPods cache lock timeout' unless @lock_timeout.positive? && @lock_timeout.finite?
      end

      def run(arguments, offline: false)
        unless arguments.is_a?(Array) && !arguments.empty? &&
            arguments.all? { |argument| argument.is_a?(String) && !argument.include?("\0") }
          raise ArgumentError, 'SwiftPods command arguments must be a non-empty array of strings'
        end

        prepare_cache_root
        verify_cache_ancestors
        ensure_private_directory(@parent)
        parent_identity = directory_identity(@parent)
        runtime = Dir.mktmpdir('.swiftpods-runtime-', @parent)
        File.chmod(0o700, runtime)
        clear_path_acl(runtime)
        runtime = File.realpath(runtime)
        runtime_identity = directory_identity(runtime)
        lock_path = @prefix + '.lock'
        preparation = nil
        begin
          raise 'SwiftPods cache lock must not be a symlink' if File.symlink?(lock_path)
          flags = File::RDWR | File::CREAT
          flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
          flags |= File::CLOEXEC if File.const_defined?(:CLOEXEC)
          File.open(lock_path, flags, 0o600) do |lock|
            lock_stat = lock.stat
            unless lock_stat.file? && lock_stat.uid == Process.euid && lock_stat.nlink == 1 && (lock_stat.mode & 0o077).zero?
              raise 'SwiftPods cache lock must be a private owned regular file'
            end
            clear_descriptor_acl(lock)
            raise 'SwiftPods cache lock retains an extended ACL' if descriptor_has_extended_acl(lock)
            acquire_lock(lock)
            verify_locked_path(lock_path, lock, lock_stat)
            verify_cache_ancestors
            raise 'SwiftPods cache directory changed while it was being locked' unless directory_identity(@parent) == parent_identity
            verify_path if File.exist?(@prefix) || File.symlink?(@prefix)
            preparation = prepare_pinned(offline: offline)
            verify_locked_path(lock_path, lock, lock_stat)
            verify_path if File.exist?(@prefix) || File.symlink?(@prefix)
            verify_cache_ancestors
          end
          return preparation unless preparation[2].success?

          # The installer now has an immutable, verified cache entry. Execute only through a fresh offline
          # verification and private snapshot, but do not serialize the user's potentially long build on the cache
          # installation lock.
          verify_cache_ancestors
          unless directory_identity(@parent) == parent_identity && directory_identity(runtime) == runtime_identity
            raise 'SwiftPods cache or runtime directory changed before execution'
          end
          execute_pinned(arguments: arguments, runtime: runtime)
        ensure
          remove_runtime(runtime, runtime_identity)
        end
      end

      private

      def prepare_cache_root
        return unless @cache_ancestors.nil?

        requested = @cache_root
        raise "Unsafe SwiftPods cache directory: #{requested}" if File.symlink?(requested)

        missing = []
        existing = requested
        until File.exist?(existing) || File.symlink?(existing)
          parent = File.dirname(existing)
          raise 'Cannot locate a SwiftPods cache ancestor' if parent == existing

          missing.unshift(File.basename(existing))
          existing = parent
        end
        canonical = File.realpath(existing)
        validate_trusted_ancestor_chain(canonical)
        candidate = missing.reduce(canonical) { |path, component| File.join(path, component) }
        ensure_private_directory(candidate)
        @cache_root = File.realpath(candidate)
        @cache_ancestors = validate_trusted_ancestor_chain(@cache_root)
        validate_private_directory(@cache_root)
        @parent = File.join(@cache_root, @version)
        @prefix = File.join(@parent, @checksum)
      rescue Errno::ENOENT, Errno::ELOOP => error
        raise "Cannot securely resolve the SwiftPods cache: #{error.message}"
      end

      def validate_trusted_ancestor_chain(path)
        current = File::SEPARATOR
        result = [trusted_ancestor_identity(current)]
        path.split(File::SEPARATOR).reject(&:empty?).each do |component|
          current = File.join(current, component)
          result << trusted_ancestor_identity(current)
        end
        result
      end

      def trusted_ancestor_identity(path)
        status = safe_lstat(path, "Unsafe SwiftPods cache ancestor: #{path}")
        trusted_owner = status.uid.zero? || status.uid == Process.euid
        sticky = (status.mode & 0o1000) != 0
        unless status.directory? && trusted_owner && ((status.mode & 0o022).zero? || sticky)
          raise "SwiftPods cache ancestor must be owned and not group/world-writable: #{path}"
        end
        File.open(path, safe_read_flags) do |directory|
          opened = directory.stat
          unless opened.directory? && [opened.dev, opened.ino] == [status.dev, status.ino]
            raise "SwiftPods cache ancestor changed while it was checked: #{path}"
          end
          if defined?(SwiftPodsDarwinACL) && SwiftPodsDarwinACL.allows_access?(directory.fileno)
            raise "SwiftPods cache ancestor grants access through an extended ACL: #{path}"
          end
          [path, opened.dev, opened.ino]
        end
      end

      def verify_cache_ancestors
        @cache_ancestors.each do |path, device, inode|
          current = trusted_ancestor_identity(path)
          unless current[1] == device && current[2] == inode
            raise "SwiftPods cache ancestor changed while it was in use: #{path}"
          end
        end
      end

      def executable
        File.join(@prefix, 'bin/swiftpods')
      end

      def installer_command
        [
          PYTHON, '-I', @installer, '--version', @version, '--manifest-sha256', @checksum,
          '--prefix', @prefix
        ]
      end

      def prepare_pinned(offline:)
        exists = File.exist?(@prefix) || File.symlink?(@prefix)
        puts "Installing SwiftPods #{@version}" unless exists
        command = installer_command
        command << '--offline' if offline
        execute(*command)
      end

      def execute_pinned(arguments:, runtime:)
        command = installer_command
        command.concat(['--runtime-directory', runtime, '--offline'])
        command << '--execute'
        command.concat(arguments)
        execute(*command)
      end

      def verify_path
        [@cache_root, @parent, @prefix, File.join(@prefix, 'bin')].each do |directory|
          validate_private_directory(directory)
        end
        status = safe_lstat(executable, 'SwiftPods cache executable is missing or changed')
        unless status.file? && status.uid == Process.euid && status.nlink == 1 &&
            (status.mode & 0o022).zero? && File.executable?(executable)
          raise 'SwiftPods cache executable is missing or changed'
        end
        File.open(executable, safe_read_flags) do |file|
          opened = file.stat
          unless [opened.dev, opened.ino] == [status.dev, status.ino] && !descriptor_has_extended_acl(file)
            raise 'SwiftPods cache executable has unsafe access controls'
          end
        end
      end

      def ensure_private_directory(path)
        if File.exist?(path) || File.symlink?(path)
          validate_private_directory(path)
          return
        end
        parent = File.dirname(path)
        unless File.exist?(parent) || File.symlink?(parent)
          ensure_private_directory(parent)
        end
        validate_private_directory(parent)
        Dir.mkdir(path, 0o700)
        File.chmod(0o700, path)
        clear_path_acl(path)
        validate_private_directory(path)
      rescue Errno::EEXIST
        validate_private_directory(path)
      end

      def validate_private_directory(path)
        status = safe_lstat(path, "Unsafe SwiftPods cache directory: #{path}")
        unless status.directory? && status.uid == Process.euid && (status.mode & 0o022).zero?
          raise "SwiftPods cache directory must be owned and not group/world-writable: #{path}"
        end
        File.open(path, safe_read_flags) do |directory|
          opened = directory.stat
          unless opened.directory? && [opened.dev, opened.ino] == [status.dev, status.ino]
            raise "SwiftPods cache directory changed while it was being checked: #{path}"
          end
          raise "SwiftPods cache directory has an extended ACL: #{path}" if descriptor_has_extended_acl(directory)

          opened
        end
      end

      def directory_identity(path)
        status = validate_private_directory(path)
        [status.dev, status.ino]
      end

      def safe_lstat(path, message)
        status = File.lstat(path)
        raise message if status.symlink?
        status
      rescue Errno::ENOENT
        raise message
      end

      def remove_runtime(runtime, identity)
        status = File.lstat(runtime)
        if !status.symlink? && status.directory? && [status.dev, status.ino] == identity
          FileUtils.remove_entry(runtime)
        end
      rescue Errno::ENOENT
        nil
      end

      def execute(*command)
        Open3.capture3(
          execution_environment,
          *command,
          unsetenv_others: true
        )
      rescue Errno::ENOENT => error
        raise "SwiftPods setup requires Python 3.9 or later: #{error.message}"
      end

      def execution_environment
        environment = ENV.to_h.reject do |name, _value|
          BLOCKED_ENVIRONMENT_NAMES.include?(name) ||
            BLOCKED_ENVIRONMENT_PREFIXES.any? { |prefix| name.start_with?(prefix) }
        end
        environment['PATH'] = '/usr/bin:/bin:/usr/sbin:/sbin'
        environment['LANG'] = 'C'
        environment['LC_ALL'] = 'C'
        environment['SSH_ASKPASS_REQUIRE'] = 'never'
        environment['GIT_TERMINAL_PROMPT'] = '0'
        environment
      end

      def verify_locked_path(path, lock, initial)
        opened = lock.stat
        current = safe_lstat(path, 'SwiftPods cache lock changed while it was being acquired')
        identities = [[initial.dev, initial.ino], [opened.dev, opened.ino], [current.dev, current.ino]]
        unless identities.uniq.one? && current.file? && current.uid == Process.euid && current.nlink == 1 &&
            (current.mode & 0o077).zero?
          raise 'SwiftPods cache lock changed while it was being acquired'
        end
      end

      def safe_read_flags
        flags = File::RDONLY
        flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
        flags |= File::CLOEXEC if File.const_defined?(:CLOEXEC)
        flags |= File::NONBLOCK if File.const_defined?(:NONBLOCK)
        flags
      end

      def descriptor_has_extended_acl(file)
        return false unless defined?(SwiftPodsDarwinACL)

        SwiftPodsDarwinACL.extended?(file.fileno)
      end

      def clear_descriptor_acl(file)
        SwiftPodsDarwinACL.clear(file.fileno) if defined?(SwiftPodsDarwinACL)
      end

      def clear_path_acl(path)
        File.open(path, safe_read_flags) { |file| clear_descriptor_acl(file) }
      end

      def acquire_lock(lock)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @lock_timeout
        until lock.flock(File::LOCK_EX | File::LOCK_NB)
          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          raise 'Timed out waiting for the SwiftPods cache lock' unless remaining.positive?

          sleep([remaining, 0.05].min)
        end
      end
    end
  end
end
