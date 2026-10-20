# frozen_string_literal: true

module SwiftPods
  # Resolve a declaration tree without mutating the user's declarations.
  # Platform boundaries and inherit! select dependency/search-path behavior;
  # ordinary settings and Swift packages have their own inheritance rules.
  class TargetInheritance
    LOCAL_SETTINGS = %w[
      name abstract dependencies search_dependencies script_phases packages inheritance
    ].freeze

    def initialize(root, parents)
      @root = root
      @parents = parents
    end

    def resolve(entry)
      parent = @parents[entry.object_id]
      inherited = parent ? resolve(parent) : {}
      settings = inherited.reject { |key, _| LOCAL_SETTINGS.include?(key) }
      result = copy(settings).merge(entry)
      mode = entry.fetch("inheritance", "complete")
      same_platform = inherits_platform?(parent, inherited, result)

      result["label"] = label_for(entry, inherited, mode, same_platform)
      result["own_swift_version_requirements"] = entry["swift_version_requirements"]
      result["dependencies"] = dependencies_for(entry, inherited, mode, same_platform)
      result["search_dependencies"] = search_dependencies_for(parent, inherited, mode, same_platform)
      packages = mode == "none" ? [] : copy(inherited.fetch("packages", []))
      packages.each { |package| package["link"] = false } if mode == "search_paths"
      result["packages"] = packages + entry.fetch("packages", [])
      result
    end

    private

    def copy(value)
      Marshal.load(Marshal.dump(value))
    end

    def inherits_platform?(parent, inherited, result)
      return true if inherited["platform"] == result["platform"]
      parent && (parent.equal?(@root) || parent["abstract"]) && inherited["platform"].nil?
    end

    def label_for(entry, inherited, mode, same_platform)
      return "Pods" if entry.equal?(@root)
      prefix = mode == "complete" && same_platform ? inherited.fetch("label", "Pods") : "Pods"
      prefix + "-" + entry.fetch("name")
    end

    def dependencies_for(entry, inherited, mode, same_platform)
      parent_dependencies = inherited.fetch("dependencies", [])
      dependencies = entry.fetch("dependencies", [])
      dependencies += parent_dependencies if mode == "complete" && same_platform
      copy(dependencies).each do |dependency|
        next if dependency["options"].key?("configurations")
        next if mode == "none"
        rule = parent_dependencies.find do |candidate|
          candidate["name"] == dependency["name"] && candidate["options"].key?("configurations")
        end
        if rule
          dependency["options"]["configurations"] = rule["options"]["configurations"]
        end
      end
    end

    def search_dependencies_for(parent, inherited, mode, same_platform)
      return [] unless same_platform
      dependencies = inherited.fetch("search_dependencies", [])
      if mode == "search_paths" && parent && !parent.equal?(@root) && !parent["abstract"]
        dependencies += inherited.fetch("dependencies", [])
      end
      dependencies
    end
  end
end
