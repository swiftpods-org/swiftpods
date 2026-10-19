# frozen_string_literal: true

module Pod
  class Sandbox
    attr_reader :root
    attr_accessor :directories, :specifications

    def initialize(root)
      @root = Pathname(root)
      @directories = {}
      @specifications = {}
    end

    def pod_dir(name)
      name = name.split("/", 2).first
      Pathname(@directories[name] || (@root + name).to_s)
    end

    def specification(name) = @specifications[name.split("/", 2).first]
    def public_headers = @public_headers ||= SwiftPods::Record.new(:root => @root + "Headers/Public")
  end

  class Installer
    attr_accessor :pods_project, :aggregate_targets, :pod_targets, :sandbox, :podfile, :generated_projects

    def initialize(project, podfile, root)
      @pods_project = project
      @generated_projects = [project].compact
      @podfile = podfile
      @sandbox = Sandbox.new(File.join(root, "Pods"))
      @pod_targets = project ? project.targets : []
      @aggregate_targets = []
    end
  end

  module HooksManager
    Hook = Struct.new(:name, :plugin_name, :block)
    class << self
      attr_reader :registrations

      def register(plugin, name, &block)
        raise ArgumentError, "Missing plugin, hook name or block" unless plugin && name && block
        (@registrations ||= {})[name.to_sym] ||= []
        @registrations[name.to_sym] << Hook.new(name.to_sym, plugin, block)
      end

      def hooks_to_run(name, plugins = nil)
        hooks = (@registrations || {}).fetch(name.to_sym, [])
        plugins ? hooks.select { |hook| plugins.key?(hook.plugin_name) } : hooks
      end

      def run(name, context, plugins = nil)
        raise ArgumentError, "Missing hook name or context" unless name && context
        hooks_to_run(name, plugins).each do |hook|
          options = plugins && plugins[hook.plugin_name]
          options = SwiftPods::PluginOptions.new(options) if options
          hook.block.arity > 1 ? hook.block.call(context, options) : hook.block.call(context)
        end
      end
    end
  end

  class UI
    def self.message(*)
      yield if block_given?
    end
    def self.puts(text)
      $stderr.puts(text)
    end
    def self.warn(text)
      $stderr.puts(text)
    end
  end
end

module SwiftPods
  # Plugin configuration accepts string and symbol keys at every nested level,
  # including values assigned by a hook after the options have been created.
  class PluginOptions < Hash
    def initialize(value)
      super()
      update(value)
    end

    def [](key) = super(key.to_s)
    def fetch(key, *arguments, &block) = super(key.to_s, *arguments, &block)
    def key?(key) = super(key.to_s)
    def dig(key, *rest) = super(key.to_s, *rest)
    def delete(key, &block) = super(key.to_s, &block)
    def values_at(*keys) = super(*keys.map(&:to_s))
    def with_indifferent_access = self

    alias include? key?
    alias has_key? key?
    alias member? key?

    def []=(key, value)
      super(key.to_s, convert_value(value))
    end

    alias store []=

    def update(other)
      other.each_pair do |key, value|
        value = yield(key.to_s, self[key], value) if block_given? && key?(key)
        self[key] = value
      end
      self
    end

    alias merge! update

    def merge(other, &block)
      dup.update(other, &block)
    end

    def replace(other)
      return self if other.equal?(self)
      clear
      update(other)
    end

    private

    def convert_value(value)
      case value
      when Hash then self.class.new(value)
      when Array then value.map { |item| convert_value(item) }
      else value
      end
    end
  end
end

module Pod
  def self._eval_podspec(source, filename)
    eval(source, nil, filename.to_s, 1)
  end

  class Source
    attr_reader :repo

    def initialize(path)
      @repo = Pathname(path)
    end

    def url = repo.to_s
    def name = repo.basename.to_s
  end

  class Installer
    PreInstallHooksContext = Struct.new(:podfile, :sandbox, :sandbox_root, :lockfile)

    class BaseInstallHooksContext
      attr_reader :sandbox, :sandbox_root, :pods_project, :pod_target_subprojects, :umbrella_targets

      def initialize(sandbox, root, project, children, targets)
        @sandbox = sandbox
        @sandbox_root = root
        @pods_project = project
        @pod_target_subprojects = children
        @umbrella_targets = targets
      end

      def generated_projects = [pods_project, *pod_target_subprojects].compact
    end

    class PostInstallHooksContext < BaseInstallHooksContext
    end

    class SourceProviderHooksContext
      attr_reader :sources

      def initialize
        @sources = []
      end

      def add_source(source)
        @sources << source
      end
    end
  end
end
