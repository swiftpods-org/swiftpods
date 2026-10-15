# frozen_string_literal: true
module Pod
  Project = Xcodeproj::Project
  Podfile = SwiftPods::Podfile

  class Config
    attr_accessor :installation_root, :verbose, :silent
    def self.instance = @instance ||= new

    def initialize; @installation_root = Pathname(Dir.pwd); @verbose = false; @silent = false; end
    def sandbox_root = installation_root + "Pods"
    def podfile_path = installation_root + "Podfile"
    def lockfile_path = installation_root + "Podfile.lock"
  end

  class Dependency
    attr_reader :name, :requirement, :external_source

    def initialize(name, *versions)
      @name = name
      @external_source = versions.last.is_a?(Hash) ? versions.pop : nil
      @requirement = Gem::Requirement.new(*versions)
    end

    def root_name = name.split("/").first
    def to_s = name
    def ==(other) = other.is_a?(Dependency) && name == other.name && requirement == other.requirement && external_source == other.external_source

    alias eql? ==

    def hash = [name, requirement, external_source].hash
  end
end

class SwiftPods::Podfile
  def dependencies
    to_hash["targets"].flat_map { |target| target.fetch("dependencies", []) }.map { |entry| Pod::Dependency.new(entry["name"], *entry["requirements"]) }.uniq { |dependency| dependency.name }
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
    platform = @stack.reverse.filter_map { |entry| entry["platform"] }.first
    dependencies = specs.flat_map { |selected| [selected, *selected.recursive_subspecs].flat_map { |child| child.dependencies(platform && platform["name"].to_sym) } }.uniq
    dependencies.reject { |dependency| dependency.root_name == spec.name }.each { |dependency| pod(dependency.name, *dependency.requirement.requirements.map { |operation, version| operation + " " + version.to_s }) }
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
