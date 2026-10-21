#!/usr/bin/env python3
"""Compare the complete DSL/attribute registries with the isolated reference."""

import argparse
import json
import re
import subprocess
from pathlib import Path

from scripts.support.bootstrap import ROOT, environment
from scripts.support.local_build import fixture_directory, results_directory
from scripts.support.reporting import execute
from Tests.Reference.reference_compare import reference_environment

RUBY = r"""
require 'json'
def normalize(value)
  case value
  when Hash then value.to_h { |key, item| [key.to_s, normalize(item)] }
  when Array then value.map { |item| normalize(item) }
  when Gem::Version, Gem::Requirement, Pathname, Symbol then value.to_s
  else value
  end
end
def observe(spec, attribute)
  result = {'hash' => normalize(spec.to_hash), 'json' => spec.to_json, 'pretty_json' => spec.to_pretty_json}
  consumer = spec.consumer(:osx)
  if consumer.respond_to?(attribute)
    value = consumer.public_send(attribute)
    value = value.map { |dependency| [dependency.name, dependency.requirement.to_s] } if attribute == 'dependencies'
    result['consumer'] = normalize(value)
  end
  result
end
input = JSON.parse(ARGV.fetch(0))
attributes = input.fetch('attributes').to_h do |attribute, value|
  spec = Pod::Spec.new { |s| s.name = 'SchemaKit'; s.version = '1.0'; s.osx.deployment_target = '13.0'; s.public_send(attribute + '=', value) }
  [attribute, observe(spec, attribute)]
end
inheritance = Pod::Spec.new do |s|
  s.name = 'Inherited'; s.version = '1.0'; s.osx.deployment_target = '13.0'
  s.source_files = 'Root/*.m'; s.frameworks = ['Foundation']; s.osx.frameworks = ['CoreFoundation']
  s.public_header_files = 'Root/*.h'; s.resources = 'Root/*.txt'; s.pod_target_xcconfig = {'MARKER' => 'parent'}
  s.subspec('Child') { |c| c.source_files = 'Child/*.m'; c.frameworks = ['AppKit']; c.pod_target_xcconfig = {'MARKER' => 'child'} }
  s.test_spec('Tests') { |c| c.source_files = 'Tests/*.m'; c.pod_target_xcconfig = {'MARKER' => 'test'} }
end
consumers = %w[Inherited Inherited/Child Inherited/Tests].to_h do |name|
  spec = inheritance.subspec_by_name(name, true, true)
  values = %w[source_files public_header_files resources frameworks pod_target_xcconfig requires_arc].to_h { |key| [key, normalize(spec.consumer(:osx).public_send(key))] }
  [name, values]
end
definitions = input.fetch('podfiles').to_h do |name, source|
  markers = %w[BUNDLE_BIN_PATH BUNDLE_GEMFILE].to_h { |key| [key, ENV[key]] }
  begin
    %w[BUNDLE_BIN_PATH BUNDLE_GEMFILE].each { |key| ENV.delete(key) } if name == 'ensure_bundler!'
    if NATIVE
      podfile = SwiftPods::Podfile.new
      podfile.instance_eval(source, 'Podfile', 1)
    else
      podfile = Pod::Podfile.new(Pathname(Dir.pwd) + 'Podfile') { instance_eval(source, 'Podfile', 1) }
    end
    options = Pod::Installer::InstallationOptions.from_podfile(podfile)
    targets = podfile.target_definitions.values.reject { |target| target.abstract? || target.name.to_s == 'Pods' }.map do |target|
      {'name' => target.name.to_s, 'label' => target.label, 'platform' => target.platform&.name&.to_s, 'minimum' => target.platform&.deployment_target&.to_s,
       'frameworks' => target.uses_frameworks?, 'swift' => normalize(target.swift_version_requirements), 'supports_swift' => ['5.0', '6.0'].map { |version| target.supports_swift_version?(Pod::Version.new(version)) },
       'dependencies' => target.dependencies.map { |dependency| [dependency.name, dependency.requirement.to_s] }.sort,
       'inhibit' => target.inhibits_warnings_for_pod?('OtherKit'), 'modular' => target.build_pod_as_module?('OtherKit'), 'configurations' => normalize(target.build_configurations), 'project' => target.user_project_path, 'scripts' => normalize(target.script_phases)}
    end.sort_by { |target| target['label'] }
    $contract_hooks = []
    %w[pre_install pre_integrate post_install post_integrate].each { |hook| podfile.public_send(hook + '!', Object.new) }
    [name, {'targets' => targets, 'options' => normalize(options.to_h), 'sources' => podfile.sources, 'plugins' => normalize(podfile.plugins), 'workspace' => podfile.workspace_path, 'bridge' => podfile.generate_bridge_support?, 'arc' => podfile.set_arc_compatibility_flag?, 'hooks' => $contract_hooks}]
  rescue Exception => error
    [name, {'error' => true}]
  ensure
    markers.each { |key, value| value ? ENV[key] = value : ENV.delete(key) }
  end
end
aliases = Pod::Specification::DSL.attributes.values.filter_map(&:writer_singular_form)
forbidden = begin
  Pod::Spec.new { |spec| spec.ios.version = '1.0' }; false
rescue NoMethodError; true
end
output = {'attributes' => attributes, 'inheritance' => consumers, 'inheritance_json' => inheritance.to_pretty_json, 'podfiles' => definitions, 'aliases' => aliases.sort, 'forbidden_platform_attribute' => forbidden}
project_attributes = if NATIVE
  Xcodeproj::Project::ATTRIBUTE_CONTRACT.fetch('classes')
else
  Xcodeproj::Project::Object.constants.to_h { |name| [name.to_s, Xcodeproj::Project::Object.const_get(name)] }.select { |_, value| value.is_a?(Class) && value < Xcodeproj::Project::Object::AbstractObject }.transform_values { |klass| klass.attributes.to_h { |attribute| [attribute.name.to_s, {'plist_name' => attribute.plist_name, 'kind' => attribute.type.to_s, 'default' => attribute.default_value}] } }
end
output['project_attributes'] = normalize(project_attributes)

puts JSON.generate(output)
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--gem-home", type=Path, required=True)
    args = parser.parse_args()
    parent = fixture_directory("contract-reference-")
    schema = json.loads(ROOT.joinpath("Runtime/attributes.json").read_text())
    attributes = {name: "Fixture" for name in schema}
    attributes.update(
        name="Renamed",
        version="2.0",
        swift_versions=["5.0", "6.0"],
        cocoapods_version=">= 1.17",
        authors={"Developer": "dev@swiftpods.org"},
        license={"type": "MIT"},
        source={"git": "https://example.invalid/fixture.git", "tag": "1.0"},
        static_framework=True,
        deprecated=True,
        platforms={"osx": "13.0"},
        dependencies={"OtherKit": [">= 1.0"]},
        info_plist={"Marker": "value"},
        requires_arc=False,
        frameworks=["Foundation"],
        weak_frameworks=["AppKit"],
        libraries=["c++"],
        compiler_flags=["-DFIXTURE=1"],
        pod_target_xcconfig={"MARKER": "pod"},
        user_target_xcconfig={"MARKER": "user"},
        xcconfig={"MARKER": "legacy"},
        prefix_header_contents=["#define FIRST 1", "#define SECOND 2"],
        prefix_header_file=False,
        script_phases=[{"name": "Fixture", "script": "true"}],
        on_demand_resources={
            "Tag": {"paths": ["file.txt"], "category": "initial_install"}
        },
        resource_bundles={"Bundle": ["file.txt"]},
        test_type="unit",
        requires_app_host=True,
        scheme={"launch_arguments": ["--fixture"]},
        default_subspecs=["Child"],
    )
    declarations = {
        "install!": "install! 'cocoapods', :clean => false",
        "ensure_bundler!": "ensure_bundler!",
        "pod": "platform :osx, '13.0'\npod 'RootKit', '~> 1.0'\ntarget 'App' do\n pod 'ChildKit', '>= 2'\nend",
        "podspec": "platform :osx, '13.0'\ntarget 'App' do\n podspec :path => 'Development.podspec'\nend",
        "target": "target 'App', false",
        "script_phase": "target 'App' do\n script_phase :name => 'Script', :script => 'true'\nend",
        "abstract_target": "abstract_target 'Shared' do\n pod 'Common'\n target 'App'\nend",
        "abstract!": "target 'Shared' do\n abstract!\n target 'App'\nend",
        "inherit!": "target 'Outer' do\n pod 'Common'\n target 'App' do\n inherit! 'none'\n pod 'Own'\nend\nend",
        "platform": "platform :ios\ntarget 'App'",
        "project": "project 'Example', 'Custom' => :debug\ntarget 'App'",
        "xcodeproj": "xcodeproj 'Example'\ntarget 'App'",
        "link_with": "link_with 'App'",
        "inhibit_all_warnings!": "inhibit_all_warnings!\ntarget 'App'",
        "use_modular_headers!": "use_modular_headers!\ntarget 'App'",
        "use_frameworks!": "use_frameworks! :linkage => :static\ntarget 'App'",
        "supports_swift_versions": "supports_swift_versions '>= 5.0', '< 6'\ntarget 'App'",
        "workspace": "workspace 'Example'\ntarget 'App'",
        "generate_bridge_support!": "generate_bridge_support!\ntarget 'App'",
        "set_arc_compatibility_flag!": "set_arc_compatibility_flag!\ntarget 'App'",
        "source": "source 'https://example.invalid/specs.git'\ntarget 'App'",
        "plugin": "plugin 'contract-plugin', :marker => 'yes'\ntarget 'App'",
    }
    declarations["inheritance:abstract-platform"] = (
        "abstract_target 'Shared' do\n pod 'Common'\n target 'App' do\n platform :osx, '13.0'\n end\nend"
    )
    for hook in ("pre_install", "pre_integrate", "post_install", "post_integrate"):
        declarations[hook] = (
            hook + " { |installer| $contract_hooks << '" + hook + "' }\ntarget 'App'"
        )
    # Coverage comes from the versioned contract, independent of Ruby formatting.
    registry = json.loads(ROOT.joinpath("Profiles/contract.json").read_text())
    option_names = list(registry["api"]["installation_options"])
    for name in option_names:
        value = "3" if name == "parallel_pod_download_thread_pool_size" else "false"
        declarations["option:" + name] = (
            "install! 'cocoapods', :" + name + " => " + value + "\ntarget 'App'"
        )
    for name, source in {
        "target-options": "target 'App', :bad => true",
        "framework-linkage": "use_frameworks! :linkage => :invalid",
        "framework-type": "use_frameworks! 123",
        "framework-key": "use_frameworks!({})",
        "root-inheritance": "inherit! :none",
        "nested-install": "target 'App' do\n install! 'cocoapods'\nend",
        "unknown-option": "install! 'cocoapods', :unknown => true",
        "swift-requirement": "supports_swift_versions 'invalid'\ntarget 'App'",
        "unknown-method": "unknown_directive!",
    }.items():
        declarations["invalid:" + name] = source
    parent.joinpath("Development.podspec").write_text(
        "Pod::Spec.new do |s|\n s.name='Development'; s.version='1.0'; s.osx.deployment_target='13.0'; s.dependency 'External', '>= 1'; s.subspec('Child') { |c| c.dependency 'Nested', '~> 2' }; end\n"
    )
    parent.joinpath("contract-plugin.rb").write_text(
        "# Deliberately empty registration fixture.\n"
    )
    # Plugin loading has separate real lifecycle coverage; make this declared
    # local plugin available to the native adapter without importing engines.
    declarations["plugin"] = "$LOAD_PATH.unshift(Dir.pwd)\n" + declarations["plugin"]
    methods = re.findall(
        r"^      def ([a-z_]+[!?]?)",
        ROOT.joinpath(
            "Tests/Reference/vendor/cocoapods-core/lib/cocoapods-core/podfile/dsl.rb"
        ).read_text(),
        re.M,
    )
    assert set(methods) <= declarations.keys(), set(methods) - declarations.keys()
    payload = json.dumps({"attributes": attributes, "podfiles": declarations})
    ruby, reference_env = reference_environment(args.gem_home, parent)
    selected = environment()
    native = subprocess.run(
        [
            ruby,
            "-e",
            "NATIVE=true; require "
            + json.dumps(str(ROOT / "Runtime/runtime.rb"))
            + ";"
            + RUBY,
            payload,
        ],
        cwd=parent,
        env=selected,
        input="",
        capture_output=True,
        text=True,
        timeout=60,
    )
    reference = subprocess.run(
        [
            ruby,
            "-e",
            "NATIVE=false; require 'bundler/setup'; require 'cocoapods';" + RUBY,
            payload,
        ],
        cwd=parent,
        env=reference_env,
        capture_output=True,
        text=True,
        timeout=60,
    )
    for name, result in [("native", native), ("reference", reference)]:
        parent.joinpath(name + ".log").write_text(result.stdout + result.stderr)
        assert result.returncode == 0, (name, result.stderr)
    own = json.loads(native.stdout)
    expected = json.loads(reference.stdout)
    parent.joinpath("native.json").write_text(json.dumps(own, indent=2))
    parent.joinpath("reference.json").write_text(json.dumps(expected, indent=2))
    mismatches = []
    for category in expected:
        if isinstance(expected[category], dict):
            for key in expected[category]:
                if own[category].get(key) != expected[category][key]:
                    mismatches.append(category + ":" + key)
        elif own.get(category) != expected[category]:
            mismatches.append(category)
    assert not mismatches, ("Contract mismatch: " + ", ".join(mismatches), parent)
    report = {
        "status": "passed",
        "engine": "swift",
        "reference": "1.17.0",
        "fixture": str(parent),
        "verified": [
            f"{len(methods)} baseline Podfile methods",
            f"{len(option_names)} installation option values and defaults",
            f"{len(attributes)} complete attribute declarations and consumer values",
            "singular aliases and per-platform setter restrictions",
            "library/test inheritance and xcconfig conflict semantics",
            "negative DSL types and options",
        ],
        "verified_cases": ["dsl:" + name for name in methods]
        + ["option:" + name for name in option_names]
        + ["attribute:" + name for name in attributes],
        "unverified": ["all build effects for every attribute and platform"],
    }
    results_directory().joinpath("native-contract-reference.json").write_text(
        json.dumps(report, indent=2) + "\n"
    )
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    execute(main, "native-contract-reference.json")
