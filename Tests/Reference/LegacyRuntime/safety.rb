# frozen_string_literal: true

require 'digest'
require 'json'
require 'find'
require 'open3'
require 'tempfile'
require 'cocoapods-downloader/remote_file'
require 'cocoapods-downloader/git'

module SwiftPods
  class Failure < StandardError
    attr_reader :code, :stage, :file, :state
    def initialize(code, stage, message, file: nil, state: nil)
      @code, @stage, @file, @state = code, stage, file, state
      super(message)
    end
  end

  def self.atomic_json(path, object)
    FileUtils.mkdir_p(File.dirname(path))
    Tempfile.create(['.swiftpods-', '.json'], File.dirname(path)) do |file|
      file.write(JSON.pretty_generate(object) + "\n")
      file.flush
      file.fsync
      File.rename(file.path, path)
    end
  end

  def self.tree_digest(path)
    path = File.expand_path(path)
    return 'absent' unless File.exist?(path) || File.symlink?(path)
    records = []
    Find.find(path) do |entry|
      relative = entry.delete_prefix(path).delete_prefix('/')
      stat = File.lstat(entry)
      if stat.symlink?
        records << [relative, 'symlink', File.readlink(entry)]
        Find.prune
      elsif stat.directory?
        records << [relative, 'directory', stat.mode & 0o777]
      elsif stat.file?
        records << [relative, 'file', stat.mode & 0o777, Digest::SHA256.file(entry).hexdigest]
      else
        raise Failure.new('SP-CACHE-TYPE', 'cache', "Unsupported filesystem object: #{entry}", file: entry)
      end
    end
    Digest::SHA256.hexdigest(JSON.generate(records.sort))
  end

  def self.local_source?(url)
    value = url.to_s
    value.start_with?('file://', '/', './', '../') || File.exist?(value)
  end

  def self.origin_identity(value)
    uri = URI.parse(value.to_s)
    uri.userinfo = nil if uri.respond_to?(:userinfo=)
    if uri.query
      fields = URI.decode_www_form(uri.query).reject { |key, _| key.match?(/token|password|key|signature|auth|credential/i) }
      uri.query = fields.empty? ? nil : URI.encode_www_form(fields)
    end
    uri.to_s
  rescue URI::InvalidURIError
    value.to_s.sub(/\A[^@]+@/, '')
  end

  # Every project model retains the bytes it read. Check immediately before
  # the upstream atomic writer publishes it; refresh after our own writes.
  # Non-cooperating generators must still be sequenced by the build system.
  module ProjectWriteGuard
    def initialize(*args, **kwargs)
      super
      @swiftpods_disk_digest = SwiftPods.tree_digest((path + 'project.pbxproj').to_s)
    end

    def initialize_from_file
      file = (path + 'project.pbxproj').to_s
      before = SwiftPods.tree_digest(file)
      result = super
      after = SwiftPods.tree_digest(file)
      raise Failure.new('SP-PROJECT-CONFLICT', 'integration', 'Project changed while it was being read', file: file, state: 'recovery_required') unless before == after
      @swiftpods_disk_digest = after
      result
    end

    def save(save_path = nil)
      file = File.join((save_path || path).to_s, 'project.pbxproj')
      expected = @swiftpods_disk_digest || 'absent'
      if File.expand_path((save_path || path).to_s) == File.expand_path(path.to_s) && SwiftPods.tree_digest(file) != expected
        SwiftPods.emit('external_conflict', 'path' => File.expand_path(file))
        raise Failure.new('SP-PROJECT-CONFLICT', 'integration', 'Project changed outside its live Xcodeproj model; regenerate and install sequentially. The external edit was preserved.', file: file, state: 'recovery_required')
      end
      result = super
      @swiftpods_disk_digest = SwiftPods.tree_digest(file) if File.expand_path((save_path || path).to_s) == File.expand_path(path.to_s)
      SwiftPods.emit('managed_write', 'path' => File.expand_path(file))
      result
    end
  end
  Xcodeproj::Project.prepend(ProjectWriteGuard)

  module WorkspaceReadGuard
    def new_from_xcworkspace(path)
      file = File.join(path, 'contents.xcworkspacedata')
      before = SwiftPods.tree_digest(file)
      instance = super
      raise Failure.new('SP-PROJECT-CONFLICT', 'integration', 'Workspace changed while being read', file: file) unless before == SwiftPods.tree_digest(file)
      instance.instance_variable_set(:@swiftpods_workspace_path, File.expand_path(path))
      instance.instance_variable_set(:@swiftpods_workspace_digest, before)
      instance
    end
  end
  module WorkspaceWriteGuard
    def save_as(path)
      if @swiftpods_workspace_path == File.expand_path(path)
        file = File.join(path, 'contents.xcworkspacedata')
        unless SwiftPods.tree_digest(file) == @swiftpods_workspace_digest
          SwiftPods.emit('external_conflict', 'path' => File.expand_path(file))
          raise Failure.new('SP-PROJECT-CONFLICT', 'integration', 'Workspace changed outside SwiftPods; external edit preserved', file: file, state: 'recovery_required')
        end
      end
      result = super
      @swiftpods_workspace_path = File.expand_path(path)
      @swiftpods_workspace_digest = SwiftPods.tree_digest(File.join(path, 'contents.xcworkspacedata'))
      SwiftPods.emit('managed_write', 'path' => File.expand_path(File.join(path, 'contents.xcworkspacedata')))
      result
    end
  end
  Xcodeproj::Workspace.singleton_class.prepend(WorkspaceReadGuard)
  Xcodeproj::Workspace.prepend(WorkspaceWriteGuard)

  module CacheIntegrity
    def certificate_path(request)
      path = path_for_pod(request).relative_path_from(root).to_s
      root + '.swiftpods-integrity' + (Digest::SHA256.hexdigest(path) + '.json')
    end

    def certificate(request)
      { 'schema_version' => 1, 'name' => request.name,
        'tree_sha256' => SwiftPods.tree_digest(path_for_pod(request)),
        'spec_sha256' => SwiftPods.tree_digest(path_for_spec(request)) }
    end

    def cached_pod(request)
      if path_for_pod(request).directory? && path_for_spec(request).file?
        file = certificate_path(request)
        expected = JSON.parse(file.read) if file.file?
        unless expected && expected == certificate(request)
          raise Failure.new('SP-CACHE-INTEGRITY', 'cache', "Cached #{request.name} is incomplete or changed. Clean this pod's cache and download it again.", file: path_for_pod(request).to_s)
        end
      end
      super
    end

    def uncached_pod(request)
      if ENV['SWIFTPODS_OFFLINE'] == '1' && !request.params[:http] && !SwiftPods.local_source?(request.params[:git] || request.params[:svn] || request.params[:hg])
        raise Failure.new('SP-OFFLINE-MISSING', 'download', "Missing cached source for #{request.name}; offline mode did not contact its origin")
      end
      super
    end

    def write_spec(spec, path)
      result = super
      relative = path.relative_path_from(root + 'Specs').to_s.delete_suffix('.podspec.json')
      cert = root + '.swiftpods-integrity' + (Digest::SHA256.hexdigest(relative) + '.json')
      SwiftPods.atomic_json(cert, 'schema_version' => 1, 'name' => spec.name,
                                  'tree_sha256' => SwiftPods.tree_digest(root + relative),
                                  'spec_sha256' => SwiftPods.tree_digest(path))
      result
    end
  end
  Pod::Downloader::Cache.prepend(CacheIntegrity)

  module OfflineCDN
    def download_file_async(partial_url)
      return super unless ENV['SWIFTPODS_OFFLINE'] == '1'
      unless local_file_okay?(partial_url)
        raise Failure.new('SP-OFFLINE-MISSING', 'resolve', "Missing cached CDN object #{name}/#{partial_url}")
      end
      Concurrent::Promises.fulfilled_future(partial_url)
    end
  end
  Pod::CDNSource.prepend(OfflineCDN)

  module OfflineSources
    def create_source_with_url(url)
      if ENV['SWIFTPODS_OFFLINE'] == '1' && !SwiftPods.local_source?(url)
        raise Failure.new('SP-OFFLINE-MISSING', 'resolve', "Spec repository is not cached: #{url}")
      end
      super
    end

    def check_for_new_version(*args)
      return if ENV['SWIFTPODS_OFFLINE'] == '1'
      super
    end
  end
  Pod::Source::Manager.prepend(OfflineSources)

  module OfflineGitSource
    def update_git_repo(*args)
      if ENV['SWIFTPODS_OFFLINE'] == '1' && !SwiftPods.local_source?(url)
        raise Failure.new('SP-OFFLINE-NETWORK', 'resolve', "Cannot update spec repository #{name} offline")
      end
      super
    end
  end
  Pod::Source.prepend(OfflineGitSource)

  module OfflineDirectDownload
    def download_source(target, params)
      if ENV['SWIFTPODS_OFFLINE'] == '1' && !params[:http] && !SwiftPods.local_source?(params[:git] || params[:svn] || params[:hg])
        raise Failure.new('SP-OFFLINE-MISSING', 'download', 'No cached source is available for the requested dependency')
      end
      super
    end
  end
  Pod::Downloader.singleton_class.prepend(OfflineDirectDownload)

  module OfflinePodspec
    def fetch(sandbox)
      return super if SwiftPods.local_source?(podspec_uri)
      origin = { 'kind' => 'podspec', 'url' => SwiftPods.origin_identity(podspec_uri),
                 'identity_sha256' => Digest::SHA256.hexdigest(podspec_uri.to_s) }
      is_json = Pathname(podspec_uri).extname == '.json'
      if ENV['SWIFTPODS_OFFLINE'] == '1'
        cached = SwiftPods.content_cache('get', 'origin' => origin)
        unless cached['status'] == 'hit'
          raise Failure.new('SP-OFFLINE-MISSING', 'resolve', "Missing cached podspec: #{SwiftPods.origin_identity(podspec_uri)}")
        end
        return store_podspec(sandbox, File.read(cached.fetch('path')), is_json)
      end
      Pod::UI.titled_section("Fetching podspec for `#{name}` #{description}", :verbose_prefix => '-> ') do
        require 'cocoapods/open-uri'
        OpenURI.open_uri(podspec_uri) do |io|
          contents = io.read
          result = store_podspec(sandbox, contents, is_json)
          Tempfile.create('swiftpods-podspec') do |file|
            file.write(contents)
            file.flush
            SwiftPods.content_cache('put', 'origin' => origin, 'path' => file.path)
          end
          result
        end
      rescue OpenURI::HTTPError => e
        raise Pod::Informative, "Failed to fetch podspec for `#{name}` at `#{podspec_uri}`.\n Error: #{e.io.status.join(' ')}"
      end
    end
  end
  Pod::ExternalSources::PodspecSource.prepend(OfflinePodspec)

  module ArchiveGuard
    def extract_with_type(filename, type = :zip)
      unless type == :dmg
        output, error, status = Open3.capture3(ENV.fetch('SWIFTPODS_EXECUTABLE'), '__archivecheck', filename.to_s, '--json')
        unless status.success?
          report = JSON.parse(output) rescue {}
          raise Failure.new('SP-ARCHIVE-UNSAFE', 'extract', report.dig('diagnostic', 'message') || error, file: filename.to_s)
        end
      end
      super
    end

    def extract_dmg(unpack_from, unpack_to)
      require 'tmpdir'
      # macOS 27 moved image commands to diskutil. Detect the supported API;
      # stdout/stderr remain separate so tool diagnostics cannot corrupt a plist.
      modern = Pod::Executable.capture_command('diskutil', %w[image --help], :capture => :none).success?
      point = Dir.mktmpdir('swiftpods-dmg-', unpack_to.to_s)
      mounted = false
      begin
        command = modern ? ['image', 'attach', '--plist', '--readOnly', '--mountOptions', 'nobrowse', '--mountPoint', point, unpack_from] :
                           ['attach', '-plist', '-readonly', '-nobrowse', '-mountpoint', point, unpack_from]
        _output, error, = Pod::Executable.capture_command!(modern ? 'diskutil' : 'hdiutil', command, :capture => :both)
        warn error unless error.empty?
        mounted = true
        output, error, status = Open3.capture3(ENV.fetch('SWIFTPODS_EXECUTABLE'), '__treecheck', point, '--json')
        unless status.success?
          report = JSON.parse(output) rescue {}
          raise Failure.new('SP-ARCHIVE-UNSAFE', 'extract', report.dig('diagnostic', 'message') || error)
        end
        FileUtils.cp_r(Dir.glob(point + '/*'), unpack_to)
      ensure
        if mounted
          Pod::Executable.capture_command!(modern ? 'diskutil' : 'hdiutil', [modern ? 'eject' : 'detach', point], :capture => :both)
        end
        Dir.rmdir(point) if File.directory?(point)
      end
    end
  end
  Pod::Downloader::RemoteFile.prepend(ArchiveGuard)

  module OfflineSubmodules
    def update_submodules
      if ENV['SWIFTPODS_OFFLINE'] == '1' && options[:submodules]
        raise Failure.new('SP-OFFLINE-MISSING', 'download', 'An uncached submodule tree needs an online download; no managed submodule fetch was started')
      end
      super
    end
  end
  Pod::Downloader::Git.prepend(OfflineSubmodules)

  module GitRefCache
    def preprocess_options(options)
      return super unless options[:branch]
      root = Pathname(ENV.fetch('SWIFTPODS_CACHE_ROOT')) + 'git-refs'
      identity = [SwiftPods.origin_identity(options[:git]), options[:branch]]
      path = root + (Digest::SHA256.hexdigest(JSON.generate(identity)) + '.json')
      if ENV['SWIFTPODS_OFFLINE'] == '1' && !SwiftPods.local_source?(options[:git])
        unless path.file?
          raise Failure.new('SP-OFFLINE-MISSING', 'resolve', "No cached commit for Git branch #{options[:branch]}")
        end
        revision = JSON.parse(path.read).fetch('commit')
        raise Failure.new('SP-CACHE-INTEGRITY', 'cache', 'Invalid cached Git revision') unless revision.match?(/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/)
        return options.reject { |key, _| key == :branch }.merge(:commit => revision)
      end
      result = super
      SwiftPods.atomic_json(path, 'schema_version' => 1, 'commit' => result[:commit]) if result[:commit]
      result
    end
  end
  Pod::Downloader::Git.singleton_class.prepend(GitRefCache)

  module HardenedSpecification
    def from_string(contents, path, subspec_name = nil)
      if ENV['SWIFTPODS_HARDENED_MANIFEST'] && File.extname(path.to_s) != '.json'
        raise Failure.new('SP-HARDENED-RUBY', 'policy', 'Hardened mode accepts JSON podspecs only; Ruby was not evaluated', file: path.to_s)
      end
      result = super
      if ENV['SWIFTPODS_HARDENED_MANIFEST']
        scan = lambda do |value|
          if value.is_a?(Hash)
            value.each do |key, child|
              if (key.to_s == 'prepare_command' && !child.nil?) || (key.to_s == 'script_phases' && !Array(child).empty?)
                raise Failure.new('SP-HARDENED-SCRIPT', 'policy', "#{result.name} declares prepare/build scripts; hardened mode cannot omit them", file: path.to_s)
              end
              scan.call(child)
            end
          elsif value.is_a?(Array)
            value.each { |child| scan.call(child) }
          end
        end
        scan.call(result.root.attributes_hash)
      end
      result
    end
  end
  Pod::Specification.singleton_class.prepend(HardenedSpecification)
end
