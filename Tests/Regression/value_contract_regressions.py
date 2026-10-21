"""Exercise serialized versions, source language suffixes and graphic pod names."""

import json
import re
import subprocess

from Tests.Integration.native_xcconfig_tests import create
from Tests.Regression.catalog_build_regressions import (
    installed_version,
    module_consumer,
    source_phase_paths,
)
from Tests.Regression.consumer_build_regressions import (
    install_twice,
    podfile,
    update_spec,
)
from Tests.Regression.header_ownership_regressions import resources_in_app
from Tests.Regression.input_contract_regressions import commit, diagnostic, git
from Tests.Regression.workspace_resource_regressions import read_project


def rejected_before_hooks(fixture, work):
    marker = work / "pre-install-ran"
    report = fixture.cli(work, "install", succeeds=False)
    assert not marker.exists(), report
    assert report.get("project_state") != "recovery_required", report
    assert not (work / "Podfile.lock").exists()
    assert not (work / "Pods/Pods.xcodeproj").exists()
    return report


def numeric_dependencies(fixture):
    for index, requirement in enumerate([42, [42], ["= 42"]]):
        for version in ["42", "100.0"]:
            work, _ = create(fixture.root / f"numeric-dependency-{index}-{version}")
            data = update_spec(work, dependencies={"Helper": requirement})
            helper = work / "Helper"
            helper.mkdir()
            (helper / "Helper.c").write_text("int helper(void) { return 1; }\n")
            (helper / "Helper.podspec.json").write_text(
                json.dumps(dict(data, name="Helper", version=version, dependencies={}))
            )
            (work / "Podfile").write_text(
                "install! 'swiftpods', :integrate_targets => false\n"
                + podfile(work).replace(
                    " pod 'Kit', :path => './Kit'",
                    " pod 'Kit', :path => './Kit'\n pod 'Helper', :path => './Helper'",
                )
                + "pre_install { |_| File.write('pre-install-ran', 'yes') }\n"
            )
            if version == "42":
                report = fixture.cli(work, "install")
                assert installed_version(report, "Helper") == "42"
                fixture.cli(work, "install", "--deployment")
            else:
                rejected_before_hooks(fixture, work)
        fixture.verified.append(
            "numeric_dependency_requirement_is_binding_" + str(index)
        )


def numeric_platforms(fixture):
    work, _ = create(fixture.root / "numeric-platform-backtracking")
    origin = work / "Kit"
    git(origin, "init", "-b", "main")
    revision = commit(origin, "library source")
    catalog = work / "specs"
    for version, minimum in [("1.0", "13.0"), ("2.0", 14)]:
        path = catalog / "Kit" / version / "Kit.podspec.json"
        path.parent.mkdir(parents=True)
        path.write_text(
            json.dumps(
                {
                    "name": "Kit",
                    "version": version,
                    "platforms": {"osx": minimum},
                    "source_files": "*.c",
                    "source": {"git": str(origin), "commit": revision},
                }
            )
        )
    (work / "Podfile").write_text(
        "install! 'swiftpods', :integrate_targets => false\nsource "
        + repr(str(catalog))
        + "\nplatform :osx, '13.0'\ntarget 'Demo' do\n pod 'Kit'\nend\n"
    )
    assert installed_version(fixture.cli(work, "install"), "Kit") == "1.0"
    fixture.cli(work, "install", "--deployment")
    fixture.verified.append("numeric_platform_minimum_backtracks_before_installation")

    for index, platforms in enumerate([{"osx": 14}, "ios", ["ios", "tvos"]]):
        work, _ = create(fixture.root / ("unsupported-platform-" + str(index)))
        update_spec(work, platforms=platforms)
        (work / "Podfile").write_text(
            podfile(work) + "pre_install { |_| File.write('pre-install-ran', 'yes') }\n"
        )
        rejected_before_hooks(fixture, work)
    fixture.verified.append(
        "numeric_and_string_platforms_and_malformed_arrays_fail_before_hooks"
    )


def numeric_swift_versions(fixture):
    work, selected = create(fixture.root / "numeric-swift-versions")
    update_spec(work, swift_versions=["4.2", 5], source_files="*.{c,h,swift}")
    (work / "Kit/Value.swift").write_text(
        "import AppIntents\nstruct NumericValueIntent: AppIntent {\n"
        ' static var title: LocalizedStringResource = "Numeric value"\n'
        " func perform() async throws -> some IntentResult & ReturnsValue<Int> { .result(value: 7) }\n}\n"
    )
    (work / "Podfile").write_text(
        "use_frameworks!\n"
        + podfile(work).replace(
            "target 'Demo' do\n", "target 'Demo' do\n supports_swift_versions '>= 5'\n"
        )
        + """post_install do |installer|
  target = installer.pod_targets.first
  spec = target.root_spec
  raise 'Raw numeric Swift version was rewritten' unless spec.attributes_hash['swift_versions'].last.is_a?(Integer)
  raise 'Swift version getter lost numeric value' unless spec.swift_versions.map(&:to_s) == ['4.2', '5']
  raise 'Swift version was not selected' unless target.native_target.build_configurations.all? { |c| c.build_settings['SWIFT_VERSION'] == '5' }
end
"""
    )
    module_consumer(selected, "Kit", "kit_value() == 7 ? 0 : 1")
    install_twice(fixture, work)
    label = "numeric-swift-versions-build"
    fixture.build(work, "Demo", label)
    subprocess.run(
        [str(resources_in_app(fixture, label) / "Contents/MacOS/Demo")], check=True
    )
    fixture.verified.append(
        "numeric_swift_versions_select_compile_and_preserve_raw_hook_attributes"
    )
    path = work / "Kit/Kit.podspec.json"
    data = json.loads(path.read_text())
    del data["swift_versions"]
    data["swift_version"] = 5
    path.write_text(json.dumps(data))
    manifest = (
        (work / "Podfile")
        .read_text()
        .replace(
            "spec.attributes_hash['swift_versions'].last.is_a?(Integer)",
            "spec.attributes_hash['swift_version'].is_a?(Integer)",
        )
        .replace("== ['4.2', '5']", "== ['5']")
    )
    (work / "Podfile").write_text(manifest)
    fixture.cli(work, "install")
    fixture.cli(work, "install", "--deployment")
    fixture.build(work, "Demo", "numeric-singular-swift-version-build")
    fixture.verified.append(
        "numeric_singular_swift_version_selects_and_compiles_without_rewriting_hooks"
    )


def uppercase_source_languages(fixture):
    for extension, pattern, filetype in [
        ("C", "*.{c,h}", "sourcecode.cpp.cpp"),
        ("M", "*.{m,h}", "sourcecode.cpp.objcpp"),
    ]:
        work, _ = create(fixture.root / ("uppercase-source-" + extension))
        (work / "Kit/Kit.c").unlink()
        (work / ("Kit/Kit." + extension)).write_text(
            "#ifndef __cplusplus\n#error This file must compile as C++\n#endif\n"
            'extern "C" int kit_value(void) { return 7; }\n'
        )
        update_spec(work, source_files=pattern)
        (work / "Podfile").write_text(podfile(work))
        install_twice(fixture, work)
        assert any(
            path.endswith("/Kit." + extension) for path in source_phase_paths(work)
        )
        objects = read_project(work / "Pods/Pods.xcodeproj")["objects"]
        assert any(
            value.get("path", "").endswith("/Kit." + extension)
            and value.get("lastKnownFileType") == filetype
            for value in objects.values()
        )
        label = "uppercase-source-build-" + extension
        fixture.build(work, "Demo", label)
        subprocess.run(
            [str(resources_in_app(fixture, label) / "Contents/MacOS/Demo")], check=True
        )
        fixture.verified.append(
            "uppercase_" + extension + "_source_compiles_links_and_runs"
        )


def graphic_names(fixture):
    for index, (name, module) in enumerate(
        [
            ("Kit@Core", "Kit_Core"),
            ("📦Kit", "_Kit"),
            ("Kit's", "Kit_s"),
        ]
    ):
        work, selected = create(fixture.root / ("graphic-name-" + str(index)))
        original = work / "Kit/Kit.podspec.json"
        data = json.loads(original.read_text())
        original.unlink()
        (work / "Kit" / (name + ".podspec.json")).write_text(
            json.dumps(dict(data, name=name), ensure_ascii=False)
        )
        (work / "Podfile").write_text(
            "use_frameworks!\n"
            + podfile(work).replace(
                "pod 'Kit'", "pod " + json.dumps(name, ensure_ascii=False)
            )
        )
        module_consumer(selected, module, "kit_value() == 7 ? 0 : 1")
        install_twice(fixture, work)
        label = "graphic-name-build-" + str(index)
        fixture.build(work, "Demo", label)
        subprocess.run(
            [str(resources_in_app(fixture, label) / "Contents/MacOS/Demo")], check=True
        )
        fixture.verified.append(
            "graphic_pod_name_preserves_module_build_and_lock_" + str(index)
        )


def malformed_containers(fixture):
    cases = [
        {"dependencies": "Ignored"},
        {"source": {"git": 42, "tag": "1.0"}},
        {"pod_target_xcconfig": "FLAG=1"},
        {"resource_bundles": "Resources/*.png"},
        {"resource_bundles": {"Bundle": [42]}},
        {"testspecs": [{"name": "T", "osx": {"deployment_target": {"invalid": True}}}]},
    ]
    for index, changes in enumerate(cases):
        work, _ = create(fixture.root / ("malformed-container-" + str(index)))
        path = work / "Kit/Kit.podspec.json"
        original = json.loads(path.read_text())
        path.write_text(json.dumps(dict(original, **changes)))
        (work / "Podfile").write_text(
            podfile(work) + "pre_install { |_| File.write('pre-install-ran', 'yes') }\n"
        )
        rejected_before_hooks(fixture, work)
        for action in ["lib", "spec"]:
            report = fixture.cli(
                work, action, "lint", str(path), "--quick", succeeds=False
            )
            diagnostic(
                report,
                "SP-DSL-POD-OPTION"
                if "source" in changes
                else "SP-SPEC-ATTRIBUTE-TYPE",
            )
    fixture.verified.append(
        "malformed_serialized_containers_fail_quick_lint_and_install_before_hooks"
    )


def serialized_input_parity(parent, engines, native, reference):
    """Run the same serialized manifests through each CLI in an isolated directory."""
    origin, catalog = parent / "values-origin", parent / "values-catalog"
    origin.mkdir()
    (origin / "Kit.c").write_text("int kit_value(void) { return 7; }\n")
    git(origin, "init", "-b", "main")
    revision = commit(origin, "source")
    catalog.mkdir()
    git(catalog, "init", "-b", "main")
    for version, minimum in [("1.0", "13.0"), ("2.0", 14)]:
        path = catalog / "Kit" / version / "Kit.podspec.json"
        path.parent.mkdir(parents=True)
        path.write_text(
            json.dumps(
                {
                    "name": "Kit",
                    "version": version,
                    "platforms": {"osx": minimum},
                    "source_files": "*.c",
                    "source": {"git": str(origin), "commit": revision},
                }
            )
        )
    commit(catalog, "specifications")
    observations = {}
    for engine in engines:
        cli = native if engine == "native" else reference
        values = observations[engine] = []
        for index, requirement in enumerate([42, [42]]):
            for version in ["42", "100.0"]:
                work, _ = create(parent / f"values-{engine}-{index}-{version}")
                data = update_spec(work, dependencies={"Helper": requirement})
                helper = work / "Helper"
                helper.mkdir()
                (helper / "Helper.c").write_text("int helper(void) { return 1; }\n")
                (helper / "Helper.podspec.json").write_text(
                    json.dumps(
                        dict(data, name="Helper", version=version, dependencies={})
                    )
                )
                (work / "Podfile").write_text(
                    "install! 'cocoapods', :integrate_targets => false\n"
                    "platform :osx, '13.0'\ntarget 'Demo' do\n"
                    " pod 'Kit', :path => './Kit'\n pod 'Helper', :path => './Helper'\nend\n"
                )
                succeeds = version == "42"
                cli(work, "install", success=succeeds)
                values.append(
                    {
                        "requirement": requirement,
                        "helper_version": version,
                        "accepted": succeeds,
                    }
                )

        work, _ = create(parent / ("values-platform-" + engine))
        (work / "Podfile").write_text(
            "install! 'cocoapods', :integrate_targets => false\nsource "
            + repr(str(catalog))
            + "\nplatform :osx, '13.0'\ntarget 'Demo' do\n pod 'Kit'\nend\n"
        )
        cli(work, "install")
        assert re.search(r"- ['\"]?Kit \(1\.0\)", (work / "Podfile.lock").read_text())
        values.append({"numeric_platform_minimum": 14, "selected_version": "1.0"})

        for index, (changes, succeeds) in enumerate(
            [
                ({"swift_versions": [5]}, True),
                ({"swift_versions": ["4.2", 5]}, True),
                ({"swift_version": 5}, True),
                ({"swift_versions": 5}, False),
                ({"platforms": ["osx", "tvos"]}, False),
                ({"dependencies": "Ignored"}, False),
                ({"source": {"git": 42, "tag": "1.0"}}, False),
                ({"pod_target_xcconfig": "FLAG=1"}, False),
                ({"resource_bundles": "Resources/*.png"}, False),
                (
                    {
                        "testspecs": [
                            {
                                "name": "T",
                                "osx": {"deployment_target": {"invalid": True}},
                            }
                        ]
                    },
                    False,
                ),
            ]
        ):
            work, _ = create(parent / f"values-lint-{engine}-{index}")
            data = update_spec(work, **changes)
            data.update(
                summary="A useful fixture library.",
                license={"type": "MIT", "text": "MIT License"},
            )
            path = work / "Kit/Kit.podspec.json"
            path.write_text(json.dumps(data))
            cli(
                work,
                "lib",
                "lint",
                str(path),
                "--quick",
                "--allow-warnings",
                success=succeeds,
            )
            values.append({"attributes": changes, "accepted": succeeds})
        for index, name in enumerate(["Kit@Core", "📦Kit", "Kit's", ".Hidden"]):
            work, _ = create(parent / f"values-name-{engine}-{index}")
            old = work / "Kit/Kit.podspec.json"
            data = json.loads(old.read_text())
            old.unlink()
            data.update(
                name=name,
                summary="A useful fixture library.",
                license={"type": "MIT", "text": "MIT License"},
            )
            path = old.parent / (name + ".podspec.json")
            path.write_text(json.dumps(data, ensure_ascii=False))
            succeeds = name != ".Hidden"
            cli(
                work,
                "lib",
                "lint",
                str(path),
                "--quick",
                "--allow-warnings",
                success=succeeds,
            )
            values.append({"name": name, "accepted": succeeds})
    if "reference" in observations:
        assert observations["native"] == observations["reference"], observations
    return observations


def run(fixture):
    numeric_dependencies(fixture)
    numeric_platforms(fixture)
    numeric_swift_versions(fixture)
    uppercase_source_languages(fixture)
    graphic_names(fixture)
    malformed_containers(fixture)
