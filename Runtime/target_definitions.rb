# frozen_string_literal: true

module SwiftPods
  class TargetDefinition
    attr_reader :data, :parent, :children, :podfile

    def initialize(data, podfile)
      @data = data
      @podfile = podfile
      @children = []
    end

    def update_tree!(parent, children)
      @parent = parent
      @children.replace(children)
      self
    end

    def root?
      parent.equal?(podfile)
    end

    def root
      root? ? self : parent.root
    end

    def recursive_children
      (children + children.map(&:recursive_children)).flatten
    end

    def name
      data.fetch("name")
    end

    def label
      data["label"] || "Pods-" + name
    end

    def to_s
      label
    end

    def platform
      data["platform"] && Pod::Platform.new(data["platform"]["name"], data["platform"]["deployment_target"])
    end

    def abstract?
      data["abstract"] == true
    end

    def uses_frameworks?
      !!data["frameworks"]
    end

    def user_project_path
      data["project"]
    end

    def build_configurations
      data["configurations"]&.transform_values(&:to_sym)
    end

    def script_phases
      data.fetch("script_phases", []).map do |phase|
        Pod::Specification.convert_keys_to_symbol(phase).tap do |value|
          value[:execution_position] = value.fetch(:execution_position, :any).to_sym
        end
      end
    end

    def inhibits_warnings_for_pod?(name)
      declaration = dependency_with_option(name, "inhibit_warnings")
      declaration ? declaration["options"]["inhibit_warnings"] : data["inhibit_warnings"] == true
    end

    def build_pod_as_module?(name)
      declaration = dependency_with_option(name, "modular_headers")
      declaration ? declaration["options"]["modular_headers"] : data["modular_headers"] == true
    end

    def dependency_with_option(name, option)
      data.fetch("dependencies", []).find do |entry|
        entry["name"].split("/").first == name.split("/").first && entry.fetch("options", {}).key?(option)
      end
    end

    private :dependency_with_option

    def swift_version
      data["swift_version"]
    end

    def swift_version_requirements
      data.key?("own_swift_version_requirements") ? data["own_swift_version_requirements"] : data["swift_version_requirements"]
    end

    def supports_swift_version?(value)
      !data["swift_version_requirements"] || Pod::Requirement.new(*data["swift_version_requirements"]).satisfied_by?(Pod::Version.new(value))
    end

    def dependencies
      data.fetch("dependencies", []).map { |entry| Pod::Dependency.from_manifest(entry) }
    end
  end

  class Podfile
    TargetDefinition = SwiftPods::TargetDefinition

    def sources
      data["sources"]
    end

    def plugins
      data["plugins"]
    end

    def workspace_path
      data["workspace"] && (data["workspace"].end_with?(".xcworkspace") ? data["workspace"] : data["workspace"] + ".xcworkspace")
    end

    def generate_bridge_support?
      data["generate_bridge_support"]
    end

    def set_arc_compatibility_flag?
      data["set_arc_compatibility_flag"]
    end

    %w[pre_install pre_integrate post_install post_integrate].each { |name|
      define_method(name + "!") { |installer|
        hooks[name]&.call(installer)
        !!hooks[name]
      }
    }

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

    def root_target_definitions
      [target_definition_list.first]
    end

    def target_definitions
      target_definition_list.to_h { |definition| [definition.name, definition] }
    end

    def installation_options
      Pod::Installer::InstallationOptions.from_podfile(self)
    end
  end
end
