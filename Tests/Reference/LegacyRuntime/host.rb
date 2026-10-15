# frozen_string_literal: true

require 'json'
require 'pathname'

module SwiftPods
  PROTOCOL_VERSION = 1
  @channel = IO.for_fd(Integer(ENV.fetch('SWIFTPODS_EVENT_FD')), 'w')
  @channel.close_on_exec = true
  @channel.sync = true
  @sequence = 0

  def self.emit(kind, payload = {})
    @sequence += 1
    @channel.puts(JSON.generate(payload.merge('protocol_version' => PROTOCOL_VERSION,
                                             'sequence' => @sequence, 'kind' => kind)))
  end

  def self.diagnostic(error, stage = 'command')
    # CocoaPods wraps hook failures in Informative and embeds the original
    # backtrace in its message; the wrapper's own backtrace omits the Podfile.
    frames = (error.backtrace || []) + error.message.lines.map(&:strip)
    location = frames.find { |line| line.match?(/(?:Podfile|\.podspec):\d+/) }
    file, line = location&.match(/\A(.+?):(\d+)/)&.captures
    specific = error
    specific = specific.cause while specific.cause && !specific.respond_to?(:code)
    code = case specific.class.name
           when /VersionConflict|VersionResolutionError/ then 'SP-RESOLVE-CONFLICT'
           when /MissingSpec|GemNotFound/ then 'SP-ENV-GEM-MISSING'
           when /DSLError|GemfileError/ then 'SP-DSL-ERROR'
           when /LoadError/ then 'SP-RUBY-LOAD'
           else 'SP-RUBY-ERROR'
           end
    chains = if specific.respond_to?(:conflicts)
               specific.conflicts.values.flat_map do |conflict|
                 conflict.requirement_trees.map { |tree| tree.map { |dependency| { 'name' => dependency.name, 'requirement' => dependency.requirement.to_s } } }
               end
             end
    emit('diagnostic', 'code' => specific.respond_to?(:code) ? specific.code : code,
                      'stage' => specific.respond_to?(:stage) ? specific.stage : code == 'SP-RESOLVE-CONFLICT' ? 'resolve' : stage, 'message' => error.message,
                      'file' => specific.respond_to?(:file) && specific.file ? specific.file : file,
                      'line' => line&.to_i, 'backtrace' => error.backtrace,
                      'dependency_chains' => chains,
                      'state' => specific.respond_to?(:state) ? specific.state : nil)
  end
end

status = 0
begin
  if ARGV.first == '__environment_import'
    require_relative 'import_task'
    SwiftPods.emit('started', 'producer' => 'SwiftPods', 'ruby' => RUBY_VERSION, 'command' => 'env import')
    SwiftPods.import_environment(*ARGV.drop(1))
  else
    # Only an explicitly selected profile can replace the shipped Gemfile.
    require 'bundler/setup'
    require 'cocoapods'
    require_relative 'safety'
    require_relative 'inputs'
    require_relative 'swiftpm'
    require_relative 'process_events'
    require_relative 'content_cache'
    require_relative 'instrumentation'
    Pod::Config.instance.cache_root = Pathname(ENV.fetch('SWIFTPODS_CACHE_ROOT'))
    SwiftPods::Inputs.project = ENV['SWIFTPODS_PROJECT_ROOT'] || Pod::Config.instance.installation_root.to_s
    if (manifest = ENV['SWIFTPODS_HARDENED_MANIFEST'])
    data = JSON.parse(File.read(manifest))
    podfile = Pod::Podfile.new(Pathname(manifest)) do
      platform data.fetch('platform').fetch('name').to_sym, data.fetch('platform').fetch('deployment_target')
      project data.fetch('project')
      workspace data['workspace'] if data['workspace']
      Array(data['sources']).each { |url| source url }
      use_frameworks! :linkage => data['frameworks'].to_sym if data['frameworks']
      data.fetch('targets').each do |entry|
        target entry.fetch('name') do
          entry.fetch('pods').each do |dependency|
            options = dependency.reject { |key, _| %w[name versions].include?(key) }.transform_keys(&:to_sym)
            pod dependency.fetch('name'), *Array(dependency['versions']), options
          end
        end
      end
    end
    Pod::Config.instance.podfile = podfile
    Pod::Config.instance.installation_root = Pathname(File.dirname(manifest))
    end
    SwiftPods.emit('started', 'producer' => 'SwiftPods', 'cocoapods' => Pod::VERSION,
                           'ruby' => RUBY_VERSION, 'command' => ARGV.first)
    Pod::Command.run(ARGV)
  end
rescue SystemExit => error
  status = error.status
rescue Interrupt
  status = 130
  warn '[!] Cancelled'
rescue Exception => error # includes Ruby syntax errors and failed gem loading
  status = 1
  SwiftPods.diagnostic(error)
  warn "#{error.class}: #{error.message}"
  warn error.backtrace.join("\n") if error.backtrace
ensure
  SwiftPods.emit('completed', 'status' => status)
end
exit status
