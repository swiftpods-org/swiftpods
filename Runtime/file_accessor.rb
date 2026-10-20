# frozen_string_literal: true

module Pod
  class Sandbox::FileAccessor
    attr_reader :path_list, :spec_consumer
    ATTRIBUTES = %w[
      source_files exclude_files public_header_files private_header_files project_header_files
      requires_arc resources resource_bundles on_demand_resources preserve_paths vendored_frameworks
      vendored_libraries prefix_header_file module_map license
    ].freeze
    PATH_ARRAYS = %w[
      source_files headers public_headers private_headers project_headers arc_source_files
      non_arc_source_files other_source_files resources preserve_paths vendored_frameworks
      vendored_libraries resource_bundle_files on_demand_resources_files vendored_frameworks_headers
      vendored_xcframeworks vendored_static_frameworks vendored_dynamic_frameworks
      vendored_static_xcframeworks vendored_dynamic_xcframeworks vendored_static_libraries
      vendored_dynamic_libraries vendored_static_artifacts vendored_dynamic_artifacts specs docs
    ].freeze

    def initialize(path_list, consumer)
      raise Informative, "Attempt to initialize File Accessor without a specification consumer." unless consumer
      @path_list = path_list.respond_to?(:root) ? path_list : SwiftPods::Record.new(root: Pathname(path_list))
      @spec_consumer = consumer
    end

    def root
      Pathname(path_list.root)
    end

    def spec
      spec_consumer.spec
    end

    def platform_name
      spec_consumer.platform_name
    end

    def inspect
      "<#{self.class} spec=#{spec.name} platform=#{platform_name} root=#{root}>"
    end

    def query(operation, include_frameworks = false)
      attributes = ATTRIBUTES.to_h { |name| [name, spec_consumer.public_send(name)] }
      SwiftPods.callback("file_accessor", {
        "root" => root.to_s, "attributes" => attributes, "operation" => operation,
        "include_frameworks" => include_frameworks,
      }).fetch("result")
    end

    PATH_ARRAYS.each do |name|
      define_method(name) { Array(query(name)).map { |value| Pathname(value) } }
    end

    def public_headers(include_frameworks = false)
      Array(query("public_headers", include_frameworks)).map { |value| Pathname(value) }
    end

    %w[prefix_header module_map license readme spec_license].each do |name|
      define_method(name) { (value = query(name)) && Pathname(value) }
    end

    def resource_bundles
      query("resource_bundles").transform_values { |paths| paths.map { |path| Pathname(path) } }
    end

    def on_demand_resources
      query("on_demand_resources").transform_values do |value|
        { paths: value.fetch("paths").map { |path| Pathname(path) }, category: value.fetch("category").to_sym }
      end
    end

    def developer_files
      [*specs, prefix_header, module_map, license, readme, *docs].compact.uniq
    end

    def self.all_files(accessors)
      accessors.flat_map do |accessor|
        [
          *accessor.source_files, *accessor.resources, *accessor.resource_bundle_files,
          *accessor.on_demand_resources_files, *accessor.preserve_paths, *accessor.vendored_frameworks,
          *accessor.vendored_libraries, accessor.license, accessor.readme, accessor.prefix_header, accessor.module_map,
        ]
      end.compact.uniq
    end

    def self.vendored_frameworks_headers_dir(framework)
      directory = Pathname(framework) + "Headers"
      directory.directory? ? directory.realpath : directory
    end

    def self.vendored_frameworks_headers(framework)
      framework = Pathname(framework).expand_path
      response = SwiftPods.callback("file_accessor", {
        "root" => framework.dirname.to_s, "attributes" => { "vendored_frameworks" => [framework.basename.to_s] },
        "operation" => "vendored_frameworks_headers",
      })
      response.fetch("result").map { |path| Pathname(path) }
    end
  end

  FileAccessor = Sandbox::FileAccessor
end
