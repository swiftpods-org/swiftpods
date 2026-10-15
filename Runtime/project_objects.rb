# frozen_string_literal: true

module Xcodeproj
  class Project
    class ObjectList
      include Enumerable

      def initialize(project, values)
        @project = project
        @values = values
      end

      def decode(value) = @project.object(value) || value
      def encode(value) = value.respond_to?(:uuid) ? value.uuid : value

      def each
        return enum_for(:each) unless block_given?
        @values.dup.each { |value| yield decode(value) }
        self
      end

      def [](*indices)
        value = @values[*indices]
        value.is_a?(Array) ? value.map { |entry| decode(entry) } : decode(value)
      end

      def []=(index, value)
        @values[index] = encode(value)
      end

      def <<(value)
        @values << encode(value)
        self
      end

      def concat(values)
        values.each { |value| self << value }
        self
      end

      def delete(value)
        removed = @values.delete(encode(value)) { return block_given? ? yield : nil }
        decode(removed)
      end

      def delete_if
        @values.delete_if { |value| yield decode(value) }
        self
      end

      def clear
        @values.clear
        self
      end

      def replace(values)
        @values.replace(values.map { |value| encode(value) })
        self
      end

      def insert(index, value)
        @values.insert(index, encode(value))
        self
      end

      def include?(value) = @values.include?(encode(value))

      def sort!(&block)
        replace(to_a.sort(&block))
      end

      def size = @values.size

      alias length size

      def empty? = @values.empty?
      def to_ary = to_a
    end

    class PBXObject
      attr_reader :project, :uuid

      def initialize(project, uuid)
        @project = project
        @uuid = uuid
      end

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
          if value.is_a?(Array)
            attribute(raw)&.fetch("kind") == "simple" ? value : ObjectList.new(project, value)
          else
            project.object(value) || value
          end
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
        entry = project.new_object(isa, value)
        build_phases << entry
        entry
      end

      def sources_build_phase = phase("PBXSourcesBuildPhase")
      def frameworks_build_phase = phase("PBXFrameworksBuildPhase")
      def resources_build_phase = phase("PBXResourcesBuildPhase")
      def headers_build_phase = phase("PBXHeadersBuildPhase")
      def shell_script_build_phases = build_phases.select { |entry| entry.isa == "PBXShellScriptBuildPhase" }

      def new_shell_script_build_phase(name = nil)
        entry = phase("PBXShellScriptBuildPhase", name || "Run Script")
        entry.shell_path = "/bin/sh"
        entry.shell_script = ""
        entry.input_paths = []
        entry.output_paths = []
        entry
      end

      def new_copy_files_build_phase(name = nil) = phase("PBXCopyFilesBuildPhase", name || "Copy Files")
      def files_references = files.map(&:file_ref)

      def remove_file_reference(reference)
        files.select { |entry| entry.file_ref == reference }.each(&:remove_from_project)
      end

      def groups = children.select { |child| %w[PBXGroup PBXVariantGroup].include?(child.isa) }

      def recursive_children
        children.flat_map { |child| [child, *(child.respond_to?(:children) ? child.recursive_children : [])] }
      end

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
        {
          "macosx" => :osx, "iphoneos" => :ios, "iphonesimulator" => :ios, "appletvos" => :tvos,
          "appletvsimulator" => :tvos, "watchos" => :watchos, "watchsimulator" => :watchos,
          "xros" => :visionos, "xrsimulator" => :visionos,
        }[sdk]
      end

      def deployment_target
        key = Project::DEPLOYMENT_KEYS[platform_name]
        common_resolved_build_setting(key)
      end

      def new_file(path, tree = "<group>")
        entry = project.new_object("PBXFileReference", "path" => path.to_s, "sourceTree" => tree)
        children << entry
        entry
      end

      def new_group(name, path = nil)
        value = { "name" => name, "children" => [], "sourceTree" => "<group>" }
        value["path"] = path if path
        entry = project.new_object("PBXGroup", value)
        children << entry
        entry
      end

      def add_file_reference(reference, *arguments)
        entry = project.new_object("PBXBuildFile", "fileRef" => reference.uuid)
        files << entry
        entry
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
        proxy = project.new_object("PBXContainerItemProxy", {
          "containerPortal" => portal.uuid, "proxyType" => "1", "remoteGlobalIDString" => target.uuid,
          "remoteInfo" => target.name,
        })
        values = { "name" => target.name, "targetProxy" => proxy.uuid }
        values["target"] = target.uuid if local
        dependencies << project.new_object("PBXTargetDependency", values)
      end

      def dependency_for_target(target)
        local = target.project.equal?(project)
        portal = project.reference_for_path(target.project.path) unless local
        dependencies.find do |dependency|
          proxy = project.object(dependency.data["targetProxy"])
          if local
            dependency.data["target"] == target.uuid
          else
            portal && proxy && proxy.data["remoteGlobalIDString"] == target.uuid && proxy.data["containerPortal"] == portal.uuid
          end
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
        ready.each { |name, parent|
          const_set(name, Class.new(const_get(parent, false)))
          parents.delete(name)
        }
      end
    end
  end
end
