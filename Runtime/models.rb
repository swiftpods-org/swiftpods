# frozen_string_literal: true
# Public hook values. These describe Swift-owned targets; they do not resolve
# dependencies or generate projects in Ruby.
module Pod
  class Version < Gem::Version; end
  class Requirement < Gem::Requirement; end

  class Platform
    attr_reader :name, :deployment_target

    def initialize(name, deployment = nil)
      @name = name.to_sym; @deployment_target = deployment && Version.new(deployment)
    end

    def to_s = [self.class.string_name(name), deployment_target].compact.join(" ")

    def self.string_name(name) = { ios: "iOS", osx: "macOS", tvos: "tvOS", watchos: "watchOS", visionos: "visionOS" }.fetch(name.to_sym)

    def ==(other) = other.is_a?(Platform) && name == other.name && deployment_target == other.deployment_target

    alias eql? ==

    def hash = [name, deployment_target].hash
    def supports?(other) = name == other.name && (!deployment_target || !other.deployment_target || deployment_target >= other.deployment_target)
    def supports_dynamic_frameworks? = name != :ios || !deployment_target || deployment_target >= Version.new("8.0")
  end

  class BuildType
    attr_reader :linkage, :packaging

    def initialize(linkage: :static, packaging: :library)
      raise ArgumentError, "Unknown linkage or packaging" unless [:static, :dynamic].include?(linkage) && [:library, :framework].include?(packaging)
      @linkage = linkage; @packaging = packaging
    end

    def self.static_library = new
    def self.static_framework = new(packaging: :framework)
    def self.dynamic_framework = new(linkage: :dynamic, packaging: :framework)
    def self.dynamic_library = new(linkage: :dynamic)

    def static? = linkage == :static
    def dynamic? = linkage == :dynamic
    def framework? = packaging == :framework
    def library? = packaging == :library
    def static_library? = static? && library?
    def static_framework? = static? && framework?
    def dynamic_framework? = dynamic? && framework?
    def dynamic_library? = dynamic? && library?
    def to_hash = { linkage: linkage, packaging: packaging }
    def ==(other) = other.is_a?(BuildType) && to_hash == other.to_hash

    alias eql? ==

    def hash = to_hash.hash
  end

  class Specification
    def root? = parent.nil?
    def version = root.data["version"] && Version.new(root.data["version"])
    def module_name = data["module_name"] || root.data["header_dir"] || root.name.gsub(/[^a-zA-Z0-9_]/, "_")
    def library_specification? = !test_specification? && !app_specification?
    def test_specification? = @spec_kind == :test
    def app_specification? = @spec_kind == :app
    def subspecs = children("subspecs")
    def test_specs = children("testspecs")
    def app_specs = children("appspecs")

    def recursive_subspecs(include_non_library_specifications = false)
      selected = subspecs + (include_non_library_specifications ? test_specs + app_specs : [])
      selected.flat_map { |spec| [spec, *spec.recursive_subspecs(include_non_library_specifications)] }
    end

    def swift_version = Array(root.data["swift_versions"] || root.data["swift_version"]).first
    def swift_versions = Array(root.data["swift_versions"] || root.data["swift_version"]).map { |value| Version.new(value) }
    def default_subspecs = Array(data["default_subspecs"] || data["default_subspec"])
    def authors = data["authors"] || data["author"] || parent&.authors

    alias author authors

    def subspec_by_name(name, raise_if_missing = true, include_non_library_specifications = false)
      return self if name.nil? || name == self.name || name == data["name"]
      absolute = name.start_with?(root.name + "/") ? name : self.name + "/" + name
      found = [self, *recursive_subspecs(include_non_library_specifications)].find { |spec| spec.name == absolute && (include_non_library_specifications || spec.library_specification?) }
      raise Informative, "Unable to find specification #{name}" if !found && raise_if_missing
      found
    end

    def dependencies(platform = nil)
      inherited = parent ? parent.dependencies(platform) : []
      values = data.fetch("dependencies", {}).merge(platform ? data.fetch(platform.to_s, {}).fetch("dependencies", {}) : {})
      inherited + values.map { |name, versions| Dependency.new(name, *versions) }
    end

    def available_platforms
      values = root.data.fetch("platforms", {}).dup
      %w[ios osx tvos watchos visionos].each { |name| values[name] = root.data[name]["deployment_target"] if root.data[name]&.key?("deployment_target") }
      values.map { |name, version| Pod::Platform.new(name, version) }
    end

    def consumer(platform) = Consumer.new(self, platform)

    def children(key)
      @children ||= {}
      @children[key] ||= data.fetch(key, []).map { |attributes| self.class.new(nil, self).tap { |child| child.data.merge!(attributes); child.instance_variable_set(:@spec_kind, { "subspecs" => :library, "testspecs" => :test, "appspecs" => :app }.fetch(key)) } }
    end

    class Consumer
      attr_reader :spec, :platform_name

      def initialize(spec, platform); @spec = spec; @platform_name = platform.respond_to?(:name) ? platform.name : platform.to_sym; end

      def method_missing(name, *arguments)
        return super unless arguments.empty? && Specification::ATTRIBUTES.include?(name.to_s)
        key = name.to_s
        specific = spec.data.fetch(platform_name.to_s, {})
        specific.key?(key) ? specific[key] : spec.public_send(name)
      end

      def respond_to_missing?(name, _private = false) = Specification::ATTRIBUTES.include?(name.to_s) || super
      def dependencies = spec.dependencies(platform_name)
      def deployment_target = spec.available_platforms.find { |platform| platform.name == platform_name }&.deployment_target&.to_s
    end
  end

  class PodTarget
    attr_reader :sandbox, :root_spec, :platform, :specs, :name, :pod_name, :target_definitions, :swift_version
    attr_accessor :native_target, :resource_bundle_targets, :test_native_targets, :app_native_targets

    def initialize(installer, entry)
      @installer = installer; @sandbox = installer.sandbox
      @resource_bundle_targets = []; @test_native_targets = []; @app_native_targets = {}
      update!(entry)
    end

    def update!(entry)
      @name = entry.fetch("name"); @pod_name = entry.fetch("pod_name")
      @root_spec = sandbox.specification(pod_name)
      @platform = Platform.new(entry.fetch("platform_name", "ios"), entry["deployment_target"])
      @specs = entry.fetch("spec_names", [pod_name]).map { |name| root_spec.subspec_by_name(name, true, true) }
      @target_definitions = if entry["consumer_keys"]
          entry["consumer_keys"].map { |key| @installer.podfile.analyzed_target_definitions.find { |definition| definition.label == key } }.compact
        else
          entry.fetch("consumer_targets", []).map { |name| @installer.podfile.target_definitions[name] }.compact
        end
      @swift_version = entry["swift_version"]
      @build_type = { "library" => BuildType.static_library, "static" => BuildType.static_framework, "dynamic" => BuildType.dynamic_framework }.fetch(entry.fetch("build_type", "library"))
      @native_target = @installer.generated_projects.flat_map(&:native_targets).find { |target| target.name == self.name }
      incoming = entry.fetch("installation_result", {})
      @installation_result = nil if @installation_data != incoming
      @installation_data = incoming
      @resource_bundle_targets = resolve_targets(@installation_data.fetch("resource_bundle_targets", []))
      @test_native_targets = resolve_targets(@installation_data.fetch("test_targets", {}).values)
      @app_native_targets = @installation_data.fetch("app_targets", {}).to_h { |name, id| [root_spec.subspec_by_name(name, true, true), resolve_target(id)] }
      self
    end

    def resolve_target(id) = @installer.generated_projects.filter_map { |project| project.object(id) if id && project.graph.fetch("objects", {}).key?(id) }.first
    def resolve_targets(ids) = ids.filter_map { |id| resolve_target(id) }
    def library_specs = specs.select(&:library_specification?)
    def test_specs = specs.select(&:test_specification?)
    def app_specs = specs.select(&:app_specification?)
    def test_target_label(spec) = label + "-" + (spec.test_type == :ui ? "UI" : "Unit") + "-" + spec.name.split("/").drop(1).join("-")
    def app_target_label(spec) = label + "-" + spec.name.split("/").drop(1).join("-")

    def installation_result
      @installation_result ||= Pod::Installer::Xcode::PodsProjectGenerator::TargetInstallationResult.new(self, native_target, resource_bundle_targets, test_native_targets,
                                                                                                         @installation_data.fetch("test_resource_bundle_targets", {}).transform_values { |ids| resolve_targets(ids) },
                                                                                                         resolve_targets(@installation_data.fetch("test_app_host_targets", [])), app_native_targets,
                                                                                                         @installation_data.fetch("app_resource_bundle_targets", {}).transform_values { |ids| resolve_targets(ids) })
    end

    def build_type = @build_type
    def label = name
    def file_accessors = specs.map { |spec| FileAccessor.new(sandbox.pod_dir(pod_name), spec.consumer(platform)) }
    def build_as_framework? = build_type.framework?
    def build_as_library? = build_type.library?
    def build_as_static? = build_type.static?
    def build_as_dynamic? = build_type.dynamic?
    def build_as_static_framework? = build_type.static_framework?
    def build_as_static_library? = build_type.static_library?
    def build_as_dynamic_framework? = build_type.dynamic_framework?
    def uses_swift? = file_accessors.any? { |accessor| accessor.source_files.any? { |path| path.extname == ".swift" } }
    def should_build? = file_accessors.any? { |accessor| !accessor.source_files.empty? }
    def product_module_name = root_spec.module_name
    def product_name = build_as_framework? ? product_module_name + ".framework" : "lib" + product_module_name + ".a"
    def support_files_dir = sandbox.root + "Target Support Files" + label
    def prefix_header_path = support_files_dir + (label + "-prefix.pch")

    def module_map_path
      config = native_target&.build_configurations&.first
      value = config&.build_settings&.fetch("MODULEMAP_FILE", nil)
      value ? Pathname(value) : support_files_dir + (product_module_name + ".modulemap")
    end

    def xcconfig_path(configuration) = support_files_dir + (label + "." + configuration.to_s.downcase + ".xcconfig")

    def to_native
      raise SwiftPods::Unsupported, "Dynamic libraries are not a supported pod build type" if build_type.dynamic_library?
      { "name" => name, "build_type" => build_type.library? ? "library" : build_type.linkage.to_s, "specification" => root_spec.to_hash }
    end
  end

  class Sandbox::FileAccessor
    attr_reader :path_list, :spec_consumer
    ATTRIBUTES = %w[source_files exclude_files public_header_files private_header_files project_header_files requires_arc resources resource_bundles on_demand_resources preserve_paths vendored_frameworks vendored_libraries prefix_header_file module_map license].freeze
    PATH_ARRAYS = %w[source_files headers public_headers private_headers project_headers arc_source_files non_arc_source_files other_source_files resources preserve_paths vendored_frameworks vendored_libraries resource_bundle_files on_demand_resources_files vendored_frameworks_headers vendored_xcframeworks vendored_static_frameworks vendored_dynamic_frameworks vendored_static_xcframeworks vendored_dynamic_xcframeworks vendored_static_libraries vendored_dynamic_libraries vendored_static_artifacts vendored_dynamic_artifacts specs docs].freeze

    def initialize(path_list, consumer)
      raise Informative, "Attempt to initialize File Accessor without a specification consumer." unless consumer
      @path_list = path_list.respond_to?(:root) ? path_list : SwiftPods::Record.new(root: Pathname(path_list))
      @spec_consumer = consumer
    end

    def root = Pathname(path_list.root)
    def spec = spec_consumer.spec
    def platform_name = spec_consumer.platform_name
    def inspect = "<#{self.class} spec=#{spec.name} platform=#{platform_name} root=#{root}>"

    def query(operation, include_frameworks = false)
      attributes = ATTRIBUTES.to_h { |name| [name, spec_consumer.public_send(name)] }
      SwiftPods.callback("file_accessor", "root" => root.to_s, "attributes" => attributes, "operation" => operation, "include_frameworks" => include_frameworks).fetch("result")
    end

    PATH_ARRAYS.each do |name|
      define_method(name) { Array(query(name)).map { |value| Pathname(value) } }
    end

    def public_headers(include_frameworks = false) = Array(query("public_headers", include_frameworks)).map { |value| Pathname(value) }

    %w[prefix_header module_map license readme spec_license].each do |name|
      define_method(name) { (value = query(name)) && Pathname(value) }
    end

    def resource_bundles = query("resource_bundles").transform_values { |paths| paths.map { |path| Pathname(path) } }

    def on_demand_resources
      query("on_demand_resources").transform_values { |value| { paths: value.fetch("paths").map { |path| Pathname(path) }, category: value.fetch("category").to_sym } }
    end

    def developer_files = [*specs, prefix_header, module_map, license, readme, *docs].compact.uniq

    def self.all_files(accessors)
      accessors.flat_map { |accessor| [*accessor.source_files, *accessor.resources, *accessor.resource_bundle_files, *accessor.on_demand_resources_files, *accessor.preserve_paths, *accessor.vendored_frameworks, *accessor.vendored_libraries, accessor.license, accessor.readme, accessor.prefix_header, accessor.module_map] }.compact.uniq
    end
    def self.vendored_frameworks_headers_dir(framework)
      directory = Pathname(framework) + "Headers"
      directory.directory? ? directory.realpath : directory
    end
    def self.vendored_frameworks_headers(framework)
      framework = Pathname(framework).expand_path
      SwiftPods.callback("file_accessor", "root" => framework.dirname.to_s, "attributes" => { "vendored_frameworks" => [framework.basename.to_s] }, "operation" => "vendored_frameworks_headers").fetch("result").map { |path| Pathname(path) }
    end
  end

  FileAccessor = Sandbox::FileAccessor

  class AggregateTarget
    attr_reader :target_definition, :pod_targets, :user_project

    def initialize(definition, pods, project)
      update!(definition, pods, project)
    end

    def update!(definition, pods, project); @target_definition = definition; @pod_targets = pods; @user_project = project; self; end
    def name = target_definition.label

    alias label name

    def platform = target_definition.platform
    def user_target_uuids = user_project ? user_project.native_targets.select { |target| target.name == target_definition.name }.map(&:uuid) : []
    def user_targets = user_target_uuids.map { |uuid| user_project.object(uuid) }
    def requires_frameworks? = pod_targets.any?(&:build_as_framework?)
  end
end

module SwiftPods
  class TargetDefinition
    attr_reader :data, :parent, :children, :podfile

    def initialize(data, podfile); @data = data; @podfile = podfile; @children = []; end
    def update_tree!(parent, children); @parent = parent; @children.replace(children); self; end
    def root? = parent.equal?(podfile)
    def root = root? ? self : parent.root
    def recursive_children = (children + children.map(&:recursive_children)).flatten
    def name = data.fetch("name")
    def label = data["label"] || "Pods-" + name
    def to_s = label
    def platform = data["platform"] && Pod::Platform.new(data["platform"]["name"], data["platform"]["deployment_target"])
    def abstract? = data["abstract"] == true
    def uses_frameworks? = !!data["frameworks"]
    def user_project_path = data["project"]
    def build_configurations = data["configurations"]&.transform_values(&:to_sym)
    def script_phases = data.fetch("script_phases", []).map { |phase| Pod::Specification.convert_keys_to_symbol(phase).tap { |value| value[:execution_position] = value.fetch(:execution_position, :any).to_sym } }

    def inhibits_warnings_for_pod?(name)
      declaration = data.fetch("dependencies", []).find { |entry| entry["name"].split("/").first == name.split("/").first && entry.fetch("options", {}).key?("inhibit_warnings") }
      declaration ? declaration["options"]["inhibit_warnings"] : data["inhibit_warnings"] == true
    end

    def build_pod_as_module?(name)
      declaration = data.fetch("dependencies", []).find { |entry| entry["name"].split("/").first == name.split("/").first && entry.fetch("options", {}).key?("modular_headers") }
      declaration ? declaration["options"]["modular_headers"] : data["modular_headers"] == true
    end

    def swift_version = data["swift_version"]
    def swift_version_requirements = data.key?("own_swift_version_requirements") ? data["own_swift_version_requirements"] : data["swift_version_requirements"]
    def supports_swift_version?(value) = !data["swift_version_requirements"] || Pod::Requirement.new(*data["swift_version_requirements"]).satisfied_by?(Pod::Version.new(value))
    def dependencies = data.fetch("dependencies", []).map { |entry| Pod::Dependency.new(entry["name"], *entry["requirements"], entry["options"].select { |key, _| %w[path git branch tag commit podspec].include?(key) }.transform_keys(&:to_sym)) }
  end

  class Podfile
    TargetDefinition = SwiftPods::TargetDefinition

    def sources = data["sources"]
    def plugins = data["plugins"]
    def workspace_path = data["workspace"] && (data["workspace"].end_with?(".xcworkspace") ? data["workspace"] : data["workspace"] + ".xcworkspace")
    def generate_bridge_support? = data["generate_bridge_support"]
    def set_arc_compatibility_flag? = data["set_arc_compatibility_flag"]

    %w[pre_install pre_integrate post_install post_integrate].each { |name| define_method(name + "!") { |installer| hooks[name]&.call(installer); !!hooks[name] } }

    def analyzed_target_definitions
      target_definition_list
      (@analyzed_targets || to_hash.fetch("targets")).map { |entry| @definitions_by_identity.fetch(entry.fetch("_id")) }
    end

    def target_definition_list
      @definitions_by_identity ||= {}
      analyzed = (@analyzed_targets || []).to_h { |entry| [entry.fetch("_id"), entry] }
      raw = [data, *targets]
      definitions = raw.to_h do |entry|
        key = entry.equal?(data) ? :root : entry.fetch("_id")
        values = analyzed[key] || resolved(entry)
        values = values.merge("name" => "Pods", "abstract" => data.fetch("abstract", true), "_id" => "root") if key == :root
        definition = @definitions_by_identity[key] ||= TargetDefinition.new({}, self)
        definition.data.replace(values)
        [entry.object_id, definition]
      end
      raw.each do |entry|
        parent = entry.equal?(data) ? self : definitions.fetch(@parents.fetch(entry.object_id).object_id)
        children = targets.select { |child| @parents[child.object_id].equal?(entry) }.map { |child| definitions.fetch(child.object_id) }
        definitions.fetch(entry.object_id).update_tree!(parent, children)
      end
      root = definitions.fetch(data.object_id)
      [root, *root.recursive_children]
    end

    def root_target_definitions = [target_definition_list.first]
    def target_definitions = target_definition_list.to_h { |definition| [definition.name, definition] }
    def installation_options = Pod::Installer::InstallationOptions.from_podfile(self)
  end
end

class Pod::Installer
  def installation_options = @installation_options ||= podfile.installation_options
  def analysis_result = @analysis_result ||= SwiftPods::Record.new(pod_targets: pod_targets, targets: aggregate_targets, specifications: sandbox.specifications.values)

  def target_installation_results
    return nil unless %w[post_install post_integrate].include?(@hook_phase) && pods_project
    @target_installation_results ||= TargetInstallationResults.new({}, {})
    @target_installation_results.pod_target_installation_results.replace(pod_targets.to_h { |target| [target.name, target.installation_result] })
    @target_installation_results.aggregate_target_installation_results.replace(aggregate_targets.to_h do |target|
      native = [pods_project, *generated_projects].compact.flat_map(&:targets).find { |value| value.name == target.label }
      previous = @target_installation_results.aggregate_target_installation_results[target.label]
      value = previous && previous.target.equal?(target) && previous.native_target.equal?(native) ? previous : Pod::Installer::Xcode::PodsProjectGenerator::TargetInstallationResult.new(target, native)
      [target.label, value]
    end)
    @target_installation_results
  end

  alias installation_results target_installation_results

  def update_targets!(entries)
    sandbox.directories = entries.to_h { |entry| [entry.fetch("pod_name"), entry["root"]] }
    sandbox.instance_variable_set(:@development_pods, entries.select { |entry| entry["local"] }.to_h { |entry| [entry.fetch("pod_name"), Pathname(entry.fetch("root"))] })
    entries.each do |entry|
      name = entry.fetch("pod_name")
      spec = sandbox.specifications[name] ||= Pod::Spec.from_hash(entry.fetch("specification", {}))
      spec.defined_in_file = sandbox.specification_path(name)
    end
    previous = pod_targets.to_h { |target| [target.name, target] }
    self.pod_targets = entries.map { |entry| previous[entry["name"]]&.update!(entry) || Pod::PodTarget.new(self, entry) }
    @analysis_result = nil
    @user_projects ||= {}
    previous_aggregates = aggregate_targets.to_h { |target| [[target.target_definition.data["_id"], target.name], target] }
    self.aggregate_targets = podfile.analyzed_target_definitions.map do |definition|
      user = if @integrate_user_projects && definition.data["project"] && File.directory?(definition.data["project"])
          path = File.expand_path(definition.data["project"])
          incoming = SwiftPods.callback("open_project", "path" => File.expand_path(path))
          @user_projects[path]&.update!(incoming) || (@user_projects[path] = Xcodeproj::Project.new(incoming))
        end
      pods = pod_targets.select { |pod| pod.target_definitions.any? { |target| target.equal?(definition) } }
      previous_aggregates[[definition.data["_id"], definition.label]]&.update!(definition, pods, user) || Pod::AggregateTarget.new(definition, pods, user)
    end
  end

  def user_projects = (@user_projects || {}).values
end

require_relative "installation_results"

class Pod::Sandbox
  def development_pods = @development_pods || {}
  def local?(name) = development_pods.key?(name.split("/").first)
  def manifest_path = root + "Manifest.lock"
  def manifest = manifest_path.file? ? Pod::Lockfile.from_file(manifest_path) : nil
  def specifications_root = root + "Local Podspecs"
  def specification_path(name) = specifications_root + (name.split("/").first + ".podspec.json")
end

class Pod::Lockfile
  attr_reader :internal_data

  def initialize(data); @internal_data = data; end

  def self.from_file(path) = new(YAML.safe_load(File.read(path), permitted_classes: [Symbol], aliases: false))

  def to_hash = internal_data
  def podfile_checksum = internal_data["PODFILE CHECKSUM"]
  def pod_names = versions.keys

  def versions
    internal_data.fetch("PODS", []).to_h do |entry|
      value = entry.is_a?(Hash) ? entry.keys.first : entry
      match = value.match(/\A(.+?) \(([^ )]+)(?:[ )])/)
      [match[1], Pod::Version.new(match[2])]
    end
  end

  def version(name) = versions[name]
end
