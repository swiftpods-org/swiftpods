#!/usr/bin/env python3
"""Regression corpus for locked sources, versions and the public hook file API."""

import argparse
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

from batch_fixture import user_project
from bootstrap import ROOT, environment
from glob_character_class_regressions import character_class_parity
from glob_scalar_regressions import scalar_parity
from input_contract_regressions import inheritance_case
from name_boundary_regressions import name_parity
from reference_compare import reference_environment
from reporting import execute
from source_input_regressions import mutable_checkout_case
from structured_input_regressions import (
    scheme_whitespace_parity,
    structured_input_parity,
)
from unicode_path_regressions import path_parity
from value_contract_regressions import serialized_input_parity

FILE_API = r"""
pre_install do |installer|
  accessor = installer.pod_targets.find { |target| target.pod_name == 'FileKit' }.file_accessors.find { |value| value.spec.library_specification? }
  relative = ->(values) { values.map { |path| path.relative_path_from(accessor.root).to_s }.sort }
  names = %w[source_files headers public_headers private_headers project_headers arc_source_files non_arc_source_files resources resource_bundle_files on_demand_resources_files]
  values = names.to_h { |name| [name, relative.call(accessor.public_send(name))] }
  values['resource_bundles'] = accessor.resource_bundles.transform_values { |paths| relative.call(paths) }
  values['on_demand_resources'] = accessor.on_demand_resources.transform_values { |value| {'paths' => relative.call(value[:paths]), 'category' => value[:category].to_s} }
  values['root'] = accessor.root.basename.to_s
  values['spec'] = accessor.spec.name
  values['platform_name'] = accessor.platform_name.to_s
  values['unknown_getters_rejected'] = [installer.analysis_result, installer.sandbox.public_headers, accessor.path_list].all? do |value|
    begin
      value.public_send(:swiftpods_unknown_getter)
      false
    rescue NoMethodError
      true
    end
  end
  begin
    installer.sandbox.private_headers
    values['unknown_getters_rejected'] = false
  rescue NoMethodError
    # The baseline has no Sandbox.private_headers operation.
  end
  raise 'Unknown public hook getter silently succeeded' unless values['unknown_getters_rejected']
  File.write('file-api.json', JSON.pretty_generate(values))
  created = Xcodeproj::Project.new(File.join(Dir.pwd, 'Hook.xcodeproj'))
  target = created.new_target(:static_library, 'Hook', :osx, '13.0')
  group = created.main_group.new_group('Generated', 'Generated')
  group.new_file('marker.c')
  begin
    target.unknown_swiftpods_attribute = 'must fail'
    unknown_rejected = false
  rescue NoMethodError
    unknown_rejected = true
  end
  raise 'Unknown PBX setter was accepted' unless unknown_rejected
  values = {'target' => target.name, 'platform' => target.platform_name.to_s, 'minimum' => target.deployment_target, 'configurations' => target.build_configurations.map(&:name).sort, 'group' => group.path, 'file' => group['marker.c'].path, 'unknown_setter_rejected' => unknown_rejected}
  created.save
  File.write('project-api.json', JSON.pretty_generate(values))
end
"""

TARGET_TREE_API = r"""
%w[pre_install pre_integrate post_install post_integrate].each do |phase|
  send(phase) do |installer|
    podfile = installer.podfile
    definitions = podfile.target_definition_list
    $tree_definitions ||= definitions
    raise 'Target definition identity changed' unless definitions.zip($tree_definitions).all? { |left, right| left.equal?(right) }
    raise 'Root target identity changed' unless podfile.root_target_definitions == [definitions.first]
    raise 'Podfile identity changed' unless definitions.all? { |definition| definition.podfile.equal?(podfile) }
    raise 'Public target definition type missing' unless definitions.all? { |definition| definition.is_a?(Pod::Podfile::TargetDefinition) && definition.to_s == definition.label }
    observations = definitions.map do |definition|
      {'name' => definition.name, 'label' => definition.label, 'abstract' => definition.abstract?, 'root' => definition.root.label,
       'root?' => definition.root?, 'parent' => definition.root? ? 'Podfile' : definition.parent.label,
       'children' => definition.children.map(&:label), 'recursive_children' => definition.recursive_children.map(&:label)}
    end
    value = {'phase' => phase, 'definitions' => observations, 'lookup' => podfile.target_definitions.transform_values(&:label),
             'installation_results_nil' => installer.target_installation_results.nil?}
    File.open('tree-api.jsonl', 'a') { |file| file.puts(JSON.generate(value)) }
    if phase == 'post_install'
      installer.aggregate_targets.each do |aggregate|
        definition = definitions.find { |candidate| candidate.label == aggregate.label }
        raise 'Aggregate lost its declaration identity' unless definition.equal?(aggregate.target_definition)
        aggregate.user_targets.each do |target|
          target.build_configurations.each { |configuration| configuration.build_settings['TREE_HOOK'] = definition.label }
        end
      end
    end
  end
end
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--gem-home", type=Path)
    args = parser.parse_args()
    parent = Path(tempfile.mkdtemp(prefix="native-compatibility-", dir=ROOT / ".build"))
    print("Compatibility regressions:", parent, flush=True)
    native_env = environment()
    native_env["SWIFTPODS_CACHE_ROOT"] = str(parent / "native-cache")
    ruby, reference_env = (
        reference_environment(args.gem_home, parent) if args.gem_home else (None, None)
    )
    binary = ROOT / ".build/debug/swiftpods"

    def native(work, *arguments, success=True):
        result = subprocess.run(
            [str(binary), *arguments, "--json"],
            cwd=work,
            env=native_env,
            capture_output=True,
            text=True,
            timeout=90,
        )
        (work / "native-last.log").write_text(result.stdout + result.stderr)
        assert (result.returncode == 0) == success, (
            arguments,
            result.stdout[-3000:],
            result.stderr[-3000:],
        )
        return json.loads(result.stdout)

    def reference(work, *arguments, success=True):
        code = "require 'bundler/setup';require 'cocoapods';Pod::Command.run(ARGV)"
        result = subprocess.run(
            [ruby, "-e", code, "--", *arguments, "--no-ansi"],
            cwd=work,
            env=reference_env,
            capture_output=True,
            text=True,
            timeout=120,
        )
        (work / "reference-last.log").write_text(result.stdout + result.stderr)
        assert (result.returncode == 0) == success, (
            arguments,
            result.stdout[-3000:],
            result.stderr[-3000:],
        )
        return result

    def git(path, *arguments):
        return subprocess.check_output(
            ["git", "-C", str(path), *arguments], stderr=subprocess.STDOUT, text=True
        ).strip()

    def repository(path):
        path.mkdir()
        (path / "README").write_text("isolated test fixture\n")
        git(path, "init")
        commit(path)

    def commit(path):
        git(path, "add", ".")
        git(
            path,
            "-c",
            "user.name=SwiftPods Tests",
            "-c",
            "user.email=tests@example.invalid",
            "commit",
            "-m",
            "fixture",
        )

    source = parent / "source"
    repository(source)
    (source / "source.c").write_text("int compatibility_kit(void) { return 1; }\n")
    commit(source)
    revision = git(source, "rev-parse", "HEAD")
    first, second = parent / "first.git", parent / "second.git"
    for path in [first, second]:
        repository(path)

    def spec(repo, name, version, marker, dependencies=None):
        file = repo / name / version / (name + ".podspec.json")
        file.parent.mkdir(parents=True, exist_ok=True)
        value = {
            "name": name,
            "version": version,
            "summary": marker,
            "homepage": "https://swiftpods.org",
            "authors": "Tests",
            "license": "MIT",
            "source": {"git": str(source), "commit": revision},
            "source_files": "*.c",
            "platforms": {"osx": "13.0"},
            "dependencies": dependencies or {},
        }
        file.write_text(json.dumps(value))
        commit(repo)

    spec(second, "Kit", "1.0", "locked-second")
    engines = ["native", "reference"] if args.gem_home else ["native"]
    projects = {}

    def manifest(work, feature=False):
        (work / "Podfile").write_text(
            "platform :osx, '13.0'\ninstall! 'cocoapods', :integrate_targets => false\nsource "
            + repr(first.as_uri())
            + "\nsource "
            + repr(second.as_uri())
            + "\ntarget 'App' do\n pod 'Kit'\n"
            + (" pod 'Feature'\n" if feature else "")
            + "end\npre_install { |installer| File.write('selected-specs.json', JSON.generate(installer.pod_targets.to_h { |target| [target.pod_name, target.root_spec.summary] })) }\n"
        )

    for engine in engines:
        work = parent / engine
        work.mkdir()
        projects[engine] = work
        manifest(work)
        (native if engine == "native" else reference)(work, "install")
    spec(first, "Kit", "1.0", "earlier-first")
    for engine, work in projects.items():
        (native if engine == "native" else reference)(work, "install", "--repo-update")
        installed = json.loads((work / "selected-specs.json").read_text())
        assert installed["Kit"] == "locked-second", (engine, installed)
    # A newly added dependency cannot silently upgrade an unchanged locked pod.
    spec(second, "Kit", "2.0", "new-version")
    spec(second, "Feature", "1.0", "requires-new-kit", {"Kit": [">= 2"]})
    for engine, work in projects.items():
        previous = (work / "Podfile.lock").read_bytes()
        manifest(work, feature=True)
        (native if engine == "native" else reference)(
            work, "install", "--repo-update", success=False
        )
        assert (work / "Podfile.lock").read_bytes() == previous
    # Non-source options cannot enable prerelease candidates.
    prerelease = parent / "prerelease"
    prerelease.mkdir()
    spec(second, "PreviewKit", "1.0", "stable")
    spec(second, "PreviewKit", "2.0.pre", "preview")
    for options in [
        "",
        ", :inhibit_warnings => true",
        ", :modular_headers => true",
        ", :configurations => ['Debug']",
    ]:
        (prerelease / "Podfile").write_text(
            "platform :osx, '13.0'\nsource "
            + repr(second.as_uri())
            + "\ntarget 'App' do\n pod 'PreviewKit'"
            + options
            + "\nend\n"
        )
        report = native(prerelease, "outdated", "--no-integrate")
        available = next(
            event["pods"] for event in report["events"] if event["kind"] == "outdated"
        )
        assert available[0]["available"] == "1.0", available
    if args.gem_home:
        code = "require 'bundler/setup';require 'cocoapods';p=Pod::Podfile.new { target('App') { pod 'PreviewKit', :inhibit_warnings=>true } };s=Pod::Spec.new { |v| v.name='PreviewKit';v.version='2.0.pre' };abort('Unexpected prerelease acceptance') if Pod::Resolver.allocate.send(:valid_possibility_version_for_root_name?,p.dependencies.first,Molinillo::DependencyGraph.new,s)"
        subprocess.run(
            [ruby, "-e", code], cwd=parent, env=reference_env, check=True, timeout=30
        )

    def pin(work, name):
        match = re.search(
            r"^\s+- ['\"]?" + re.escape(name) + r" \(([0-9][0-9A-Za-z.-]*)\)",
            (work / "Podfile.lock").read_text(),
            re.MULTILINE,
        )
        assert match, (work, name)
        return match[1]

    # Relaxing a requirement keeps a compatible installed version locked.
    for engine in engines:
        work = parent / ("relaxed-" + engine)
        work.mkdir()
        text = (
            "platform :osx, '13.0'\ninstall! 'cocoapods', :integrate_targets => false\nsource "
            + repr(second.as_uri())
            + "\ntarget 'App' do\n pod 'Kit', '= 1.0'\nend\n"
        )
        (work / "Podfile").write_text(text)
        (native if engine == "native" else reference)(work, "install", "--repo-update")
        (work / "Podfile").write_text(text.replace(", '= 1.0'", ""))
        (native if engine == "native" else reference)(work, "install")
        assert pin(work, "Kit") == "1.0"
        work = parent / ("removed-prerelease-" + engine)
        work.mkdir()
        text = text.replace("'Kit', '= 1.0'", "'PreviewKit', '= 2.0.pre'")
        (work / "Podfile").write_text(text)
        (native if engine == "native" else reference)(work, "install", "--repo-update")
        locked = (work / "Podfile.lock").read_bytes()
        (work / "Podfile").write_text(text.replace(", '= 2.0.pre'", ""))
        (native if engine == "native" else reference)(work, "install", success=False)
        assert (work / "Podfile.lock").read_bytes() == locked
        arguments = ["update", "PreviewKit"] + (
            ["--repo-update"] if engine == "native" else []
        )
        (native if engine == "native" else reference)(work, *arguments)
        assert pin(work, "PreviewKit") == "1.0"
    # A shared dependency remains pinned until explicitly selected for update.
    spec(second, "SharedKit", "1.0", "shared")
    spec(second, "RootA", "1.0", "first", {"SharedKit": [">= 1"]})
    spec(second, "RootB", "1.0", "second", {"SharedKit": [">= 0.5"]})
    shared = {}
    for engine in engines:
        work = parent / ("shared-" + engine)
        work.mkdir()
        shared[engine] = work
        text = (
            "platform :osx, '13.0'\ninstall! 'cocoapods', :integrate_targets => false\nsource "
            + repr(second.as_uri())
            + "\ntarget 'App' do\n pod 'RootA'\n pod 'RootB'\nend\n"
        )
        (work / "Podfile").write_text(text)
        (native if engine == "native" else reference)(work, "install", "--repo-update")
    spec(second, "SharedKit", "2.0", "new-shared")
    for engine, work in shared.items():
        text = (work / "Podfile").read_text()
        locked = (work / "Podfile.lock").read_bytes()
        (work / "Podfile").write_text(
            text.replace("end\n", " pod 'SharedKit', '>= 2'\nend\n")
        )
        (native if engine == "native" else reference)(
            work, "install", "--repo-update", success=False
        )
        assert (work / "Podfile.lock").read_bytes() == locked
        (work / "Podfile").write_text(text)
    spec(second, "RootA", "2.0", "needs-new-shared", {"SharedKit": [">= 2"]})
    for engine, work in shared.items():
        arguments = ["update", "RootA"] + (
            ["--repo-update"] if engine == "native" else []
        )
        (native if engine == "native" else reference)(work, *arguments)
        assert (
            pin(work, "RootA") == "1.0"
            and pin(work, "SharedKit") == "1.0"
            and pin(work, "RootB") == "1.0"
        )
        arguments = ["update", "RootA", "SharedKit"] + (
            ["--repo-update"] if engine == "native" else []
        )
        (native if engine == "native" else reference)(work, *arguments)
        assert (
            pin(work, "RootA") == "2.0"
            and pin(work, "SharedKit") == "2.0"
            and pin(work, "RootB") == "1.0"
        )
    # Keep both parents when lock dependency strings are identical. The reference
    # loses the second edge; native intentionally preserves the unchanged parent.
    spec(second, "SameShared", "1.0", "same-shared")
    spec(second, "SameA", "1.0", "same-a", {"SameShared": [">= 1"]})
    spec(second, "SameB", "1.0", "same-b", {"SameShared": [">= 1"]})
    repeated = {}
    for engine in engines:
        work = parent / ("same-edge-" + engine)
        work.mkdir()
        repeated[engine] = work
        (work / "Podfile").write_text(
            "platform :osx, '13.0'\ninstall! 'cocoapods', :integrate_targets => false\nsource "
            + repr(second.as_uri())
            + "\ntarget 'App' do\n pod 'SameA'\n pod 'SameB'\nend\n"
        )
        (native if engine == "native" else reference)(work, "install", "--repo-update")
    spec(second, "SameShared", "2.0", "new-same-shared")
    spec(second, "SameA", "2.0", "new-same-a", {"SameShared": [">= 2"]})
    for engine, work in repeated.items():
        arguments = ["update", "SameA"] + (
            ["--repo-update"] if engine == "native" else []
        )
        (native if engine == "native" else reference)(work, *arguments)
        expected = "1.0" if engine == "native" else "2.0"
        assert (
            pin(work, "SameA") == expected
            and pin(work, "SameShared") == expected
            and pin(work, "SameB") == "1.0"
        )
        arguments = ["update", "SameA", "SameShared"] + (
            ["--repo-update"] if engine == "native" else []
        )
        (native if engine == "native" else reference)(work, *arguments)
        assert (
            pin(work, "SameA") == "2.0"
            and pin(work, "SameShared") == "2.0"
            and pin(work, "SameB") == "1.0"
        )
    filekit = parent / "FileKit"
    (filekit / "Sources/Nested").mkdir(parents=True)
    (filekit / "Resources").mkdir()
    for name in [
        "Public.h",
        "Private.hpp",
        "Project.hxx",
        "Implementation.m",
        "Excluded.h",
        "Nested/Inline.ipp",
    ]:
        (filekit / "Sources" / name).write_text("// fixture\n")
    for name in ["kept.txt", "excluded.txt", "tagged.txt"]:
        (filekit / "Resources" / name).write_text(name)
    value = {
        "name": "FileKit",
        "version": "1.0",
        "summary": "Public file API",
        "homepage": "https://swiftpods.org",
        "authors": "Tests",
        "license": "MIT",
        "source": {"git": str(source)},
        "platforms": {"osx": "13.0"},
        "source_files": ["Sources", "Sources/Nested"],
        "public_header_files": [],
        "private_header_files": "Sources/Private.hpp",
        "project_header_files": "Sources/Project.hxx",
        "exclude_files": ["Sources/Excluded.h", "Resources/excluded.txt"],
        "requires_arc": "Sources/*.m",
        "resources": "Resources/*.txt",
        "resource_bundles": {"Data": ["Resources/*.txt"]},
        "on_demand_resources": {
            "Tag": {"paths": ["Resources/tagged.txt"], "category": "initial_install"}
        },
    }
    (filekit / "FileKit.podspec.json").write_text(json.dumps(value))
    observations = {}
    for engine in engines:
        work = parent / ("files-" + engine)
        work.mkdir()
        (work / "Podfile").write_text(
            "platform :osx, '13.0'\ninstall! 'cocoapods', :integrate_targets => false\nsource "
            + repr(second.as_uri())
            + "\ntarget 'App' do\n pod 'FileKit', :path => '../FileKit'\nend\n"
            + FILE_API
        )
        (native if engine == "native" else reference)(work, "install")
        observations[engine] = json.loads((work / "file-api.json").read_text())
        observations[engine]["project_api"] = json.loads(
            (work / "project-api.json").read_text()
        )
        assert observations[engine]["public_headers"] == [
            "Sources/Nested/Inline.ipp",
            "Sources/Public.h",
        ], observations[engine]
        assert (
            "Resources/excluded.txt"
            not in observations[engine]["resource_bundle_files"]
        )
    if args.gem_home:
        assert observations["native"] == observations["reference"], observations
    trees = {}
    for engine in engines:
        work = parent / ("tree-" + engine)
        work.mkdir()
        for folder in ["Left", "Right"]:
            directory = work / folder
            directory.mkdir()
            user_project(directory, "App")
        declaration = "platform :osx, '13.0'\nworkspace 'Tree'\n"
        for folder in ["Left", "Right"]:
            declaration += (
                "abstract_target '"
                + folder
                + "' do\n project '"
                + folder
                + "/App.xcodeproj'\n target('App') {}\nend\n"
            )
        (work / "Podfile").write_text(declaration + TARGET_TREE_API)
        (native if engine == "native" else reference)(work, "install")
        trees[engine] = [
            json.loads(line)
            for line in (work / "tree-api.jsonl").read_text().splitlines()
        ]
        assert [value["phase"] for value in trees[engine]] == [
            "pre_install",
            "pre_integrate",
            "post_install",
            "post_integrate",
        ]
        assert [value["installation_results_nil"] for value in trees[engine]] == [
            True,
            True,
            False,
            False,
        ]
        assert trees[engine][0]["lookup"] == {
            "Pods": "Pods",
            "Left": "Pods-Left",
            "Right": "Pods-Right",
            "App": "Pods-Right-App",
        }
        for folder in ["Left", "Right"]:
            graph = json.loads(
                subprocess.check_output(
                    [
                        "plutil",
                        "-convert",
                        "json",
                        "-o",
                        "-",
                        str(work / folder / "App.xcodeproj/project.pbxproj"),
                    ]
                )
            )
            configurations = [
                value["buildSettings"]
                for value in graph["objects"].values()
                if value["isa"] == "XCBuildConfiguration"
                and value["buildSettings"].get("PRODUCT_NAME") == "App"
            ]
            assert configurations and all(
                value["TREE_HOOK"] == "Pods-" + folder + "-App"
                for value in configurations
            )
        skipped = parent / ("tree-skipped-" + engine)
        skipped.mkdir()
        (skipped / "Podfile").write_text(
            "platform :osx, '13.0'\ninstall! 'cocoapods', :integrate_targets => false, :skip_pods_project_generation => true\ntarget('App') {}\n"
            + TARGET_TREE_API
        )
        (native if engine == "native" else reference)(skipped, "install")
        values = [
            json.loads(line)
            for line in (skipped / "tree-api.jsonl").read_text().splitlines()
        ]
        assert [value["phase"] for value in values] == [
            "pre_install",
            "post_install",
        ] and all(value["installation_results_nil"] for value in values)
    if args.gem_home:
        assert trees["native"] == trees["reference"], trees
    # A lockfile edit during a hook must survive install failure and recovery.
    work = parent / "lock-conflict"
    work.mkdir()
    (work / "Podfile").write_text(
        "platform :osx, '13.0'\ninstall! 'cocoapods', :integrate_targets => false\nsource "
        + repr(second.as_uri())
        + "\ntarget 'App' do\n pod 'FileKit', :path => '../FileKit'\nend\npost_install { File.write('Podfile.lock', 'external-edit') }\n"
    )
    rejected = native(work, "install", success=False)
    assert any(event.get("code") == "SP-LOCK-CONFLICT" for event in rejected["events"])
    native(work, "recover")
    assert (work / "Podfile.lock").read_text() == "external-edit"
    duplicate_cases = []
    for phase in ["pre_integrate", "post_install", "post_integrate"]:
        work = parent / ("duplicate-" + phase)
        work.mkdir()
        podfile = work / "Podfile"
        podfile.write_text(phase + " {}\n" + phase + " {}\n")
        rejected = native(work, "ipc", "podfile", str(podfile), success=False)
        assert any(
            "Specifying multiple" in event.get("message", "")
            for event in rejected["events"]
        ), rejected
        assert not (work / ".swiftpods").exists()
        if args.gem_home:
            result = subprocess.run(
                [
                    ruby,
                    "-e",
                    "require 'bundler/setup';require 'cocoapods';Pod::Podfile.from_file(ARGV.fetch(0))",
                    str(podfile),
                ],
                cwd=work,
                env=reference_env,
                capture_output=True,
                text=True,
                timeout=30,
            )
            assert result.returncode != 0 and "Specifying multiple" in result.stderr, (
                result.stderr
            )
        duplicate_cases.append("Podfile.reject_duplicate_" + phase)
    work = parent / "duplicate-pre_install"
    work.mkdir()
    podfile = work / "Podfile"
    podfile.write_text(
        "platform :osx, '13.0'\ninstall! 'cocoapods', :integrate_targets => false\ntarget('App') {}\npre_install { File.write('last-hook.txt', 'first') }\npre_install { File.write('last-hook.txt', 'second') }\n"
    )
    native(work, "install")
    assert (work / "last-hook.txt").read_text() == "second"
    if args.gem_home:
        (work / "last-hook.txt").unlink()
        subprocess.run(
            [
                ruby,
                "-e",
                "require 'bundler/setup';require 'cocoapods';Pod::Podfile.from_file(ARGV.fetch(0)).pre_install!(nil)",
                str(podfile),
            ],
            cwd=work,
            env=reference_env,
            check=True,
            timeout=30,
        )
        assert (work / "last-hook.txt").read_text() == "second"
    duplicate_cases.append("Podfile.replace_duplicate_pre_install")
    inheritance = inheritance_case(parent / "none-own-native", native, native_env)
    assert inheritance["build_status"] == 0 and not inheritance["diagnostics"], (
        inheritance
    )
    if args.gem_home:
        baseline_inheritance = inheritance_case(
            parent / "none-own-reference", reference, reference_env
        )
        assert baseline_inheritance["input_sha256"] == inheritance["input_sha256"]
        assert baseline_inheritance["build_status"] == 65 and any(
            "Undefined symbols" in value
            for value in baseline_inheritance["diagnostics"]
        ), baseline_inheritance
    checkout_cases = {}
    baseline_checkouts = {}
    for vcs in ["git", "hg"]:
        observed = mutable_checkout_case(
            parent / ("mutable-native-" + vcs), native, native_env, vcs
        )
        assert (
            observed["preserved"]
            and observed["deployment_preserved"]
            and observed["immutable_lock"]
            and observed["unchanged_lock"]
            and observed["updated"]
        ), observed
        checkout_cases[vcs] = observed
        if args.gem_home:
            baseline = mutable_checkout_case(
                parent / ("mutable-reference-" + vcs), reference, reference_env, vcs
            )
            assert baseline["input_sha256"] == observed["input_sha256"], (
                observed,
                baseline,
            )
            assert (
                not baseline["preserved"]
                and not baseline["deployment_preserved"]
                and not baseline["immutable_lock"]
                and baseline["updated"]
            ), baseline
            baseline_checkouts[vcs] = baseline
    verified = [
        "locked spec repository preserved when an earlier source gains the same version",
        "unchanged version pin remains a constraint when a new dependency conflicts",
        "warning/modular/configuration options do not enable prereleases",
        "public hook FileAccessor delegates to native file selection",
        "empty public patterns retain visible headers",
        "private/project/excluded/nested headers",
        "ARC selection",
        "resource bundles and ODR exclusions",
        "external lockfile edit survives failed install and recovery",
    ]
    verified += [
        "compatible requirement edits retain installed version pins",
        "removing a prerelease requirement conflicts with its locked prerelease; explicit update selects a stable version",
        "new direct declaration does not unlock an existing transitive dependency",
        "targeted update keeps distinct shared edges pinned; explicitly selecting the shared dependency unlocks it",
        "targeted update preserves identical shared edges until the shared dependency is explicitly selected",
    ]
    cases = [
        "FileAccessor." + name
        for name in [
            "source_files",
            "headers",
            "public_headers",
            "private_headers",
            "project_headers",
            "arc_source_files",
            "non_arc_source_files",
            "resources",
            "resource_bundles",
            "resource_bundle_files",
            "on_demand_resources",
            "on_demand_resources_files",
            "root",
            "spec",
            "platform_name",
        ]
    ]
    cases += [
        "Project." + name
        for name in [
            "new",
            "new_target",
            "new_group",
            "new_file",
            "save",
            "unknown_setter_rejected",
        ]
    ]
    cases += duplicate_cases
    cases += ["HookValues.unknown_getter_rejected"]
    cases += [
        "Podfile." + name
        for name in [
            "target_definitions",
            "target_definition_list",
            "root_target_definitions",
        ]
    ]
    cases += [
        "TargetDefinition." + name
        for name in [
            "parent",
            "children",
            "recursive_children",
            "root",
            "root?",
            "podfile",
        ]
    ]
    cases += ["Installer.target_installation_results_lifecycle"]
    cases += ["Resolver.shared_pins_preserved", "Resolver.shared_pins_explicit_update"]
    cases += [
        "Targets.none_own_dependency_input",
        "Targets.none_own_dependency_enabled",
    ]
    cases += [
        "Sources.mutable_checkout_input",
        "Sources.mutable_checkout_pinned",
        "Sources.mutable_checkout_explicit_update",
    ]
    verified += [
        "explicit symbolic Git/Mercurial selectors retain immutable checkout pins until update"
    ]
    verified += [
        "full root/abstract/concrete target tree with stable object identities across all four hooks",
        "same-named targets in separate projects preserve their distinct hook mutations",
        "installation results remain nil before generation and when generation is skipped",
    ]
    glob_values = character_class_parity(parent, engines, native, reference)
    scalar_globs = scalar_parity(parent, engines, native, reference)
    unicode_paths = path_parity(parent, engines, native, reference)
    unicode_names = name_parity(parent, engines, native, reference)
    verified += [
        "Unicode filesystem components preserve source selection, header mapping, cleanup and symlinks"
    ]
    cases += [
        "Glob.class_input",
        "Glob.literal_members",
        "Glob.path_boundaries",
        "Glob.complete_names",
        "Glob.case_folding",
    ]
    verified += [
        "glob character classes preserve literal members, ranges and path boundaries",
        "glob matches complete filenames and preserves exclusions, visibility and resources",
    ]
    serialized_values = serialized_input_parity(parent, engines, native, reference)
    structured_values = structured_input_parity(parent, engines, native, reference)
    scheme_values = scheme_whitespace_parity(parent, engines, native, reference)
    cases += ["Scheme.whitespace_input", "Scheme.whitespace_serialization"]
    verified += ["scheme XML preserves launch arguments and environment whitespace"]
    cases += [
        "ScriptPhases.boolean_log_visibility_input",
        "ScriptPhases.boolean_log_visibility_effect",
    ]
    cases += [
        "Specification.source",
        "Specification.license",
        "Specification.consumer",
        "Consumer.source",
        "Consumer.license",
        "Consumer.version",
        "Consumer.swift_versions",
        "Consumer.authors",
        "Consumer.screenshots",
        "Consumer.deprecated?",
        "Consumer.static_framework",
        "Consumer.base_name",
        "Consumer.platform_validation",
        "Consumer.stable_identity",
    ]
    verified += [
        "serialized numeric dependency requirements, Swift versions and invalid attribute containers"
    ]
    report = {
        "status": "passed",
        "engine": "swift",
        "fixture": str(parent),
        "verified": verified,
        "verified_cases": cases,
        "none_own_dependency": inheritance,
        "mutable_checkout_inputs": checkout_cases,
        "serialized_values": serialized_values,
        "structured_values": structured_values,
        "scheme_whitespace": scheme_values,
        "glob_character_classes": glob_values,
        "scalar_globs": scalar_globs,
        "unicode_paths": unicode_paths,
        "unicode_names": unicode_names,
        "unverified": ["arbitrary private plugin APIs", "remote authenticated sources"],
    }
    name = (
        "native-compatibility-reference.json"
        if args.gem_home
        else "native-compatibility.json"
    )
    if args.gem_home:
        report["reference"] = "1.17.0"
        report["differences"] = [
            {
                "id": "Glob.character_class_matching",
                "feature": "Glob",
                "reference": "Ruby 3.4.11 includes implicit closing delimiters and inconsistently folds class members and range endpoints",
                "native": "uses declared literal members and consistent case-insensitive ranges for unchanged patterns",
                "parity": False,
                "observation": {
                    key: glob_values[key]
                    for key in [
                        "literal-opening",
                        "literal-set",
                        "escaped-letter",
                        "unicode-class",
                        "literal-casefold",
                        "mixed-descending",
                        "mixed-descending-other",
                    ]
                },
            },
            {
                "id": "Scheme.XML_whitespace",
                "feature": "Scheme",
                "reference": "literal XML attribute whitespace is normalized to spaces",
                "native": "character references preserve unchanged arguments and environment values",
                "parity": False,
                "observation": scheme_values,
            },
            {
                "id": "ScriptPhases.boolean_log_visibility",
                "feature": "ScriptPhases",
                "reference": "accepts false but keeps environment logging enabled",
                "native": "accepts false and disables environment logging",
                "parity": False,
                "observation": {
                    engine: values[-1] for engine, values in structured_values.items()
                },
            },
            {
                "id": "Sources.mutable_checkout_pins",
                "feature": "Sources",
                "reference": "symbolic commit/revision selectors can change downloaded bytes during install and deployment",
                "native": "uses the immutable checkout recorded in lock until explicitly updated",
                "parity": False,
                "observation": baseline_checkouts,
            },
            {
                "id": "Targets.none_own_dependencies",
                "feature": "Targets",
                "reference": "none disables a child target's own unconfigured dependency",
                "native": "none restricts inheritance while preserving the child's own dependency",
                "parity": False,
                "observation": baseline_inheritance,
            },
            {
                "id": "Resolver.shared_dependency_pins",
                "feature": "Resolver",
                "reference": "identical lock edges lose the unchanged parent and unlock its shared dependency",
                "native": "retains every parent and keeps shared pins until explicitly included in the update",
                "parity": False,
            },
        ]
    (ROOT / "test-results" / name).write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    execute(
        main,
        (
            "native-compatibility-reference.json"
            if "--gem-home" in sys.argv
            else "native-compatibility.json"
        ),
    )
