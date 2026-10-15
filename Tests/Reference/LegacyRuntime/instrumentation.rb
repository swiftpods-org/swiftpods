# frozen_string_literal: true

module SwiftPods
  module CommandDiagnostics
    def handle_exception(command, error)
      SwiftPods.diagnostic(error)
      super
    end

    def report_error(error)
      # Upstream's exception search makes an unsolicited GitHub request. Keep
      # the error/backtrace locally and preserve its failure status instead.
      raise error
    end
  end
  Pod::Command.singleton_class.prepend(CommandDiagnostics)

  module InstallerEvents
    def install!
      super
      specs = analysis_result.specifications.map do |spec|
        spec_source = analysis_result.specs_by_source.find { |_source, source_specs| source_specs.any? { |candidate| candidate.name == spec.name } }&.first
        { 'name' => spec.name, 'version' => spec.version.to_s,
          'dependencies' => spec.dependencies.map { |dependency| { 'name' => dependency.name, 'requirement' => dependency.requirement.to_s } },
          'source' => spec.source, 'spec_repository' => spec_source.respond_to?(:url) ? spec_source.url : nil,
          'checkout' => sandbox.checkout_sources[spec.root.name],
          'module_name' => spec.module_name,
          'local' => sandbox.local?(spec.root.name),
          'root' => sandbox.pod_dir(spec.root.name).to_s }
      end
      targets = aggregate_targets.map do |target|
        { 'name' => target.name, 'platform' => target.platform.to_s,
          'pods' => target.pod_targets.map(&:pod_name),
          'dependencies' => target.target_definition.dependencies.map { |dependency| { 'name' => dependency.name, 'requirement' => dependency.requirement.to_s } },
          'user_project' => target.user_project&.path&.to_s,
          'user_targets' => target.user_project ? target.user_targets.map(&:name) : [] }
      end
      resources = pod_targets.flat_map do |target|
        target.file_accessors.select { |accessor| accessor.spec.library_specification? }.map do |accessor|
          { 'pod' => target.pod_name, 'bundles' => accessor.resource_bundles.keys,
            'privacy_manifests' => (accessor.resources + accessor.resource_bundles.values.flatten).select { |path| path.extname == '.xcprivacy' }.map { |path| path.basename.to_s } }
        end
      end
      SwiftPods.emit('installation', 'specs' => specs, 'targets' => targets,
                                     'input_manifest' => podfile.defined_in_file&.to_s,
                                     'lockfile' => lockfile.to_hash,
                                     'resources' => resources,
                                     'inputs' => SwiftPods::Inputs.report(podfile, analysis_result.specifications),
                                     'plugins' => podfile.plugins.keys.map { |name| { 'name' => name, 'version' => Gem.loaded_specs[name]&.version&.to_s } },
                                     'environment_profile' => ENV['SWIFTPODS_ENVIRONMENT'] || 'baseline')
    end

    %i[run_podfile_pre_install_hook run_podfile_pre_integrate_hook
       run_podfile_post_install_hook run_podfile_post_integrate_hook].each do |method|
      define_method(method) do |*args|
        SwiftPods.emit('phase', 'name' => method.to_s)
        super(*args)
      end
    end
  end
  Pod::Installer.prepend(InstallerEvents)
end
