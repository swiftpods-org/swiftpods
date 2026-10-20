# frozen_string_literal: true

module Pod
  class Specification
    module DSL
      class Attribute
        attr_reader :name, :metadata

        def initialize(name, metadata)
          @name = name.to_sym
          @metadata = metadata
        end

        def container
          metadata["container"] && Object.const_get(metadata["container"])
        end

        def types
          metadata["types"].map { |name| Object.const_get(name) }
        end

        def supported_types
          [*types, container].compact
        end

        def root_only?
          metadata["root_only"]
        end

        def multi_platform?
          metadata["multi_platform"]
        end

        def inherited?
          metadata["inherited"]
        end

        def default_value
          metadata["default"]
        end

        def writer_name
          name.to_s + "="
        end

        def writer_singular_form
          metadata["singular"] && metadata["singular"] + "="
        end
      end

      CONTRACT = JSON.parse(File.read(File.join(__dir__, "attributes.json"))).freeze
      def self.attributes
        @attributes ||= CONTRACT.to_h { |name, metadata| [name.to_sym, Attribute.new(name, metadata)] }
      end
    end

    ALIASES = DSL::CONTRACT.each_with_object({}) do |(name, metadata), aliases|
      aliases[metadata["singular"]] = name if metadata["singular"]
    end.freeze
    attr_accessor :defined_in_file

    def attributes_hash
      data
    end

    def store_attribute(name, value, platform = nil)
      name = name.to_s
      value = self.class.convert_keys_to_string(value) if value.is_a?(Hash)
      if value.is_a?(String)
        indentation = value.lines.reject { |line| line.strip.empty? }.map { |line| line[/\A */].size }.min || 0
        value = value.gsub(/^ {0,#{indentation}}/, "").strip
      end
      if platform
        (data[platform.to_s] ||= {})[name] = value
      else
        data[name] = value
      end
    end

    def self.convert_keys_to_string(value, recursive: true)
      value.to_h { |key, item| [key.to_s, recursive && item.is_a?(Hash) ? convert_keys_to_string(item) : item] }
    end

    def self.convert_keys_to_symbol(value, recursive: true)
      value.to_h { |key, item| [key.to_sym, recursive && item.is_a?(Hash) ? convert_keys_to_symbol(item) : item] }
    end

    def module_name
      return root.data["module_name"] if root.data["module_name"]
      SwiftPods::ModuleIdentifier.normalize(root.data["header_dir"] || root.name)
    end

    def swift_versions
      (Array(root.data["swift_versions"]) + Array(root.data["swift_version"])).map { |value| Version.new(value) }.uniq.sort
    end

    def swift_version
      swift_versions.last
    end

    def test_type
      (data["test_type"] || ("unit" if test_specification?))&.to_sym
    end

    def authors
      values = root.data["authors"] || root.data["author"]
      return nil if values.nil?
      return values if values.is_a?(Hash)
      Array(values).each_with_object({}) { |value, result| value.is_a?(Hash) ? result.merge!(value) : result[value] = nil }
    end

    alias author authors

    def license
      value = root.data["license"]
      return { type: value } if value.is_a?(String)
      return {} unless value.is_a?(Hash)
      result = Specification.convert_keys_to_symbol(value)
      if result[:text].is_a?(String)
        indentation = result[:text].lines.reject { |line| line.strip.empty? }.map { |line| line[/\A */].size }.min || 0
        result[:text] = result[:text].gsub(/^ {0,#{indentation}}/, "")
      end
      result
    end

    def source
      value = root.data["source"]
      value.is_a?(Hash) ? Specification.convert_keys_to_symbol(value) : value
    end

    def base_name
      data["name"]
    end

    def requires_arc
      data["requires_arc"]
    end

    def screenshots
      Array(root.data["screenshots"])
    end

    def static_framework
      root.data["static_framework"]
    end

    def deprecated
      root.data["deprecated"]
    end

    def deprecated?
      deprecated || !root.data["deprecated_in_favor_of"].nil?
    end

    def prepare_command
      value = root.data["prepare_command"]
      return nil if value.nil?
      indentation = value.lines.reject { |line| line.strip.empty? }.map { |line| line[/\A */].size }.min || 0
      value.gsub(/^ {0,#{indentation}}/, "").chomp
    end

    def cocoapods_version
      Requirement.new(root.data["cocoapods_version"] || ">= 0")
    end

    def available_platforms
      names = platform_requirements.keys
      if names.empty?
        names = parent ? parent.available_platforms.map(&:name) : %w[osx ios tvos visionos watchos]
      end
      names.map { |name| Pod::Platform.new(name, deployment_target(name)) }
    end

    def platform_requirements
      values = data["platforms"]
      values.is_a?(Hash) ? values : Array(values).to_h { |name| [name.to_s, nil] }
    end

    private :platform_requirements

    def deployment_target(platform)
      platform_requirements[platform.to_s] || parent&.deployment_target(platform)
    end

    def supported_on_platform?(platform)
      value = platform.is_a?(Pod::Platform) ? platform : Pod::Platform.new(platform)
      available_platforms.any? { |supported| value.supports?(supported) }
    end

    def spec_type
      test_specification? ? :test : app_specification? ? :app : :library
    end

    def non_library_specification?
      !library_specification?
    end

    def checksum
      root.defined_in_file && Digest::SHA1.file(root.defined_in_file).hexdigest
    end

    def dependencies(platform = nil)
      platforms = platform ? [platform] : available_platforms
      platforms.flat_map { |value| consumer(value).dependencies }.uniq
    end

    def subspec_dependencies(platform = nil)
      selection = default_subspecs
      selected = if selection == :none
          []
        elsif selection.empty?
          subspecs.reject(&:non_library_specification?)
        else
          selection.map { |subspec| root.subspec_by_name(name + "/" + subspec.to_s) }
        end
      selected = selected.select { |spec| spec.supported_on_platform?(platform) } if platform
      selected.map { |spec| Dependency.new(spec.name, version) }
    end

    def all_dependencies(platform = nil)
      dependencies(platform) + subspec_dependencies(platform)
    end

    def to_hash
      value = data.dup
      if root? || available_platforms != parent.available_platforms
        value["platforms"] = available_platforms.to_h { |platform| [platform.name.to_s, platform.deployment_target&.to_s] }
      end
      %w[subspecs testspecs appspecs].each { |key| value.delete(key) }
      { "testspecs" => test_specs, "appspecs" => app_specs, "subspecs" => children("subspecs") }.each { |key, specs| value[key] = specs.map(&:to_hash) unless specs.empty? }
      value.delete("swift_version")
      value["swift_version"] = swift_version.to_s if swift_version
      value
    end

    def to_json(*arguments)
      JSON.dump(to_hash, *arguments) + "\n"
    end

    def to_pretty_json(*arguments)
      JSON.pretty_generate(to_hash, *arguments) + "\n"
    end

    def method_missing(method, *arguments)
      key = method.to_s
      return DSL::PlatformProxy.new(self, key.to_sym) if %w[ios osx tvos watchos visionos].include?(key) && arguments.empty?
      if key == "platform="
        name, minimum = arguments.first
        return store_attribute("platforms", name.to_s => minimum)
      end
      canonical = ALIASES.fetch(key.delete_suffix("="), key.delete_suffix("="))
      attribute = DSL.attributes[canonical.to_sym]
      return super unless attribute
      if key.end_with?("=")
        value = arguments.fetch(0)
        store_attribute(canonical, value)
      elsif arguments.empty?
        value = data[canonical]
        value = parent.public_send(canonical) if value.nil? && parent && attribute.root_only?
        value.nil? ? attribute.default_value : value
      else
        super
      end
    end

    def respond_to_missing?(method, _private = false)
      DSL.attributes.key?(ALIASES.fetch(method.to_s.delete_suffix("="), method.to_s.delete_suffix("=")).to_sym) || %w[ios osx tvos watchos visionos].include?(method.to_s) || super
    end

    module DSL
      class PlatformProxy
        attr_reader :spec, :platform

        def initialize(spec, platform)
          @spec = spec
          @platform = platform
        end

        def deployment_target=(value)
          (spec.data["platforms"] ||= {})[platform.to_s] = value
        end

        def dependency(name, *requirements)
          ((spec.data[platform.to_s] ||= {})["dependencies"] ||= {})[name] = requirements.flatten
        end

        def method_missing(method, *arguments)
          canonical = Specification::ALIASES.fetch(method.to_s.delete_suffix("="), method.to_s.delete_suffix("="))
          attribute = DSL.attributes[canonical.to_sym]
          return super unless attribute && method.to_s.end_with?("=")
          raise NoMethodError, "#{canonical} cannot be set per-platform" unless attribute.multi_platform?
          spec.store_attribute(canonical, arguments.fetch(0), platform)
        end

        def respond_to_missing?(method, _private = false)
          attribute = DSL.attributes[Specification::ALIASES.fetch(method.to_s.delete_suffix("="), method.to_s.delete_suffix("=")).to_sym]
          (attribute && attribute.multi_platform?) || super
        end
      end
    end

    class Consumer
      %i[base_name version swift_version swift_versions cocoapods_version authors license source screenshots
         static_framework deprecated deprecated? prepare_command].each do |name|
        define_method(name) { spec.root.public_send(name) }
      end

      def test_type
        effective(spec, DSL.attributes.fetch(:test_type)) || (:unit if spec.test_specification?)
      end

      def pod_target_xcconfig
        effective_xcconfig(:pod_target_xcconfig)
      end

      def user_target_xcconfig
        effective_xcconfig(:user_target_xcconfig)
      end

      def effective_xcconfig(name)
        legacy = effective(spec, DSL.attributes.fetch(:xcconfig))
        attribute = DSL.attributes.fetch(name)
        merge(legacy, effective(spec, attribute), attribute) || {}
      end

      private :effective_xcconfig

      def dependencies
        attribute = DSL.attributes.fetch(:dependencies)
        (effective(spec, attribute) || {}).map { |name, versions| Dependency.new(name, *Array(versions)) }
      end

      def respond_to_missing?(method, _private = false)
        return false if %w[platforms default_subspecs xcconfig].include?(method.to_s)
        DSL.attributes.key?(method.to_s.delete_suffix("?").to_sym) || super
      end

      def method_missing(method, *arguments)
        name = method.to_s.delete_suffix("?")
        attribute = DSL.attributes[name.to_sym]
        return super unless arguments.empty? && attribute
        value = effective(spec, attribute)
        value = attribute.default_value if value.nil?
        value = attribute.container.new if value.nil? && attribute.container
        value
      end

      def effective(spec, attribute)
        name = attribute.name.to_s
        value = prepare(spec.data[name], attribute)
        value = merge(value, prepare(spec.data.fetch(platform_name.to_s, {})[name], attribute), attribute) if attribute.multi_platform?
        value = merge(effective(spec.parent, attribute), value, attribute) if spec.parent && attribute.inherited?
        value
      end

      def merge(old, value, attribute)
        return old if value.nil?
        return value if old.nil?
        return value if attribute.types.include?(TrueClass)
        return Array(old) + Array(value) if attribute.container == Array
        if attribute.container == Hash
          return old.merge(value) { |_, first, last| merge_hash_value(first, last, attribute) }
        end
        value
      end

      def merge_hash_value(first, last, attribute)
        xcconfig = %i[xcconfig pod_target_xcconfig user_target_xcconfig].include?(attribute.name)
        if attribute.name == :info_plist || (spec.non_library_specification? && xcconfig)
          last
        elsif first.is_a?(Array) || last.is_a?(Array)
          Array(first) + Array(last)
        else
          first.to_s + " " + last.to_s
        end
      end

      private :merge_hash_value

      def prepare(value, attribute)
        value = value.is_a?(Hash) ? [value] : Array(value).compact if attribute.container == Array
        case attribute.name
        when :prefix_header_contents then value.is_a?(Array) ? value.join("\n").chomp : value&.chomp
        when :test_type then value&.to_sym
        when :scheme then value && Specification.convert_keys_to_symbol(value, recursive: false)
        when :resource_bundles then value&.transform_values { |paths| Array(paths).compact }
        when :on_demand_resources
          value&.transform_values do |raw|
            entry = raw.is_a?(Hash) ? Specification.convert_keys_to_symbol(raw, recursive: false) : { paths: raw }
            { paths: Array(entry[:paths]).compact, category: entry.fetch(:category, :download_on_demand).to_sym }
          end
        when :script_phases
          value&.map { |raw| Specification.convert_keys_to_symbol(raw).tap { |entry| entry[:execution_position] = entry.fetch(:execution_position, :any).to_sym } }
        else value
        end
      end
    end
  end
end
