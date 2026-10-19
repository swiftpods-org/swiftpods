# frozen_string_literal: true

class Pod::Installer
  def installation_options = @installation_options ||= podfile.installation_options

  def analysis_result
    @analysis_result ||= SwiftPods::Record.new(pod_targets: pod_targets, targets: aggregate_targets, specifications: sandbox.specifications.values)
  end

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

  def initialize(data)
    @internal_data = data
  end

  def self.from_file(path)
    new(YAML.safe_load(File.read(path), permitted_classes: [Symbol], aliases: false))
  end

  def to_hash = internal_data
  def podfile_checksum = internal_data["PODFILE CHECKSUM"]
  def pod_names = versions.keys

  def versions
    internal_data.fetch("PODS", []).to_h do |entry|
      value = entry.is_a?(Hash) ? entry.keys.first : entry
      match = value.is_a?(String) && value.match(/\A(.+?) \(([^ )]+)(?:[ )])/)
      raise Pod::Informative, "Invalid locked dependency: #{value.inspect}" unless match
      [match[1], Pod::Version.new(match[2])]
    end
  end

  def version(name)
    locked = versions
    locked[name] || locked.find { |pod, _| pod.split("/", 2).first == name }&.last
  end
end
