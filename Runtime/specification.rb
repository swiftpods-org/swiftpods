# frozen_string_literal: true

module Pod
  VERSION = "1.17.0" # Public API contract version; no external engine is loaded.

  class Specification
    ATTRIBUTES = %w[
      name version summary description homepage license author authors source source_files
      exclude_files public_header_files private_header_files project_header_files header_dir
      header_mappings_dir module_name module_map requires_arc frameworks weak_frameworks libraries
      resources resource_bundles on_demand_resources vendored_frameworks vendored_libraries
      preserve_paths pod_target_xcconfig user_target_xcconfig xcconfig compiler_flags swift_version
      swift_versions static_framework prepare_command script_phase script_phases default_subspec
      default_subspecs prefix_header_file prefix_header_contents deprecated deprecated_in_favor
      deprecated_in_favor_of cocoapods_version documentation_url social_media_url screenshots
      source_map readme changelog platforms test_type requires_app_host app_host_name scheme
      info_plist
    ].freeze
    CHILD_KINDS = { "subspecs" => :library, "testspecs" => :test, "appspecs" => :app }.freeze

    attr_reader :data

    def initialize(name = nil, parent = nil)
      @data = {}
      @data["name"] = name if name
      @parent = parent
      yield self if block_given?
      Pod.instance_variable_set(:@last_spec, self) unless parent
    end

    def name
      @parent ? @parent.name + "/" + @data["name"].to_s : @data["name"].to_s
    end

    def to_s
      name
    end

    def root
      @parent ? @parent.root : self
    end

    def parent
      @parent
    end

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
      subspecs << child
      child
    end

    def test_spec(name = "Tests")
      child = self.class.new(name, self)
      child.instance_variable_set(:@spec_kind, :test)
      child.data["test_type"] = "unit"
      yield child if block_given?
      subspecs << child
      child
    end

    def app_spec(name = "App")
      child = self.class.new(name, self)
      child.instance_variable_set(:@spec_kind, :app)
      yield child if block_given?
      subspecs << child
      child
    end

    def root?
      parent.nil?
    end

    def version
      root.data["version"] && Version.new(root.data["version"])
    end

    def library_specification?
      !test_specification? && !app_specification?
    end

    def test_specification?
      @spec_kind == :test
    end

    def app_specification?
      @spec_kind == :app
    end

    def test_specs
      children("testspecs")
    end

    def app_specs
      children("appspecs")
    end

    def recursive_subspecs(_include_non_library_specifications = false)
      subspecs.flat_map { |spec| [spec, *spec.recursive_subspecs] }
    end

    def default_subspecs
      values = Array(data["default_subspecs"] || data["default_subspec"])
      values.first.to_s == "none" ? :none : values
    end

    def subspec_by_name(name, raise_if_missing = true, include_non_library_specifications = false)
      return self if name.nil? || name == self.name || name == data["name"]
      absolute = name.start_with?(root.name + "/") ? name : self.name + "/" + name
      found = [self, *recursive_subspecs].find do |spec|
        spec.name == absolute && (include_non_library_specifications || spec.library_specification?)
      end
      raise Informative, "Unable to find specification #{name}" if !found && raise_if_missing
      found
    end

    def consumer(platform)
      input = platform.respond_to?(:name) ? platform.name : platform
      value = platform.is_a?(Pod::Platform) ? platform : Pod::Platform.new(input)
      raise Pod::Informative, "#{name} is not compatible with #{value.name}" unless supported_on_platform?(value.name)
      (@consumers ||= {})[value.name] ||= Consumer.new(self, value.name)
    end

    def children(key)
      kind = CHILD_KINDS.fetch(key)
      subspecs.select { |child| (child.instance_variable_get(:@spec_kind) || :library) == kind }
    end

    # All child kinds share one live collection, including specifications loaded
    # from JSON. Mutations made by podspec helpers must reach serialization.
    def subspecs
      @subspecs ||= CHILD_KINDS.flat_map do |key, kind|
        data.fetch(key, []).map do |attributes|
          self.class.new(nil, self).tap do |child|
            child.data.merge!(attributes)
            child.instance_variable_set(:@spec_kind, kind)
          end
        end
      end
    end

    class Consumer
      attr_reader :spec, :platform_name

      def initialize(spec, platform)
        @spec = spec
        input = platform.respond_to?(:name) ? platform.name : platform
        @platform_name = Pod::Platform.new(input).name
        raise Pod::Informative, "#{spec.name} is not compatible with #{platform}" unless spec.supported_on_platform?(platform.is_a?(Pod::Platform) ? platform : @platform_name)
      end

      def deployment_target
        spec.available_platforms.find { |platform| platform.name == platform_name }&.deployment_target&.to_s
      end
    end
  end

  Spec = Specification
end
