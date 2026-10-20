# frozen_string_literal: true

module Pod
  class Informative < StandardError
  end

  class Installer
    class InstallationOptions
      DEFAULTS = {
        "clean" => true, "deduplicate_targets" => true, "deterministic_uuids" => true,
        "integrate_targets" => true, "lock_pod_sources" => true,
        "warn_for_multiple_pod_sources" => true, "warn_for_unused_master_specs_repo" => true,
        "share_schemes_for_development_pods" => false, "disable_input_output_paths" => false,
        "preserve_pod_file_structure" => false, "generate_multiple_pod_projects" => false,
        "incremental_installation" => false, "skip_pods_project_generation" => false,
        "parallel_pod_downloads" => false, "parallel_pod_download_thread_pool_size" => 40,
      }.freeze
      def self.defaults
        DEFAULTS
      end

      def self.all_options
        DEFAULTS.keys
      end

      def self.from_podfile(podfile)
        new(podfile.data.fetch("options", {}))
      end

      def initialize(options = {})
        options = options.transform_keys(&:to_s)
        unknown = options.keys - DEFAULTS.keys
        raise Informative, "Unknown installation options: #{unknown.join(", ")}" unless unknown.empty?
        @values = DEFAULTS.merge(options)
      end

      DEFAULTS.each_key do |name|
        define_method(name) { @values[name] }
        define_method(name + "?") { @values[name] } unless name == "parallel_pod_download_thread_pool_size"
        define_method(name + "=") { |value| @values[name] = value }
      end

      def to_h(include_defaults: true)
        include_defaults ? @values.dup : @values.reject { |key, value| DEFAULTS[key] == value }
      end

      def ==(other)
        other.is_a?(self.class) && to_h == other.to_h
      end

      alias eql? ==

      def hash
        to_h.hash
      end
    end
  end
end
