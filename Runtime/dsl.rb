# frozen_string_literal: true
# SwiftPods' own Ruby DSL adapter. Dependency resolution and Xcode generation
# are performed in Swift. No third-party engine is loaded here.
require "json"
require "pathname"
require "digest"
require "yaml"
require "ostruct"

module SwiftPods
  class Unsupported < StandardError; end

  class Record
    def initialize(values)
      @values = values.transform_keys(&:to_sym).freeze
      @values.each_key { |name| define_singleton_method(name) { @values.fetch(name) } }
    end

    def to_h = @values.dup
  end

  module EngineIsolation
    def require(path)
      if %w[xcodeproj xcodeproj/project cocoapods cocoapods-core cocoapods/version cocoapods-core/version cocoapods-core/platform cocoapods-core/requirement cocoapods-core/specification cocoapods-core/specification/dsl cocoapods/target/build_type cocoapods/installer cocoapods/hooks_manager cocoapods/installer/base_install_hooks_context cocoapods/installer/pre_install_hooks_context cocoapods/installer/post_install_hooks_context cocoapods/installer/source_provider_hooks_context].include?(path.to_s)
        return false if ($swiftpods_own_features ||= []).include?(path.to_s)
        $swiftpods_own_features << path.to_s
        return true
      end
      if path.to_s.match?(%r{\A(?:cocoapods(?:-core)?)(?:/|\z)})
        raise Unsupported, "Loading a third-party installation engine is forbidden: #{path}"
      end
      super
    end
  end
end

Kernel.prepend(SwiftPods::EngineIsolation)
require "bundler/setup" if ENV["SWIFTPODS_PROFILE_GEMFILE"]
# Bundler's setup API does not populate the executable marker set by `bundle
# exec`. Both enter the same verified imported gem environment here.
if ENV["SWIFTPODS_PROFILE_GEMFILE"]
  ENV["BUNDLE_BIN_PATH"] = Gem.bin_path("bundler", "bundle", Bundler::VERSION)
end

module Pod
  VERSION = "1.17.0" # Public API contract version; no external engine is loaded.

  class Specification
    ATTRIBUTES = %w[name version summary description homepage license author authors source source_files exclude_files public_header_files private_header_files project_header_files header_dir header_mappings_dir module_name module_map requires_arc frameworks weak_frameworks libraries resources resource_bundles on_demand_resources vendored_frameworks vendored_libraries preserve_paths pod_target_xcconfig user_target_xcconfig xcconfig compiler_flags swift_version swift_versions static_framework prepare_command script_phase script_phases default_subspec default_subspecs prefix_header_file prefix_header_contents deprecated deprecated_in_favor deprecated_in_favor_of cocoapods_version documentation_url social_media_url screenshots source_map readme changelog platforms test_type requires_app_host app_host_name scheme info_plist].freeze
    attr_reader :data

    def initialize(name = nil, parent = nil)
      @data = {}
      @data["name"] = name if name
      @parent = parent
      yield self if block_given?
      Pod.instance_variable_set(:@last_spec, self) unless parent
    end

    def to_hash = @data
    def name = @parent ? @parent.name + "/" + @data["name"].to_s : @data["name"].to_s
    def to_s = name
    def root = @parent ? @parent.root : self
    def parent = @parent

    def self.from_hash(data)
      new.tap { |spec| spec.data.merge!(data) }
    end
    def self.from_file(path)
      path = File.realpath(File.expand_path(path.to_s))
      contents = File.read(path)
      spec = if path.end_with?(".json")
          from_hash(JSON.parse(contents))
        else
          Dir.chdir(File.dirname(path)) { Pod._eval_podspec(contents, path) }
        end
      raise Pod::Informative, "Podspec did not return a specification" unless spec.is_a?(Specification)
      spec.defined_in_file = Pathname(path)
      (Pod.instance_variable_get(:@spec_inputs) || Pod.instance_variable_set(:@spec_inputs, {}))[path] = Digest::SHA256.hexdigest(contents)
      spec
    end

    def dependency(name, *requirements)
      (@data["dependencies"] ||= {})[name] = requirements.flatten.empty? ? [">= 0"] : requirements.flatten
    end

    def subspec(name)
      child = self.class.new(name, self)
      child.instance_variable_set(:@spec_kind, :library)
      yield child
      (@data["subspecs"] ||= []) << child.data
      (@children ||= {})["subspecs"] ||= []; @children["subspecs"] << child
      child
    end

    def test_spec(name = "Tests")
      child = self.class.new(name, self)
      child.instance_variable_set(:@spec_kind, :test)
      child.data["test_type"] = "unit"
      yield child if block_given?
      (@data["testspecs"] ||= []) << child.data
      (@children ||= {})["testspecs"] ||= []; @children["testspecs"] << child
      child
    end

    def app_spec(name = "App")
      child = self.class.new(name, self)
      child.instance_variable_set(:@spec_kind, :app)
      yield child if block_given?
      (@data["appspecs"] ||= []) << child.data
      (@children ||= {})["appspecs"] ||= []; @children["appspecs"] << child
      child
    end

    def method_missing(name, *values)
      key = name.to_s
      if %w[ios osx tvos watchos visionos].include?(key)
        return Platform.new(@data[key] ||= {})
      elsif key == "platform="
        platform, version = values.first
        (@data["platforms"] ||= {})[platform.to_s] = version.to_s
      elsif key.end_with?("=") && ATTRIBUTES.include?(key.delete_suffix("="))
        attribute = key.delete_suffix("=")
        if %w[author swift_version default_subspec xcconfig deprecated_in_favor].include?(attribute)
          canonical = { "author" => "authors", "swift_version" => "swift_versions", "default_subspec" => "default_subspecs", "xcconfig" => "pod_target_xcconfig", "deprecated_in_favor" => "deprecated_in_favor_of" }.fetch(attribute)
          value = values.first
          @data[canonical] = %w[swift_version default_subspec].include?(attribute) ? Array(value).map(&:to_s) : value
        elsif %w[script_phase script_phases].include?(attribute)
          value = values.first
          @data["script_phases"] = value.nil? || value.is_a?(Array) ? value : [value]
        else
          @data[attribute] = values.first
        end
      elsif ATTRIBUTES.include?(key) && values.empty?
        key == "script_phase" ? @data["script_phases"]&.first : (@data.key?(key) ? @data[key] : (@parent&.public_send(name)))
      else
        super
      end
    end

    def respond_to_missing?(name, _private = false) = ATTRIBUTES.include?(name.to_s.delete_suffix("=")) || super

    class Platform
      def initialize(data); @data = data; end
      def deployment_target=(value); @data["deployment_target"] = value.to_s; end
      def dependency(name, *requirements); (@data["dependencies"] ||= {})[name] = requirements; end

      def method_missing(name, *values)
        key = name.to_s.delete_suffix("=")
        if %w[script_phase script_phases].include?(key)
          return key == "script_phase" ? @data["script_phases"]&.first : @data["script_phases"] if values.empty?
          value = values.first
          return @data["script_phases"] = value.nil? || value.is_a?(Array) ? value : [value] if name.to_s.end_with?("=")
        end
        return @data[key] if values.empty? && Specification::ATTRIBUTES.include?(key)
        return @data[key] = values.first if name.to_s.end_with?("=") && Specification::ATTRIBUTES.include?(key)
        super
      end
    end
  end

  Spec = Specification

  class Sandbox
    attr_reader :root
    attr_accessor :directories, :specifications

    def initialize(root); @root = Pathname(root); @directories = {}; @specifications = {}; end
    def pod_dir(name) = Pathname(@directories[name] || (@root + name).to_s)
    def specification(name) = @specifications[name]
    def public_headers = @public_headers ||= SwiftPods::Record.new(:root => @root + "Headers/Public")
  end

  class Installer
    attr_accessor :pods_project, :aggregate_targets, :pod_targets, :sandbox, :podfile, :generated_projects

    def initialize(project, podfile, root)
      @pods_project = project; @generated_projects = [project].compact; @podfile = podfile
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
    def self.message(*); yield if block_given?; end
    def self.puts(text); $stderr.puts(text); end
    def self.warn(text); $stderr.puts(text); end
  end
end

module SwiftPods
  class PluginOptions < Hash
    def initialize(value); super(); value.each { |key, item| self[key.to_s] = item.is_a?(Hash) ? self.class.new(item) : item }; end
    def [](key) = super(key.to_s)
    def fetch(key, *args, &block) = super(key.to_s, *args, &block)
    def key?(key) = super(key.to_s)
    def with_indifferent_access = self
  end
end

module Pod
  def self._eval_podspec(source, filename)
    eval(source, nil, filename.to_s, 1)
  end

  class Source
    attr_reader :repo

    def initialize(path); @repo = Pathname(path); end
    def url = repo.to_s
    def name = repo.basename.to_s
  end

  class Installer
    PreInstallHooksContext = Struct.new(:podfile, :sandbox, :sandbox_root, :lockfile)

    class BaseInstallHooksContext
      attr_reader :sandbox, :sandbox_root, :pods_project, :pod_target_subprojects, :umbrella_targets

      def initialize(sandbox, root, project, children, targets)
        @sandbox = sandbox; @sandbox_root = root; @pods_project = project
        @pod_target_subprojects = children; @umbrella_targets = targets
      end

      def generated_projects = [pods_project, *pod_target_subprojects].compact
    end

    class PostInstallHooksContext < BaseInstallHooksContext; end

    class SourceProviderHooksContext
      attr_reader :sources

      def initialize; @sources = []; end
      def add_source(source); @sources << source; end
    end
  end
end

require "securerandom"
require_relative "project"

module SwiftPods
  class Podfile
    # User closures retain this method's lexical scope, never the protocol loop's
    # state. Names such as project, installer and request are valid user locals.
    def evaluate_file(manifest_path)
      instance_eval(File.read(manifest_path), manifest_path, 1)
    end

    attr_reader :targets, :hooks, :data

    def initialize
      @data = { "sources" => [], "plugins" => {}, "options" => {} }
      @targets = []; @hooks = {}; @stack = [@data]; @parents = {}
    end

    def current = @stack.last

    def platform(name, version = nil)
      defaults = { "ios" => "4.3", "osx" => "10.6", "tvos" => "9.0", "watchos" => "2.0", "visionos" => "1.0" }
      raise Pod::Informative, "Unsupported platform #{name}" unless defaults.key?(name.to_s)
      current["platform"] = { "name" => name.to_s, "deployment_target" => (version || defaults.fetch(name.to_s)).to_s }
    end

    def project(path, configurations = {})
      current["project"] = path.end_with?(".xcodeproj") ? path : path + ".xcodeproj"
      current["configurations"] = configurations unless configurations.empty?
    end

    def workspace(path); @data["workspace"] = path; end
    def source(url); @data["sources"] << url; end

    def use_frameworks!(options = true)
      raise ArgumentError, "use_frameworks! expects a boolean or a hash" unless options == true || options == false || options.is_a?(Hash)
      value = options.is_a?(Hash) ? options.fetch(:linkage).to_s : (options ? "dynamic" : nil)
      raise ArgumentError, "Unknown framework linkage" unless value.nil? || %w[static dynamic].include?(value)
      current["frameworks"] = value
    end

    def use_modular_headers!; current["modular_headers"] = true; end
    def inhibit_all_warnings!; current["inhibit_warnings"] = true; end

    def install!(name, options = {})
      raise Pod::Informative, "The installation method can only be set at the root level of the Podfile." unless current.equal?(@data)
      raise Unsupported, "Unknown installation method #{name}" unless %w[cocoapods swiftpods].include?(name)
      parsed = Pod::Installer::InstallationOptions.new(options)
      @data["options"] = parsed.to_h(include_defaults: false)
    end

    def swift_version(value); current["swift_version"] = value.to_s; end

    def supports_swift_versions(*requirements)
      values = requirements.flatten.map(&:to_s)
      current["swift_version_requirements"] = values
    end

    def target(name, options = nil, &block)
      raise Pod::Informative, "Unsupported options `#{options}` for target `#{name}`." if options
      define_target(name, false, &block)
    end

    def abstract_target(name, &block); define_target(name, true, &block); end
    def abstract!(value = true); current["abstract"] = value; end

    def xcodeproj(*arguments)
      Pod::UI.warn("`xcodeproj` was renamed to `project`. Please update your Podfile accordingly.")
      project(*arguments)
    end

    def link_with(*) = raise(Pod::Informative, "The specification of `link_with` in the Podfile is now unsupported, please use target blocks instead.")
    def generate_bridge_support!; @data["generate_bridge_support"] = true; end
    def set_arc_compatibility_flag!; @data["set_arc_compatibility_flag"] = true; end

    def inherit!(kind)
      kind = kind.to_s
      raise Pod::Informative, "Unknown inheritance #{kind}" unless %w[complete none search_paths].include?(kind)
      raise Pod::Informative, "Cannot set inheritance for root or abstract targets" if current.equal?(@data) || current["abstract"]
      current["inheritance"] = kind
    end

    def define_target(name, abstract, &block)
      entry = { "name" => name.to_s, "abstract" => abstract, "dependencies" => [], "_id" => @targets.length }
      @parents[entry.object_id] = current
      @targets << entry
      @stack << entry
      instance_eval(&block) if block
    ensure
      @stack.pop
    end

    def pod(name, *args)
      options = args.last.is_a?(Hash) ? args.pop.transform_keys(&:to_s) : {}
      options["configurations"] = Array(options.delete("configuration")) if options.key?("configuration") && !options.key?("configurations")
      (current["dependencies"] ||= []) << { "name" => name, "requirements" => (args.empty? ? [">= 0"] : args), "options" => options }
    end

    def spm(name, options)
      (current["packages"] ||= []) << options.transform_keys(&:to_s).merge("name" => name)
    end

    def script_phase(options)
      raise Unsupported, "script_phase requires a hash" unless options.is_a?(Hash)
      phase = options.transform_keys(&:to_s)
      phases = (current["script_phases"] ||= [])
      raise Unsupported, "Duplicate script phase #{phase["name"]}" if phases.any? { |entry| entry["name"] == phase["name"] }
      phases << phase
    end

    def plugin(name, options = {})
      @data["plugins"][name] = options
      gem = Gem.loaded_specs[name]
      entry = gem && File.join(gem.full_gem_path, "lib", "cocoapods_plugin.rb")
      entry && File.file?(entry) ? require(entry) : require(name)
    end

    %w[pre_install pre_integrate post_install post_integrate].each do |name|
      define_method(name) do |&block|
        raise Pod::Informative, "Specifying multiple `#{name}` hooks is unsupported." if name != "pre_install" && @hooks[name]
        @hooks[name] = block
      end
    end

    def resolved(entry)
      parent = @parents[entry.object_id]
      inherited = parent ? resolved(parent) : {}
      result = Marshal.load(Marshal.dump(inherited.reject { |key, _| %w[name abstract dependencies search_dependencies script_phases packages inheritance].include?(key) }))
      result.merge!(entry)
      mode = entry.fetch("inheritance", "complete")
      can_inherit = inherited["platform"] == result["platform"] || (parent && (parent.equal?(@data) || parent["abstract"]) && inherited["platform"].nil?)
      result["label"] = entry.equal?(@data) ? "Pods" : (mode != "complete" || !can_inherit ? "Pods-" + entry.fetch("name") : inherited.fetch("label", "Pods") + "-" + entry.fetch("name"))
      result["own_swift_version_requirements"] = entry["swift_version_requirements"]
      result["dependencies"] = entry.fetch("dependencies", []) + (mode == "complete" && can_inherit ? inherited.fetch("dependencies", []) : [])
      result["search_dependencies"] = can_inherit ? inherited.fetch("search_dependencies", []) : []
      if mode == "search_paths" && parent && !parent.equal?(@data) && !parent["abstract"]
        result["search_dependencies"] += inherited.fetch("dependencies", [])
      end
      result["dependencies"] = Marshal.load(Marshal.dump(result["dependencies"]))
      result["dependencies"].each do |dependency|
        next if dependency["options"].key?("configurations")
        inherited_rule = inherited.fetch("dependencies", []).find { |entry| entry["name"] == dependency["name"] && entry["options"].key?("configurations") }
        if mode == "none"
          dependency["options"]["configurations"] = []
        elsif inherited_rule
          dependency["options"]["configurations"] = inherited_rule["options"]["configurations"]
        end
      end
      result["packages"] = (mode == "none" ? [] : inherited.fetch("packages", [])) + entry.fetch("packages", [])
      result
    end

    def to_hash = @data.merge("targets" => @targets.reject { |target| target["abstract"] }.map { |target| resolved(target) })
  end
end

require_relative "options"
require_relative "helpers"
require_relative "models"
require_relative "attributes"

$swiftpods_environment_inputs = {}

module SwiftPods::EnvironmentInputs
  def [](name)
    value = super
    $swiftpods_environment_inputs[name.to_s] = { "status" => "tracked", "sha256" => Digest::SHA256.hexdigest(value.nil? ? "absent" : "value:" + value) }
    value
  end

  def fetch(name, *arguments, &block)
    self[name]
    super
  end

  def key?(name)
    self[name]
    super
  end
end

ENV.singleton_class.prepend(SwiftPods::EnvironmentInputs)

channel = STDOUT.dup
channel.sync = true
$swiftpods_channel = channel

module SwiftPods
  def self.callback(operation, data)
    $swiftpods_channel.puts(JSON.generate({ "callback" => operation, "value" => data }))
    response = JSON.parse(STDIN.gets || raise("Swift callback channel closed"))
    raise Unsupported, response["message"] unless response["ok"]
    response["value"]
  end
end

STDOUT.reopen(STDERR)
$stdout = STDOUT
podfile = nil
installer = nil
inputs = {}
evaluated_specs = {}
while (line = STDIN.gets)
  begin
    request = JSON.parse(line)
    case request.fetch("operation")
    when "podfile"
      path = File.realpath(request.fetch("path"))
      Dir.chdir(File.dirname(path))
      podfile = SwiftPods::Podfile.new
      podfile.evaluate_file(path)
      inputs[path] = Digest::SHA256.file(path).hexdigest
      result = podfile.to_hash
    when "analyzed_podfile"
      request.fetch("targets").each do |value|
        entry = podfile.instance_variable_get(:@targets).find { |target| target["_id"] == value["_id"] }
        raise SwiftPods::Unsupported, "Analyzed target identity is missing" unless entry
        %w[platform project swift_version].each { |key| value[key].nil? ? entry.delete(key) : entry[key] = value[key] }
      end
      result = podfile.to_hash
    when "spec"
      path = File.realpath(request.fetch("path"))
      evaluated_specs[path] = Pod::Spec.from_file(path)
      result = evaluated_specs[path].to_hash
      inputs[path] = Digest::SHA256.file(path).hexdigest
    when "spec_serialization"
      path = File.realpath(request.fetch("path"))
      spec = evaluated_specs[path] ||= Pod::Spec.from_file(path)
      result = { "json" => spec.to_pretty_json }
      inputs[path] = Digest::SHA256.file(path).hexdigest
    when "yaml"
      result = YAML.safe_load(File.read(request.fetch("path")), permitted_classes: [Symbol], aliases: false) || {}
    when "plugins_prepare"
      sandbox = Pod::Sandbox.new(File.join(Dir.pwd, "Pods"))
      context = Pod::Installer::PreInstallHooksContext.new(podfile, sandbox, sandbox.root.to_s, File.file?("Podfile.lock") ? YAML.safe_load(File.read("Podfile.lock"), permitted_classes: [Symbol], aliases: false) : nil)
      Pod::HooksManager.run(:pre_install, context, podfile.data["plugins"])
      sources = Pod::Installer::SourceProviderHooksContext.new
      Pod::HooksManager.run(:source_provider, sources, podfile.data["plugins"])
      podfile.data["sources"].concat(sources.sources.map { |source| source.respond_to?(:url) ? source.url : source.to_s })
      result = podfile.to_hash
    when "hook", "plugin_hook"
      podfile.instance_variable_set(:@analyzed_targets, request["manifest"]["targets"]) if request["manifest"]
      data = request.fetch("project")
      project = if data["generated"] == false
          nil
        elsif installer&.pods_project
          installer.pods_project.update!(data)
        else
          Xcodeproj::Project.new(data)
        end
      if installer
        installer.pods_project = project
      else
        installer = Pod::Installer.new(project, podfile, Dir.pwd)
      end
      previous_projects = installer.generated_projects.to_h { |entry| [entry.path.to_s, entry] }
      child_projects = request.fetch("projects", []).map { |entry| previous_projects[entry.fetch("path")]&.update!(entry) || Xcodeproj::Project.new(entry) }
      installer.generated_projects = child_projects.empty? ? [project].compact : child_projects
      installer.instance_variable_set(:@hook_phase, request.fetch("name"))
      installer.instance_variable_set(:@integrate_user_projects, request["integrate_user_projects"])
      installer.update_targets!(request.fetch("pod_targets", []))
      name = request.fetch("name")
      if request.fetch("operation") == "plugin_hook"
        context = Pod::Installer::PostInstallHooksContext.new(installer.sandbox, installer.sandbox.root.to_s, project, child_projects, installer.aggregate_targets)
        Pod::HooksManager.run(name, context, podfile.data["plugins"])
      else
        podfile.hooks[name]&.call(installer)
      end
      result = (project ? project.to_hash.merge("projects" => child_projects.map(&:to_hash)) : data).merge("pod_targets" => installer.pod_targets.map(&:to_native), "user_projects" => installer.user_projects.map(&:to_hash))
    when "glob"
      result = Dir.glob(request.fetch("patterns"), :base => request.fetch("root")).sort
    when "inputs"
      inputs.merge!(Pod.instance_variable_get(:@spec_inputs) || {})
      $LOADED_FEATURES.select { |path| path.start_with?(Dir.pwd + "/") }.each { |path| inputs[path] = Digest::SHA256.file(path).hexdigest if File.file?(path) }
      result = { "files" => inputs, "environment" => $swiftpods_environment_inputs, "coverage" => "Evaluated manifests, loaded project helpers and observed ENV reads; arbitrary filesystem, process and network inputs are not fully tracked" }
    else
      raise SwiftPods::Unsupported, "Unknown DSL operation #{request["operation"]}"
    end
    channel.puts(JSON.generate({ "ok" => true, "value" => result }))
  rescue Exception => error
    channel.puts(JSON.generate({ "ok" => false, "class" => error.class.name, "message" => error.message, "backtrace" => error.backtrace }))
  end
end
