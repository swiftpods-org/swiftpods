# frozen_string_literal: true
# SwiftPods' own live PBX object model for user hooks. Swift owns persistence.
module Xcodeproj
  class Project
    ATTRIBUTE_CONTRACT = JSON.parse(File.read(File.join(__dir__, "project_attributes.json"))).freeze
    TYPES = { :static_library => ["com.apple.product-type.library.static", "archive.ar", "lib", ".a"], :framework => ["com.apple.product-type.framework", "wrapper.framework", "", ".framework"], :application => ["com.apple.product-type.application", "wrapper.application", "", ".app"], :unit_test_bundle => ["com.apple.product-type.bundle.unit-test", "wrapper.cfbundle", "", ".xctest"], :ui_test_bundle => ["com.apple.product-type.bundle.ui-testing", "wrapper.cfbundle", "", ".xctest"] }.freeze
    attr_reader :path, :graph
    def self.open(path)
      new(SwiftPods.callback("open_project", "path" => File.expand_path(path.to_s)))
    end

    def initialize(data)
      data = SwiftPods.callback("create_project", "path" => File.expand_path(data.to_s)) unless data.is_a?(Hash)
      @cache = {}; update!(data)
    end

    def update!(data)
      @path = Pathname(data.fetch("path"))
      if @graph
        incoming = data.fetch("graph")
        @graph["objects"].delete_if { |id, _| !incoming["objects"].key?(id) }
        incoming["objects"].each do |id, value|
          old = @graph["objects"][id]
          if old
            value.each { |key, item| old[key].is_a?(Hash) && item.is_a?(Hash) ? old[key].replace(item) : old[key] = item }
            old.delete_if { |key, _| !value.key?(key) }
          else
            @graph["objects"][id] = value
          end
        end
        @graph.merge!(incoming.reject { |key, _| key == "objects" })
      else
        @graph = data.fetch("graph")
      end
      self
    end

    def object(id)
      return nil unless id && @graph["objects"][id]
      @cache[id] ||= (Object.const_defined?(@graph["objects"][id]["isa"], false) ? Object.const_get(@graph["objects"][id]["isa"], false) : PBXObject).new(self, id)
    end

    def objects = @graph["objects"].keys.map { |id| object(id) }
    def root_object = object(@graph["rootObject"])
    def main_group = root_object.main_group
    def targets = root_object.targets
    def native_targets = targets.select { |target| target.isa == "PBXNativeTarget" }
    def build_configurations = root_object.build_configuration_list.build_configurations
    def files = objects.select { |entry| entry.isa == "PBXFileReference" }
    def objects_by_uuid = @graph["objects"].keys.to_h { |id| [id, object(id)] }
    def products_group = root_object.product_ref_group
    def frameworks_group = main_group.groups.find { |group| group.display_name == "Frameworks" } || main_group.new_group("Frameworks")
    def add_build_configuration(name, type) = root_object.add_build_configuration(name, type)
    def mark_dirty!; end
    def dirty? = true

    def reference_for_path(value)
      expected = File.expand_path(value.to_s)
      files.find { |entry| entry.data["path"] && File.expand_path(entry.data["path"], path.dirname.to_s) == expected }
    end

    def new_object(isa, attributes = {})
      @created ||= Hash.new(0)
      key = isa + ":" + JSON.generate(attributes)
      @created[key] += 1
      id = Digest::SHA256.hexdigest("swiftpods-hook:" + path.to_s + ":" + @graph["rootObject"].to_s + ":" + key + ":" + @created[key].to_s)[0, 24].upcase
      declared_defaults = ATTRIBUTE_CONTRACT.fetch("classes").fetch(isa, {}).to_h { |_, metadata| [metadata.fetch("plist_name"), metadata["kind"] == "to_many" ? [] : metadata["default"]] }.reject { |_, value| value.nil? }
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

    def new(klass) = new_object(klass.respond_to?(:name) ? klass.name.split("::").last : klass.to_s)
    def new_file(path, tree = "<group>") = main_group.new_file(path, tree)
    def new_group(name, path = nil) = main_group.new_group(name, path)

    def new_target(type, name, platform, deployment = nil, *arguments)
      metadata = TYPES.fetch(type) { raise SwiftPods::Unsupported, "Unknown target product #{type}" }
      product = new_object("PBXFileReference", "explicitFileType" => metadata[1], "path" => metadata[2] + name + metadata[3], "sourceTree" => "BUILT_PRODUCTS_DIR")
      target = new_object("PBXNativeTarget", "name" => name, "productName" => name, "productType" => metadata[0], "productReference" => product.uuid, "buildPhases" => [], "dependencies" => [], "buildRules" => [])
      list = new_object("XCConfigurationList", "buildConfigurations" => [], "defaultConfigurationName" => "Release", "defaultConfigurationIsVisible" => "0")
      target.build_configuration_list = list
      %w[Debug Release].each do |configuration|
        config = target.add_build_configuration(configuration, configuration.downcase.to_sym)
        config.build_settings.merge!("PRODUCT_NAME" => name, "SDKROOT" => { "ios" => "iphoneos", "osx" => "macosx", "tvos" => "appletvos", "watchos" => "watchos", "visionos" => "xros" }.fetch(platform.to_s), "GENERATE_INFOPLIST_FILE" => "YES")
        key = { "ios" => "IPHONEOS", "osx" => "MACOSX", "tvos" => "TVOS", "watchos" => "WATCHOS", "visionos" => "XROS" }.fetch(platform.to_s) + "_DEPLOYMENT_TARGET"
        config.build_settings[key] = deployment.to_s if deployment
      end
      target.sources_build_phase; target.frameworks_build_phase; target.resources_build_phase
      targets << target
      root_object.product_ref_group.children << product
      target
    end

    def save(*); SwiftPods.callback("save_project", to_hash); nil; end
    def to_hash = { "path" => path.to_s, "graph" => @graph }

    class ObjectList
      include Enumerable

      def initialize(project, values); @project = project; @values = values; end
      def decode(value) = @project.object(value) || value
      def encode(value) = value.respond_to?(:uuid) ? value.uuid : value

      def each
        return enum_for(:each) unless block_given?
        @values.dup.each { |value| yield decode(value) }; self
      end

      def [](index) = decode(@values[index])
      def []=(index, value); @values[index] = encode(value); end
      def <<(value); @values << encode(value); self; end
      def concat(values); values.each { |value| self << value }; self; end
      def delete(value); @values.delete(encode(value)); value; end
      def delete_if; @values.delete_if { |value| yield decode(value) }; self; end
      def clear; @values.clear; self; end
      def replace(values); @values.replace(values.map { |value| encode(value) }); self; end
      def insert(index, value); @values.insert(index, encode(value)); self; end
      def include?(value) = @values.include?(encode(value))
      def sort!(&block); replace(to_a.sort(&block)); end
      def size = @values.size

      alias length size

      def empty? = @values.empty?
      def to_ary = to_a
    end

    class PBXObject
      attr_reader :project, :uuid

      def initialize(project, uuid); @project = project; @uuid = uuid; end
      def data = project.graph["objects"].fetch(uuid)
      def isa = data.fetch("isa")
      def to_s = data["name"] || data["path"] || uuid
      def display_name = to_s
      def to_hash = data
      def attribute(name) = Project::ATTRIBUTE_CONTRACT.fetch("classes").fetch(isa, {})[name.to_s]
      def field(name) = attribute(name)&.fetch("plist_name") || name.to_s.gsub(/_([a-z])/) { $1.upcase }

      def method_missing(name, *arguments)
        raw = name.to_s
        key = field(raw.delete_suffix("="))
        if raw.end_with?("=")
          metadata = attribute(raw.delete_suffix("="))
          return super unless metadata && metadata["kind"] != "to_many"
          value = arguments.fetch(0)
          data[key] = value.respond_to?(:uuid) ? value.uuid : value
        elsif arguments.empty? && data.key?(key)
          value = data[key]
          value.is_a?(Array) ? (attribute(raw)&.fetch("kind") == "simple" ? value : ObjectList.new(project, value)) : (project.object(value) || value)
        elsif arguments.empty? && (metadata = attribute(raw))
          default = metadata["kind"] == "to_many" ? [] : metadata["default"]
          return nil if default.nil?
          data[key] = Marshal.load(Marshal.dump(default))
          data[key].is_a?(Array) && metadata["kind"] != "simple" ? ObjectList.new(project, data[key]) : data[key]
        elsif arguments.empty? && %w[settings buildSettings attributes].include?(key)
          data[key] ||= {}
        elsif arguments.empty? && %w[baseConfigurationReference productReference productRefGroup fileRef target targetProxy name path shellPath shellScript inputPaths outputPaths inputFileListPaths outputFileListPaths sourceTree explicitFileType lastKnownFileType includeInIndex].include?(key)
          nil
        else
          super
        end
      end

      def respond_to_missing?(name, _private = false)
        metadata = attribute(name.to_s.delete_suffix("="))
        (metadata && (!name.to_s.end_with?("=") || metadata["kind"] != "to_many")) || data.key?(field(name)) || super
      end

      def build_configurations
        return ObjectList.new(project, data.fetch("buildConfigurations")) if isa == "XCConfigurationList"
        build_configuration_list.build_configurations
      end

      def add_build_configuration(name, type)
        existing = build_configurations.find { |config| config.name == name }
        return existing if existing
        source = build_configurations.find { |config| config.name.downcase == type.to_s } || build_configurations.first
        settings = source ? Marshal.load(Marshal.dump(source.build_settings)) : {}
        config = project.new_object("XCBuildConfiguration", "name" => name, "buildSettings" => settings)
        build_configurations << config
        config
      end

      def phase(isa, label = nil)
        existing = build_phases.find { |entry| entry.isa == isa } unless label
        return existing if existing
        value = { "files" => [], "buildActionMask" => "2147483647", "runOnlyForDeploymentPostprocessing" => "0" }
        value["name"] = label if label
        entry = project.new_object(isa, value); build_phases << entry; entry
      end

      def sources_build_phase = phase("PBXSourcesBuildPhase")
      def frameworks_build_phase = phase("PBXFrameworksBuildPhase")
      def resources_build_phase = phase("PBXResourcesBuildPhase")
      def headers_build_phase = phase("PBXHeadersBuildPhase")
      def shell_script_build_phases = build_phases.select { |entry| entry.isa == "PBXShellScriptBuildPhase" }

      def new_shell_script_build_phase(name = nil)
        entry = phase("PBXShellScriptBuildPhase", name || "Run Script")
        entry.shell_path = "/bin/sh"; entry.shell_script = ""; entry.input_paths = []; entry.output_paths = []
        entry
      end

      def new_copy_files_build_phase(name = nil) = phase("PBXCopyFilesBuildPhase", name || "Copy Files")
      def files_references = files.map(&:file_ref)

      def remove_file_reference(reference)
        files.select { |entry| entry.file_ref == reference }.each(&:remove_from_project)
      end

      def groups = children.select { |child| %w[PBXGroup PBXVariantGroup].include?(child.isa) }
      def recursive_children = children.flat_map { |child| [child, *(child.respond_to?(:children) ? child.recursive_children : [])] }
      def recursive_children_groups = groups.flat_map { |group| [group, *group.recursive_children_groups] }
      def find_file_by_path(path) = children.find { |entry| entry.data["path"] == path.to_s }

      def [](path)
        first, rest = path.to_s.split("/", 2)
        found = children.find { |entry| entry.display_name == first }
        rest ? found&.[](rest) : found
      end

      def real_path
        value = data["path"].to_s
        return Pathname(value) if data["sourceTree"] == "<absolute>" || value.start_with?("/")
        parent = project.objects.find { |entry| entry.data.fetch("children", []).include?(uuid) }
        base = data["sourceTree"] == "<group>" && parent ? parent.real_path : project.path.dirname
        base + value
      end

      def resolved_build_setting(key, resolve_against_xcconfig = false)
        value = project.to_hash.merge("target" => uuid, "key" => key, "xcconfig" => resolve_against_xcconfig)
        SwiftPods.callback("build_settings", value).fetch("result")
      end

      def common_resolved_build_setting(key, resolve_against_xcconfig = false)
        values = resolved_build_setting(key, resolve_against_xcconfig).values.uniq
        raise ArgumentError, "Multiple values for #{key}" if values.size > 1
        values.first
      end

      def platform_name
        sdk = common_resolved_build_setting("SDKROOT").to_s
        { "macosx" => :osx, "iphoneos" => :ios, "iphonesimulator" => :ios, "appletvos" => :tvos, "appletvsimulator" => :tvos, "watchos" => :watchos, "watchsimulator" => :watchos, "xros" => :visionos, "xrsimulator" => :visionos }[sdk]
      end

      def deployment_target
        key = { osx: "MACOSX_DEPLOYMENT_TARGET", ios: "IPHONEOS_DEPLOYMENT_TARGET", tvos: "TVOS_DEPLOYMENT_TARGET", watchos: "WATCHOS_DEPLOYMENT_TARGET", visionos: "XROS_DEPLOYMENT_TARGET" }[platform_name]
        common_resolved_build_setting(key)
      end

      def new_file(path, tree = "<group>")
        entry = project.new_object("PBXFileReference", "path" => path.to_s, "sourceTree" => tree)
        children << entry
        entry
      end

      def new_group(name, path = nil)
        value = { "name" => name, "children" => [], "sourceTree" => "<group>" }; value["path"] = path if path
        entry = project.new_object("PBXGroup", value); children << entry; entry
      end

      def add_file_reference(reference, *arguments)
        entry = project.new_object("PBXBuildFile", "fileRef" => reference.uuid)
        files << entry; entry
      end

      def add_file_references(references)
        references.map do |reference|
          extension = File.extname(reference.path.to_s)
          phase = %w[.h .hh .hpp].include?(extension) ? headers_build_phase : sources_build_phase
          phase.add_file_reference(reference)
        end
      end

      def add_dependency(target)
        return if dependency_for_target(target)
        local = target.project.equal?(project)
        portal = local ? project.root_object : project.reference_for_path(target.project.path)
        raise ArgumentError, "Dependency target must belong to this project or a referenced subproject" unless portal
        proxy = project.new_object("PBXContainerItemProxy", "containerPortal" => portal.uuid, "proxyType" => "1", "remoteGlobalIDString" => target.uuid, "remoteInfo" => target.name)
        values = { "name" => target.name, "targetProxy" => proxy.uuid }; values["target"] = target.uuid if local
        dependencies << project.new_object("PBXTargetDependency", values)
      end

      def dependency_for_target(target)
        local = target.project.equal?(project)
        portal = project.reference_for_path(target.project.path) unless local
        dependencies.find do |dependency|
          proxy = project.object(dependency.data["targetProxy"])
          local ? dependency.data["target"] == target.uuid : (portal && proxy && proxy.data["remoteGlobalIDString"] == target.uuid && proxy.data["containerPortal"] == portal.uuid)
        end
      end

      def remove_from_project
        project.graph["objects"].values.each do |object|
          object.each do |key, value|
            value.delete(uuid) if value.is_a?(Array)
            object.delete(key) if value == uuid
          end
        end
        project.graph["objects"].delete(uuid)
      end
    end

    module Object
      AbstractObject = PBXObject
      parents = Project::ATTRIBUTE_CONTRACT.fetch("parents").dup
      until parents.empty?
        ready = parents.select { |_, parent| const_defined?(parent, false) }
        raise SwiftPods::Unsupported, "Invalid project class inheritance contract" if ready.empty?
        ready.each { |name, parent| const_set(name, Class.new(const_get(parent, false))); parents.delete(name) }
      end
    end
  end
end
