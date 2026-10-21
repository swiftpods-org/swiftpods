require 'json'
require 'fileutils'
require 'open3'

module Fastlane
  module Swiftpods
    class Executable
      RELEASE_PATH = File.expand_path('../release.json', __dir__).freeze
      INSTALLER_PATH = File.expand_path('../../../../../scripts/install.py', __dir__).freeze

      def initialize(release: JSON.parse(File.read(RELEASE_PATH)), cache_root: nil, installer: INSTALLER_PATH)
        @installer = installer
        @version = release.fetch('version')
        @checksum = release.fetch('manifest_sha256')
        unless @version.match?(/\A\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?\z/) && @checksum.match?(/\A[0-9a-f]{64}\z/)
          raise 'Invalid pinned SwiftPods release'
        end
        cache_root ||= ENV['SWIFTPODS_TOOL_CACHE_ROOT'] || File.join(Dir.home, 'Library/Caches/SwiftPods/tools')
        @parent = File.expand_path(File.join(cache_root, @version))
        @prefix = File.join(@parent, @checksum)
      end

      def resolve(offline: false)
        FileUtils.mkdir_p(@parent, mode: 0o700)
        File.open(@prefix + '.lock', File::RDWR | File::CREAT, 0o600) do |lock|
          lock.flock(File::LOCK_EX)
          if File.exist?(@prefix) || File.symlink?(@prefix)
            verify
          else
            raise 'SwiftPods is not cached. Run once without offline: true to install the pinned CLI.' if offline
            install
          end
        end
        File.join(@prefix, 'bin/swiftpods')
      end

      private

      def install
        puts "Installing SwiftPods #{@version}"
        execute(
          'python3', @installer, '--version', @version,
          '--manifest-sha256', @checksum, '--prefix', @prefix
        )
        verify
      end

      def verify
        raise 'SwiftPods cache prefix must not be a symlink' if File.symlink?(@prefix)
        receipt = JSON.parse(File.read(File.join(@prefix, '.installation.json')))
        unless receipt['version'] == @version && receipt['manifest_sha256'] == @checksum
          raise 'SwiftPods cache belongs to a different release'
        end
        executable = File.join(@prefix, 'bin/swiftpods')
        expected = File.join(@prefix, 'libexec/bin/swiftpods')
        unless File.symlink?(executable) && File.readlink(executable) == '../libexec/bin/swiftpods' &&
               File.realpath(executable) == File.realpath(expected) && File.executable?(expected)
          raise 'SwiftPods cache launcher is missing or changed'
        end
        environment = { 'SWIFTPODS_BUNDLE' => File.join(@prefix, 'libexec') }
        execute(environment, executable, 'runtime', 'verify', '--json')
        actual = JSON.parse(execute(environment, executable, 'version', '--json'))
        raise 'Cached SwiftPods version differs from the pinned release' unless actual['swiftpods_version'] == @version
      end

      def execute(*command)
        output, status = Open3.capture2e(*command)
        raise "SwiftPods setup failed (#{status.exitstatus}):\n#{output}" unless status.success?
        output
      rescue Errno::ENOENT => error
        raise "SwiftPods setup requires Python 3.9+ and a compatible Ruby: #{error.message}"
      end
    end
  end
end
