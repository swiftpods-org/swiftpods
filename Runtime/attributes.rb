# frozen_string_literal: true
module Pod
  class Specification
    module DSL
      class Attribute
        attr_reader :name, :metadata
        def initialize(name, metadata); @name = name.to_sym; @metadata = metadata; end
        def container = metadata['container'] && Object.const_get(metadata['container'])
        def types = metadata['types'].map { |name| Object.const_get(name) }
        def supported_types = [*types, container].compact
        def root_only? = metadata['root_only']
        def multi_platform? = metadata['multi_platform']
        def inherited? = metadata['inherited']
        def default_value = metadata['default']
        def writer_name = name.to_s + '='
        def writer_singular_form = metadata['singular'] && metadata['singular'] + '='
      end
      CONTRACT = JSON.parse(File.read(File.join(__dir__, 'attributes.json'))).freeze
      def self.attributes = @attributes ||= CONTRACT.to_h { |name, metadata| [name.to_sym, Attribute.new(name, metadata)] }
    end
    ALIASES = DSL::CONTRACT.filter_map { |name, metadata| [metadata['singular'], name] if metadata['singular'] }.to_h.freeze
    attr_accessor :defined_in_file
    def attributes_hash = data
    def store_attribute(name, value, platform = nil)
      name = name.to_s
      value = self.class.convert_keys_to_string(value) if value.is_a?(Hash)
      if value.is_a?(String)
        indentation = value.lines.reject { |line| line.strip.empty? }.map { |line| line[/\A */].size }.min || 0
        value = value.gsub(/^ {0,#{indentation}}/, '').strip
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
    def module_name = root.data['module_name'] || root.data['header_dir'] || root.name.gsub(/[^a-zA-Z0-9_]/, '_').sub(/\A(?=[0-9])/, '_')
    def swift_versions = (Array(root.data['swift_versions']) + Array(root.data['swift_version'])).map { |value| Version.new(value) }.uniq.sort
    def swift_version = swift_versions.last
    def authors
      values = root.data['authors'] || root.data['author']
      return values if values.is_a?(Hash)
      Array(values).each_with_object({}) { |value, result| value.is_a?(Hash) ? result.merge!(value) : result[value] = nil }
    end
    alias author authors
    def license
      value = root.data['license']; value.is_a?(String) ? {'type' => value} : value
    end
    def cocoapods_version = Requirement.new(root.data['cocoapods_version'] || '>= 0')
    def subspecs = children('subspecs') + children('testspecs') + children('appspecs')
    def available_platforms
      values = data['platforms']
      values = values.is_a?(Hash) ? values : Array(values).to_h { |name| [name.to_s, nil] }
      values = parent ? parent.available_platforms.to_h { |platform| [platform.name.to_s, platform.deployment_target&.to_s] } : %w[osx ios tvos visionos watchos].to_h { |name| [name, nil] } if values.empty?
      values.map { |name, version| Pod::Platform.new(name, version) }
    end
    def deployment_target(platform) = available_platforms.find { |value| value.name == platform.to_sym }&.deployment_target&.to_s
    def supported_on_platform?(platform)
      value = platform.is_a?(Pod::Platform) ? platform : Pod::Platform.new(platform)
      available_platforms.any? { |supported| value.supports?(supported) }
    end
    def spec_type = test_specification? ? :test : app_specification? ? :app : :library
    def non_library_specification? = !library_specification?
    def checksum = root.defined_in_file && Digest::SHA1.file(root.defined_in_file).hexdigest
    def dependencies(platform = nil)
      platforms = platform ? [platform] : available_platforms
      platforms.flat_map { |value| consumer(value).dependencies }.uniq
    end
    def all_dependencies(platform = nil) = dependencies(platform) + subspecs.flat_map { |spec| spec.all_dependencies(platform) }
    def to_hash
      value = data.dup
      if root? || available_platforms != parent.available_platforms
        value['platforms'] = available_platforms.to_h { |platform| [platform.name.to_s, platform.deployment_target&.to_s] }
      end
      %w[subspecs testspecs appspecs].each { |key| value.delete(key) }
      {'testspecs' => test_specs, 'appspecs' => app_specs, 'subspecs' => children('subspecs')}.each { |key, specs| value[key] = specs.map(&:to_hash) unless specs.empty? }
      value.delete('swift_version'); value['swift_version'] = swift_version.to_s if swift_version
      value
    end
    def to_json(*arguments) = JSON.dump(to_hash, *arguments) + "\n"
    def to_pretty_json(*arguments) = JSON.pretty_generate(to_hash, *arguments) + "\n"
    def method_missing(method, *arguments)
      key = method.to_s
      return DSL::PlatformProxy.new(self, key.to_sym) if %w[ios osx tvos watchos visionos].include?(key) && arguments.empty?
      if key == 'platform='
        name, minimum = arguments.first
        return store_attribute('platforms', name.to_s => minimum)
      end
      canonical = ALIASES.fetch(key.delete_suffix('='), key.delete_suffix('='))
      attribute = DSL.attributes[canonical.to_sym]
      return super unless attribute
      if key.end_with?('=')
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
    def respond_to_missing?(method, _private = false) = DSL.attributes.key?(ALIASES.fetch(method.to_s.delete_suffix('='), method.to_s.delete_suffix('=')).to_sym) || %w[ios osx tvos watchos visionos].include?(method.to_s) || super
    module DSL
      class PlatformProxy
        attr_reader :spec, :platform
        def initialize(spec, platform); @spec = spec; @platform = platform; end
        def deployment_target=(value)
          (spec.data['platforms'] ||= {})[platform.to_s] = value
        end
        def dependency(name, *requirements)
          ((spec.data[platform.to_s] ||= {})['dependencies'] ||= {})[name] = requirements.flatten
        end
        def method_missing(method, *arguments)
          canonical = Specification::ALIASES.fetch(method.to_s.delete_suffix('='), method.to_s.delete_suffix('='))
          attribute = DSL.attributes[canonical.to_sym]
          return super unless attribute && method.to_s.end_with?('=')
          raise NoMethodError, "#{canonical} cannot be set per-platform" unless attribute.multi_platform?
          spec.store_attribute(canonical, arguments.fetch(0), platform)
        end
        def respond_to_missing?(method, _private = false)
          attribute = DSL.attributes[Specification::ALIASES.fetch(method.to_s.delete_suffix('='), method.to_s.delete_suffix('=')).to_sym]
          (attribute && attribute.multi_platform?) || super
        end
      end
    end
    class Consumer
      def pod_target_xcconfig = merge(effective(spec, DSL.attributes.fetch(:xcconfig)), effective(spec, DSL.attributes.fetch(:pod_target_xcconfig)), DSL.attributes.fetch(:pod_target_xcconfig)) || {}
      def user_target_xcconfig = merge(effective(spec, DSL.attributes.fetch(:xcconfig)), effective(spec, DSL.attributes.fetch(:user_target_xcconfig)), DSL.attributes.fetch(:user_target_xcconfig)) || {}
      def dependencies
        attribute = DSL.attributes.fetch(:dependencies)
        (effective(spec, attribute) || {}).map { |name, versions| Dependency.new(name, *Array(versions)) }
      end
      def respond_to_missing?(method, _private = false)
        return false if %w[platforms default_subspecs xcconfig].include?(method.to_s)
        DSL.attributes.key?(method.to_s.delete_suffix('?').to_sym) || super
      end
      def method_missing(method, *arguments)
        name = method.to_s.delete_suffix('?')
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
          return old.merge(value) do |_, first, last|
            if attribute.name == :info_plist || spec.non_library_specification? && %i[xcconfig pod_target_xcconfig user_target_xcconfig].include?(attribute.name)
              last
            elsif first.is_a?(Array) || last.is_a?(Array)
              Array(first) + Array(last)
            else
              first.to_s + ' ' + last.to_s
            end
          end
        end
        value
      end
      def prepare(value, attribute)
        value = value.is_a?(Hash) ? [value] : Array(value).compact if attribute.container == Array
        case attribute.name
        when :prefix_header_contents then value.is_a?(Array) ? value.join("\n").chomp : value&.chomp
        when :test_type then value&.to_sym
        when :scheme then value && Specification.convert_keys_to_symbol(value, recursive: false)
        when :resource_bundles then value&.transform_values { |paths| Array(paths).compact }
        when :on_demand_resources
          value&.transform_values do |raw|
            entry = raw.is_a?(Hash) ? Specification.convert_keys_to_symbol(raw, recursive: false) : {paths: raw}
            {paths: Array(entry[:paths]).compact, category: entry.fetch(:category, :download_on_demand).to_sym}
          end
        when :script_phases
          value&.map { |raw| Specification.convert_keys_to_symbol(raw).tap { |entry| entry[:execution_position] = entry.fetch(:execution_position, :any).to_sym } }
        else value
        end
      end
    end
  end
end
