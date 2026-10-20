# frozen_string_literal: true

module Pod
  Project = Xcodeproj::Project
  Podfile = SwiftPods::Podfile

  class Config
    attr_accessor :installation_root, :verbose, :silent
    def self.instance
      @instance ||= new
    end

    def initialize
      @installation_root = Pathname(Dir.pwd)
      @verbose = false
      @silent = false
    end

    def sandbox_root
      installation_root + "Pods"
    end

    def podfile_path
      installation_root + "Podfile"
    end

    def lockfile_path
      installation_root + "Podfile.lock"
    end
  end

  class Dependency
    SOURCE_OPTIONS = %w[
      path git branch tag commit podspec http sha1 sha256 type flatten headers svn folder revision hg submodules
    ].freeze
    attr_reader :name, :requirement, :external_source
    def self.from_manifest(entry)
      source = entry.fetch("options", {}).select { |key, _| SOURCE_OPTIONS.include?(key.to_s) }.transform_keys(&:to_sym)
      arguments = [entry.fetch("name"), *entry.fetch("requirements", [">= 0"])]
      arguments << source unless source.empty?
      new(*arguments)
    end

    def initialize(name, *versions)
      @name = name
      @external_source = versions.last.is_a?(Hash) ? versions.pop : nil
      @requirement = Pod::Requirement.new(*versions)
    end

    def root_name
      name.split("/").first
    end

    def to_s
      name
    end

    def ==(other)
      other.is_a?(Dependency) && name == other.name && requirement == other.requirement && external_source == other.external_source
    end

    alias eql? ==

    def hash
      [name, requirement, external_source].hash
    end
  end
end

class SwiftPods::Podfile
  def dependencies
    to_hash["targets"].flat_map { |target| target.fetch("dependencies", []) }.map { |entry| Pod::Dependency.from_manifest(entry) }.uniq
  end

  def podspec(options = nil)
    options ||= {}
    path = options[:path] || options[:name]
    path += ".podspec" if path && !File.basename(path).include?(".podspec")
    path ||= Dir.glob("*.podspec{,.json}").first
    raise ArgumentError, "No podspec found" unless path
    spec = Pod::Spec.from_file(path)
    selection = options[:subspecs] || options[:subspec]
    specs = selection ? Array(selection).map { |name| spec.subspec_by_name(spec.name + "/" + name) } : [spec]
    scope = @stack.reverse.find { |entry| entry["platform"] }
    platform = scope && scope["platform"]
    platform_name = platform && platform["name"].to_sym
    dependencies = specs.flat_map do |selected|
      [selected, *selected.recursive_subspecs].flat_map { |child| child.dependencies(platform_name) }
    end.uniq
    dependencies.reject { |dependency| dependency.root_name == spec.name }.each do |dependency|
      requirements = dependency.requirement.requirements.map { |operation, version| operation + " " + version.to_s }
      pod(dependency.name, *requirements)
    end
  end

  def ensure_bundler!(*versions)
    raise Pod::Informative, "The Ensure Bundler check can only be set at the root level of the Podfile." unless current.equal?(data)
    unless ENV["SWIFTPODS_PROFILE_GEMFILE"] && %w[BUNDLE_BIN_PATH BUNDLE_GEMFILE].all? { |key| ENV.key?(key) }
      raise Pod::Informative, "No imported Bundler profile is selected. Use swiftpods env import --gemfile Gemfile, then select it with --environment NAME."
    end
    require "bundler"
    requirement = Gem::Requirement.new(*versions)
    raise Pod::Informative, "Bundler #{Bundler::VERSION} does not satisfy #{requirement}" unless requirement.satisfied_by?(Gem::Version.new(Bundler::VERSION))
  end
end
