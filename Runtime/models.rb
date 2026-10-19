# frozen_string_literal: true

module Pod
  class PodTarget
    attr_reader :sandbox, :root_spec, :platform, :specs, :name, :pod_name, :target_definitions, :swift_version
    attr_accessor :native_target, :resource_bundle_targets, :test_native_targets, :app_native_targets

    def initialize(installer, entry)
      @installer = installer
      @sandbox = installer.sandbox
      @resource_bundle_targets = []
      @test_native_targets = []
      @app_native_targets = {}
      update!(entry)
    end

    def update!(entry)
      @name = entry.fetch("name")
      @pod_name = entry.fetch("pod_name")
      @root_spec = sandbox.specification(pod_name)
      @platform = Platform.new(entry.fetch("platform_name", "ios"), entry["deployment_target"])
      @specs = entry.fetch("spec_names", [pod_name]).map { |name| root_spec.subspec_by_name(name, true, true) }
      @target_definitions = if entry["consumer_keys"]
          entry["consumer_keys"].map { |key| @installer.podfile.analyzed_target_definitions.find { |definition| definition.label == key } }.compact
        else
          entry.fetch("consumer_targets", []).map { |name| @installer.podfile.target_definitions[name] }.compact
        end
      @swift_version = entry["swift_version"]
      @build_type = {
        "library" => BuildType.static_library, "static" => BuildType.static_framework,
        "dynamic" => BuildType.dynamic_framework,
      }.fetch(entry.fetch("build_type", "library"))
      @native_target = @installer.generated_projects.flat_map(&:native_targets).find { |target| target.name == self.name }
      incoming = entry.fetch("installation_result", {})
      @installation_result = nil if @installation_data != incoming
      @installation_data = incoming
      @resource_bundle_targets = resolve_targets(@installation_data.fetch("resource_bundle_targets", []))
      @test_native_targets = resolve_targets(@installation_data.fetch("test_targets", {}).values)
      @app_native_targets = @installation_data.fetch("app_targets", {}).to_h { |name, id| [root_spec.subspec_by_name(name, true, true), resolve_target(id)] }
      self
    end

    def resolve_target(id)
      @installer.generated_projects.filter_map { |project| project.object(id) if id && project.graph.fetch("objects", {}).key?(id) }.first
    end

    def resolve_targets(ids) = ids.filter_map { |id| resolve_target(id) }
    def library_specs = specs.select(&:library_specification?)
    def test_specs = specs.select(&:test_specification?)
    def app_specs = specs.select(&:app_specification?)

    def test_target_label(spec)
      label + "-" + (spec.test_type == :ui ? "UI" : "Unit") + "-" + spec.name.split("/").drop(1).join("-")
    end

    def app_target_label(spec) = label + "-" + spec.name.split("/").drop(1).join("-")

    def installation_result
      return @installation_result if @installation_result
      result_class = Pod::Installer::Xcode::PodsProjectGenerator::TargetInstallationResult
      test_bundles = @installation_data.fetch("test_resource_bundle_targets", {}).transform_values do |ids|
        resolve_targets(ids)
      end
      app_bundles = @installation_data.fetch("app_resource_bundle_targets", {}).transform_values do |ids|
        resolve_targets(ids)
      end
      @installation_result = result_class.new(
        self, native_target, resource_bundle_targets, test_native_targets, test_bundles,
        resolve_targets(@installation_data.fetch("test_app_host_targets", [])), app_native_targets, app_bundles
      )
    end

    def build_type = @build_type
    def label = name

    def file_accessors
      specs.map { |spec| FileAccessor.new(sandbox.pod_dir(pod_name), spec.consumer(platform)) }
    end

    def build_as_framework? = build_type.framework?
    def build_as_library? = build_type.library?
    def build_as_static? = build_type.static?
    def build_as_dynamic? = build_type.dynamic?
    def build_as_static_framework? = build_type.static_framework?
    def build_as_static_library? = build_type.static_library?
    def build_as_dynamic_framework? = build_type.dynamic_framework?

    def uses_swift?
      file_accessors.any? { |accessor| accessor.source_files.any? { |path| path.extname == ".swift" } }
    end

    def should_build? = file_accessors.any? { |accessor| !accessor.source_files.empty? }
    def product_module_name = root_spec.module_name

    def product_name
      build_as_framework? ? product_module_name + ".framework" : "lib" + label + ".a"
    end

    def support_files_dir = sandbox.root + "Target Support Files" + label
    def prefix_header_path = support_files_dir + (label + "-prefix.pch")

    def module_map_path
      config = native_target&.build_configurations&.first
      value = config&.build_settings&.fetch("MODULEMAP_FILE", nil)
      value ? Pathname(value) : support_files_dir + (product_module_name + ".modulemap")
    end

    def xcconfig_path(configuration)
      support_files_dir + (label + "." + configuration.to_s.downcase + ".xcconfig")
    end

    def to_native
      raise SwiftPods::Unsupported, "Dynamic libraries are not a supported pod build type" if build_type.dynamic_library?
      { "name" => name, "build_type" => build_type.library? ? "library" : build_type.linkage.to_s, "specification" => root_spec.to_hash }
    end
  end

  class AggregateTarget
    attr_reader :target_definition, :pod_targets, :user_project

    def initialize(definition, pods, project)
      update!(definition, pods, project)
    end

    def update!(definition, pods, project)
      @target_definition = definition
      @pod_targets = pods
      @user_project = project
      self
    end

    def name = target_definition.label

    alias label name

    def platform = target_definition.platform

    def user_target_uuids
      user_project ? user_project.native_targets.select { |target| target.name == target_definition.name }.map(&:uuid) : []
    end

    def user_targets = user_target_uuids.map { |uuid| user_project.object(uuid) }
    def requires_frameworks? = pod_targets.any?(&:build_as_framework?)
  end
end
