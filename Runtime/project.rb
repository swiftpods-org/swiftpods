# frozen_string_literal: true

# SwiftPods' own live PBX object model for user hooks. Swift owns persistence.
module Xcodeproj
  class Project
    ATTRIBUTE_CONTRACT = JSON.parse(File.read(File.join(__dir__, "project_attributes.json"))).freeze
    TYPES = {
      static_library: ["com.apple.product-type.library.static", "archive.ar", "lib", ".a"],
      framework: ["com.apple.product-type.framework", "wrapper.framework", "", ".framework"],
      application: ["com.apple.product-type.application", "wrapper.application", "", ".app"],
      unit_test_bundle: ["com.apple.product-type.bundle.unit-test", "wrapper.cfbundle", "", ".xctest"],
      ui_test_bundle: ["com.apple.product-type.bundle.ui-testing", "wrapper.cfbundle", "", ".xctest"],
    }.freeze
    PLATFORM_SDKS = {
      "ios" => "iphoneos", "osx" => "macosx", "tvos" => "appletvos", "watchos" => "watchos", "visionos" => "xros",
    }.freeze
    DEPLOYMENT_KEYS = {
      osx: "MACOSX_DEPLOYMENT_TARGET", ios: "IPHONEOS_DEPLOYMENT_TARGET", tvos: "TVOS_DEPLOYMENT_TARGET",
      watchos: "WATCHOS_DEPLOYMENT_TARGET", visionos: "XROS_DEPLOYMENT_TARGET",
    }.freeze
    attr_reader :path, :graph
    def self.open(path)
      new(SwiftPods.callback("open_project", "path" => File.expand_path(path.to_s)))
    end

    def initialize(data)
      data = SwiftPods.callback("create_project", "path" => File.expand_path(data.to_s)) unless data.is_a?(Hash)
      @cache = {}
      update!(data)
    end

    def update!(data)
      @path = Pathname(data.fetch("path"))
      if @graph
        synchronize_graph!(@graph, data.fetch("graph"))
      else
        @graph = data.fetch("graph")
      end
      @cache.delete_if { |id, _| !@graph.fetch("objects").key?(id) }
      self
    end

    # Hooks may retain arrays, hashes and ObjectLists across phases. Refresh
    # those containers in place so later mutations still reach the live graph.
    def synchronize_graph!(current, incoming)
      return current if current.equal?(incoming)
      if current.is_a?(Hash) && incoming.is_a?(Hash)
        current.delete_if { |key, _| !incoming.key?(key) }
        incoming.each do |key, value|
          current[key] = synchronize_graph!(current[key], value)
        end
        current
      elsif current.is_a?(Array) && incoming.is_a?(Array)
        current.replace(incoming.each_with_index.map { |value, index| synchronize_graph!(current[index], value) })
      else
        incoming
      end
    end

    private :synchronize_graph!

    def object(id)
      return nil unless id && @graph["objects"][id]
      @cache[id] ||= begin
          isa = @graph["objects"][id]["isa"]
          klass = Object.const_defined?(isa, false) ? Object.const_get(isa, false) : PBXObject
          klass.new(self, id)
        end
    end

    def objects
      @graph["objects"].keys.map { |id| object(id) }
    end

    def root_object
      object(@graph["rootObject"])
    end

    def source_root
      value = root_object.project_dir_path.to_s
      Pathname(File.expand_path(value.empty? ? "." : value, path.dirname))
    end

    def main_group
      root_object.main_group
    end

    def targets
      root_object.targets
    end

    def native_targets
      targets.select { |target| target.isa == "PBXNativeTarget" }
    end

    def build_configurations
      root_object.build_configuration_list.build_configurations
    end

    def files
      objects.select { |entry| entry.isa == "PBXFileReference" }
    end

    def objects_by_uuid
      @graph["objects"].keys.to_h { |id| [id, object(id)] }
    end

    def products_group
      root_object.product_ref_group
    end

    def frameworks_group
      main_group.groups.find { |group| group.display_name == "Frameworks" } || main_group.new_group("Frameworks")
    end

    def add_build_configuration(name, type)
      root_object.add_build_configuration(name, type)
    end

    def mark_dirty!
    end

    def dirty?
      true
    end

    def reference_for_path(value)
      expected = File.expand_path(value.to_s)
      files.find { |entry| entry.data["path"] && entry.real_path.expand_path.to_s == expected }
    end

    def new_object(isa, attributes = {})
      @created ||= Hash.new(0)
      key = isa + ":" + JSON.generate(attributes)
      begin
        @created[key] += 1
        identity = ["swiftpods-hook", path.to_s, @graph["rootObject"].to_s, key, @created[key].to_s].join(":")
        id = Digest::SHA256.hexdigest(identity)[0, 24].upcase
      end while @graph.fetch("objects").key?(id)
      declared_defaults = ATTRIBUTE_CONTRACT.fetch("classes").fetch(isa, {}).to_h do |_, metadata|
        value = metadata["kind"] == "to_many" ? [] : metadata["default"]
        [metadata.fetch("plist_name"), value]
      end.reject { |_, value| value.nil? }
      defaults = case isa
        when "PBXGroup", "PBXVariantGroup" then { "children" => [], "sourceTree" => "<group>" }
        when "XCBuildConfiguration" then { "buildSettings" => {} }
        when "XCConfigurationList" then { "buildConfigurations" => [], "defaultConfigurationIsVisible" => "0" }
        when "PBXNativeTarget", "PBXAggregateTarget" then { "buildPhases" => [], "dependencies" => [], "buildRules" => [] }
        when /BuildPhase\z/ then { "files" => [], "buildActionMask" => "2147483647", "runOnlyForDeploymentPostprocessing" => "0" }
        else {}
        end
      @graph["objects"][id] = { "isa" => isa }.merge(Marshal.load(Marshal.dump(declared_defaults))).merge(defaults).merge(attributes)
      object(id)
    end

    def new(klass)
      new_object(klass.respond_to?(:name) ? klass.name.split("::").last : klass.to_s)
    end

    def new_file(path, tree = "<group>")
      main_group.new_file(path, tree)
    end

    def new_group(name, path = nil)
      main_group.new_group(name, path)
    end

    def new_target(type, name, platform, deployment = nil, *arguments)
      metadata = TYPES.fetch(type) { raise SwiftPods::Unsupported, "Unknown target product #{type}" }
      product = new_object("PBXFileReference", {
        "explicitFileType" => metadata[1], "path" => metadata[2] + name + metadata[3], "sourceTree" => "BUILT_PRODUCTS_DIR",
      })
      target = new_object("PBXNativeTarget", {
        "name" => name, "productName" => name, "productType" => metadata[0], "productReference" => product.uuid,
        "buildPhases" => [], "dependencies" => [], "buildRules" => [],
      })
      list = new_object("XCConfigurationList", {
        "buildConfigurations" => [], "defaultConfigurationName" => "Release", "defaultConfigurationIsVisible" => "0",
      })
      target.build_configuration_list = list
      %w[Debug Release].each do |configuration|
        config = target.add_build_configuration(configuration, configuration.downcase.to_sym)
        config.build_settings.merge!(
          "PRODUCT_NAME" => name, "SDKROOT" => PLATFORM_SDKS.fetch(platform.to_s), "GENERATE_INFOPLIST_FILE" => "YES",
        )
        key = DEPLOYMENT_KEYS.fetch(platform.to_sym)
        config.build_settings[key] = deployment.to_s if deployment
      end
      target.sources_build_phase
      target.frameworks_build_phase
      target.resources_build_phase
      targets << target
      root_object.product_ref_group.children << product
      target
    end

    def save(*)
      SwiftPods.callback("save_project", to_hash)
      nil
    end

    def to_hash
      { "path" => path.to_s, "graph" => @graph }
    end
  end
end

require_relative "project_objects"
