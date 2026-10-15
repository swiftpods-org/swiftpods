# frozen_string_literal: true

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
      @targets = []
      @hooks = {}
      @stack = [@data]
      @parents = {}
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

    def workspace(path)
      @data["workspace"] = path
    end

    def source(url)
      @data["sources"] << url
    end

    def use_frameworks!(options = true)
      raise ArgumentError, "use_frameworks! expects a boolean or a hash" unless options == true || options == false || options.is_a?(Hash)
      value = options.is_a?(Hash) ? options.fetch(:linkage).to_s : (options ? "dynamic" : nil)
      raise ArgumentError, "Unknown framework linkage" unless value.nil? || %w[static dynamic].include?(value)
      current["frameworks"] = value
    end

    def use_modular_headers!
      current["modular_headers"] = true
    end

    def inhibit_all_warnings!
      current["inhibit_warnings"] = true
    end

    def install!(name, options = {})
      raise Pod::Informative, "The installation method can only be set at the root level of the Podfile." unless current.equal?(@data)
      raise Unsupported, "Unknown installation method #{name}" unless %w[cocoapods swiftpods].include?(name)
      parsed = Pod::Installer::InstallationOptions.new(options)
      @data["options"] = parsed.to_h(include_defaults: false)
    end

    def swift_version(value)
      current["swift_version"] = value.to_s
    end

    def supports_swift_versions(*requirements)
      values = requirements.flatten.map(&:to_s)
      current["swift_version_requirements"] = values
    end

    def target(name, options = nil, &block)
      raise Pod::Informative, "Unsupported options `#{options}` for target `#{name}`." if options
      define_target(name, false, &block)
    end

    def abstract_target(name, &block)
      define_target(name, true, &block)
    end

    def abstract!(value = true)
      current["abstract"] = value
    end

    def xcodeproj(*arguments)
      Pod::UI.warn("`xcodeproj` was renamed to `project`. Please update your Podfile accordingly.")
      project(*arguments)
    end

    def link_with(*)
      raise(Pod::Informative, "The specification of `link_with` in the Podfile is now unsupported, please use target blocks instead.")
    end

    def generate_bridge_support!
      @data["generate_bridge_support"] = true
    end

    def set_arc_compatibility_flag!
      @data["set_arc_compatibility_flag"] = true
    end

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
      (@inheritance ||= TargetInheritance.new(@data, @parents)).resolve(entry)
    end

    def to_hash
      @data.merge("targets" => @targets.reject { |target| target["abstract"] }.map { |target| resolved(target) })
    end
  end
end
