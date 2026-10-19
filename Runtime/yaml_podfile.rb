# frozen_string_literal: true

module SwiftPods
  class Podfile
    # Serialized CocoaPods declarations use the same target tree and DSL
    # validation as Ruby Podfiles; YAML never executes source text.
    def import_yaml(value)
      yaml_keys(value, %w[sources workspace installation_method plugins target_definitions generate_bridge_support set_arc_compatibility_flag])
      %w[generate_bridge_support set_arc_compatibility_flag].each { |key| yaml_boolean(value, key) }
      yaml_array(value.fetch("sources", [])).each { |url| source(url) }
      workspace(value["workspace"]) if value.key?("workspace")
      if (method = value["installation_method"])
        yaml_keys(method, %w[name options])
        install!(method.fetch("name"), method.fetch("options", {}))
      end
      plugins = value.fetch("plugins", {})
      raise Unsupported, "YAML plugins must be a mapping" unless plugins.is_a?(Hash)
      plugins.each { |name, options| plugin(name, options) }
      generate_bridge_support! if value["generate_bridge_support"]
      set_arc_compatibility_flag! if value["set_arc_compatibility_flag"]
      yaml_array(value.fetch("target_definitions", [])).each do |definition|
        if definition.is_a?(Hash) && definition["name"] == "Pods" && definition["abstract"] == true
          import_yaml_target(definition)
        else
          import_yaml_definition(definition)
        end
      end
    end

    private

    def yaml_keys(value, allowed)
      raise Unsupported, "YAML declaration must be a mapping" unless value.is_a?(Hash) && value.keys.all? { |key| key.is_a?(String) }
      unknown = value.keys - allowed
      raise Unsupported, "Unknown YAML Podfile keys: #{unknown.join(", ")}" unless unknown.empty?
      value
    end

    def yaml_array(value)
      raise Unsupported, "YAML declaration must be an array" unless value.is_a?(Array)
      value
    end

    def yaml_boolean(value, key)
      return unless value.key?(key)
      raise Unsupported, "YAML #{key} must be boolean" unless [true, false, nil].include?(value[key])
    end

    def import_yaml_definition(value)
      raise Unsupported, "YAML target needs a name" unless value.is_a?(Hash) && value["name"].is_a?(String)
      yaml_boolean(value, "abstract")
      define_target(value.fetch("name"), value.fetch("abstract", false)) { import_yaml_target(value) }
    end

    def import_yaml_target(value)
      yaml_keys(value, %w[name abstract platform user_project_path build_configurations dependencies children inheritance uses_frameworks swift_version swift_version_requirements inhibit_warnings use_modular_headers script_phases configuration_pod_whitelist])
      (@yaml_settings ||= {})[current.object_id] = value
      if (selected = value["platform"])
        if selected.is_a?(Hash) && selected.size == 1
          platform(*selected.first)
        elsif selected.is_a?(String)
          platform(selected)
        else
          raise Unsupported, "Invalid YAML platform"
        end
      end
      project(value["user_project_path"], value.fetch("build_configurations", {})) if value.key?("user_project_path")
      current["configurations"] = value["build_configurations"] if value.key?("build_configurations")
      if value.key?("uses_frameworks")
        linkage = value["uses_frameworks"]
        use_frameworks!(linkage.is_a?(Hash) ? linkage.transform_keys(&:to_sym) : linkage)
      end
      inherit!(value["inheritance"]) if value.key?("inheritance")
      swift_version(value["swift_version"]) if value.key?("swift_version")
      supports_swift_versions(*yaml_array(value["swift_version_requirements"])) if value.key?("swift_version_requirements")
      yaml_array(value.fetch("script_phases", [])).each { |phase| script_phase(phase) }
      yaml_array(value.fetch("dependencies", [])).each do |dependency|
        if dependency.is_a?(String)
          pod(dependency)
        elsif dependency.is_a?(Hash) && dependency.size == 1
          name, requirements = dependency.first
          values = yaml_array(requirements).map { |item| item.is_a?(Hash) ? item.transform_keys(&:to_sym) : item }
          pod(name, *values)
        else
          raise Unsupported, "Invalid YAML dependency"
        end
      end
      { "inhibit_warnings" => "inhibit_warnings", "use_modular_headers" => "modular_headers" }.each do |key, option|
        if value.key?(key)
          rules = yaml_keys(value[key], %w[all for_pods not_for_pods])
          yaml_boolean(rules, "all")
          current[option] = rules["all"] if rules.key?("all")
        end
        current.fetch("dependencies", []).each do |dependency|
          next if dependency["options"].key?(option)
          name = dependency.fetch("name").split("/").first
          yaml_scopes.each do |scope|
            next unless scope.key?(key)
            rules = yaml_keys(scope[key], %w[all for_pods not_for_pods])
            %w[for_pods not_for_pods].each do |kind|
              dependency["options"][option] = kind == "for_pods" if yaml_array(rules.fetch(kind, [])).include?(name)
            end
          end
        end
      end
      whitelists = yaml_scopes.filter_map { |scope| scope["configuration_pod_whitelist"] }
      whitelists.each do |whitelist|
        raise Unsupported, "Invalid YAML configuration whitelist" unless whitelist.is_a?(Hash)
      end
      current.fetch("dependencies", []).each do |dependency|
        next if dependency["options"].key?("configurations")
        names = whitelists.flat_map { |whitelist| whitelist.select { |_, pods| yaml_array(pods).include?(dependency["name"].split("/").first) }.keys }.uniq
        dependency["options"]["configurations"] = names unless names.empty?
      end
      yaml_array(value.fetch("children", [])).each { |child| import_yaml_definition(child) }
    end

    def yaml_scopes
      scopes = []
      entry = current
      while entry
        scopes.unshift(@yaml_settings.fetch(entry.object_id, {}))
        break if entry["inheritance"] == "none"
        entry = @parents[entry.object_id]
      end
      scopes
    end
  end
end
