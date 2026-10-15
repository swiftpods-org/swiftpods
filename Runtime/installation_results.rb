# frozen_string_literal: true
# References to the projects generated and owned by the Swift engine.
class Pod::Installer
  TargetInstallationResults = Struct.new(:pod_target_installation_results, :aggregate_target_installation_results)

  class Xcode
    class PodsProjectGenerator
      class TargetInstallationResult
        attr_reader :target, :native_target, :resource_bundle_targets, :test_native_targets,
                    :test_resource_bundle_targets, :test_app_host_targets, :app_native_targets,
                    :app_resource_bundle_targets

        def initialize(target, native_target, resource_bundle_targets = [], test_native_targets = [],
                                              test_resource_bundle_targets = {}, test_app_host_targets = [],
                                              app_native_targets = {}, app_resource_bundle_targets = {})
          @target, @native_target = target, native_target
          @resource_bundle_targets, @test_native_targets = resource_bundle_targets, test_native_targets
          @test_resource_bundle_targets, @test_app_host_targets = test_resource_bundle_targets, test_app_host_targets
          @app_native_targets, @app_resource_bundle_targets = app_native_targets, app_resource_bundle_targets
        end

        def native_target_for_spec(spec)
          return native_target if spec.library_specification?
          return test_native_targets.find { |value| value.name == target.test_target_label(spec) } if spec.test_specification?
          app_native_targets[spec]
        end

        def test_specs_by_native_target = target.test_specs.filter_map { |spec| value = native_target_for_spec(spec); [value, spec] if value }.to_h
        def app_specs_by_native_target = app_native_targets.to_h { |spec, value| [value, spec] }
        def non_library_specs_by_native_target = test_specs_by_native_target.merge(app_specs_by_native_target)
        def app_host_target_labelled(label) = (app_native_targets.values + test_app_host_targets).find { |value| value.name == label }
      end
    end
  end
end
