"""Consumer and protocol regressions for structured specification inputs."""

import json
import platform
import subprocess
import xml.etree.ElementTree as ET

from consumer_build_regressions import install_twice, podfile, update_spec
from header_ownership_regressions import resources_in_app
from input_contract_regressions import commit, git
from native_xcconfig_tests import create
from vendor_fixture import fixture_build_arguments, fixture_derived_data
from vendor_fixture import run as build
from workspace_resource_regressions import read_project

NUMERIC_SELECTORS = [1, 1.0, 3_826_980_940_661_245.5]
SCHEME_WHITESPACE_VALUES = [
    "tab\ttail",
    "line\ntail",
    "carriage\rtail",
    "pair\r\ntail",
    "xml &<\"'🧩東京",
    "literal &#9; &#10; &#13; \\t",
]


def scheme_environment():
    return {
        "SCHEME_VALUE_" + str(index): value
        for index, value in enumerate(SCHEME_WHITESPACE_VALUES)
    }


def scheme_values(path):
    tree = ET.parse(path).getroot()
    return {
        "arguments": [
            node.get("argument")
            for node in tree.findall(
                "LaunchAction/CommandLineArguments/CommandLineArgument"
            )
        ],
        "environment": {
            node.get("key"): node.get("value")
            for node in tree.findall(
                "LaunchAction/EnvironmentVariables/EnvironmentVariable"
            )
        },
    }


def scheme_whitespace_parity(parent, engines, native, reference):
    expected = {
        "arguments": SCHEME_WHITESPACE_VALUES,
        "environment": scheme_environment(),
    }
    observations = {}

    def normalized(value):
        return (
            value.replace("\r\n", " ")
            .replace("\t", " ")
            .replace("\r", " ")
            .replace("\n", " ")
        )

    for engine in engines:
        work, _ = create(parent / ("scheme-whitespace-" + engine))
        update_spec(
            work,
            scheme={
                "launch_arguments": expected["arguments"],
                "environment_variables": expected["environment"],
            },
        )
        source = work / "Kit/Kit.podspec.json"
        before = source.read_bytes()
        (work / "Podfile").write_text(
            "install! 'cocoapods', :integrate_targets => false, :share_schemes_for_development_pods => true\n"
            + podfile(work)
        )
        (native if engine == "native" else reference)(work, "install")
        assert source.read_bytes() == before
        observed = scheme_values(
            work / "Pods/Pods.xcodeproj/xcshareddata/xcschemes/Kit.xcscheme"
        )
        if engine == "native":
            assert observed == expected, observed
        else:
            assert observed == {
                "arguments": [normalized(value) for value in SCHEME_WHITESPACE_VALUES],
                "environment": {
                    key: normalized(value)
                    for key, value in scheme_environment().items()
                },
            }, observed
        observations[engine] = observed
    return {"input": expected, "observations": observations}


def source_fixture(root):
    work, _ = create(root)
    origin = work / "Kit"
    data = update_spec(work, source={"git": str(origin), "tag": 1.0})
    (origin / "LICENSE").write_text("MIT License\n")
    git(origin, "init", "-b", "main")
    first = commit(origin, "integer tag")
    git(origin, "tag", "1")
    (origin / "Kit.c").write_text("int kit_value(void) { return 9; }\n")
    second = commit(origin, "floating tag")
    git(origin, "tag", "1.0")
    git(origin, "tag", "3826980940661245.5")
    (origin / "Kit.c").write_text("int kit_value(void) { return 11; }\n")
    latest = commit(origin, "new head")
    return origin, data, first, second, latest


def numeric_source_case(parent, mode, field, value, origin, data):
    work, selected = create(parent)
    if mode == "external":
        source = ":git => " + repr(str(origin)) + ", :" + field + " => " + repr(value)
        manifest = podfile(work).replace(":path => './Kit'", source)
    else:
        catalog = work / "specs"
        catalog.mkdir()
        git(catalog, "init", "-b", "main")
        path = catalog / "Kit/1.0/Kit.podspec.json"
        path.parent.mkdir(parents=True)
        path.write_text(
            json.dumps(dict(data, source={"git": str(origin), field: value}))
        )
        commit(catalog, "specification")
        manifest = podfile(work).replace(" pod 'Kit', :path => './Kit'", " pod 'Kit'")
        manifest = "source " + repr(str(catalog)) + "\n" + manifest
    (work / "Podfile").write_text(
        manifest
        + """pre_install do |installer|
  spec = installer.pod_targets.first.root_spec
  consumer = spec.consumer(:osx)
  raise 'Consumer lost version object' unless consumer.version.is_a?(Pod::Version)
  raise 'Source getter lost Symbol keys' unless spec.source[:git]
  raise 'License getter lost Symbol keys' unless spec.license[:type] == 'MIT'
  values = spec.attributes_hash['source'].transform_values { |v| v.class.to_s }
  File.write('raw-types.json', JSON.generate(values))
end
"""
    )
    expected = 9 if isinstance(value, float) else 7
    main = selected.parent / "Sources/main.mm"
    main.write_text(
        main.read_text().replace(
            "return 0;", f"return kit_value() == {expected} ? 0 : 1;"
        )
    )
    return work


def numeric_selectors(fixture):
    origin, data, _, _, latest = source_fixture(fixture.root / "numeric-source-origin")
    floating = []
    for mode in ["external", "spec"]:
        for field in ["tag", "commit"]:
            for value in NUMERIC_SELECTORS:
                label = mode + "-" + field + "-" + repr(value)
                work = numeric_source_case(
                    fixture.root / ("numeric-source-" + label),
                    mode,
                    field,
                    value,
                    origin,
                    data,
                )
                install_twice(fixture, work)
                expected = 9 if isinstance(value, float) else 7
                assert f"return {expected};" in (work / "Pods/Kit/Kit.c").read_text()
                raw = json.loads((work / "raw-types.json").read_text())
                selector = "tag" if mode == "external" else field
                assert raw[selector] == (
                    "Float"
                    if mode == "external" or isinstance(value, float)
                    else "Integer"
                ), raw
                if field == "tag" and isinstance(value, float):
                    floating.append(work)
                    build_label = "numeric-source-build-" + mode + "-" + repr(value)
                    fixture.build(work, "Demo", build_label)
                    binary = (
                        resources_in_app(fixture, build_label) / "Contents/MacOS/Demo"
                    )
                    subprocess.run([str(binary)], check=True)
                fixture.verified.append(
                    "numeric_git_selector_selects_exact_source_and_preserves_hook_types_"
                    + label
                )
    for tag in ["1.0", "3826980940661245.5"]:
        git(origin, "tag", "-f", tag, latest)
    for index, work in enumerate(floating):
        locked = (work / "Podfile.lock").read_bytes()
        for flags in [[], ["--deployment"], ["--offline", "--deployment"]]:
            fixture.cli(work, "install", *flags)
            assert "return 9;" in (work / "Pods/Kit/Kit.c").read_text()
            assert (work / "Podfile.lock").read_bytes() == locked
        fixture.cli(work, "update", "Kit", "--no-repo-update")
        assert "return 11;" in (work / "Pods/Kit/Kit.c").read_text()
        fixture.verified.append(
            "floating_git_selector_retains_immutable_pin_until_update_" + str(index)
        )


def malformed_structures(fixture):
    cases = [
        {"scheme": {"launch_arguments": "--invalid"}},
        {"scheme": {"code_coverage": 1}},
        {"testspecs": [{"name": "Tests", "scheme": {"parallelizable": 0}}]},
        {"scheme": {"environment_variables": {"VALUE": "head\x00tail"}}},
        {
            "testspecs": [
                {"name": "Tests", "scheme": {"launch_arguments": ["head\x0btail"]}}
            ]
        },
        {
            "appspecs": [
                {
                    "name": "App",
                    "scheme": {"build_configurations": {"Run": "head\ufffetail"}},
                }
            ]
        },
        {"scheme": {"environment_variables": {"head\x00tail": "valid"}}},
        {"script_phases": [{"name": "Missing"}]},
        {"script_phases": [{"name": "Unknown", "script": "true", "unknown": True}]},
        {"on_demand_resources": {"asset": {"paths": "*.txt", "category": 42}}},
        {"on_demand_resources": {"asset": {"paths": "*.txt", "category": "invalid"}}},
        {"default_subspecs": [42]},
        {"requires_arc": [42]},
        {"license": {"type": 42}},
        {"authors": [42]},
        {"appspecs": [{"name": "App", "info_plist": {"Field": None}}]},
    ]
    for index, changes in enumerate(cases):
        work, _ = create(fixture.root / ("structured-invalid-" + str(index)))
        path = work / "Kit/Kit.podspec.json"
        update_spec(work, **changes)
        (work / "Podfile").write_text(
            podfile(work) + "pre_install { |_| File.write('hook-ran', 'yes') }\n"
        )
        for action in ["lib", "spec"]:
            fixture.cli(work, action, "lint", str(path), "--quick", succeeds=False)
        report = fixture.cli(work, "install", succeeds=False)
        assert not (work / "hook-ran").exists(), report
        assert report.get("project_state") != "recovery_required", report
        assert not (work / "Pods/Pods.xcodeproj").exists()
        assert not (work / "Podfile.lock").exists()
    fixture.verified.append(
        "structured_declarations_fail_quick_lint_and_install_before_hooks"
    )
    fixture.verified.append(
        "scheme_invalid_xml_characters_fail_before_hooks_and_writes"
    )


def prefix_and_config_values(fixture):
    work, selected = create(fixture.root / "structured-prefix-config")
    update_spec(
        work,
        prefix_header_contents=["#define PREFIX_VALUE \\", 42],
        pod_target_xcconfig={
            "OPAQUE": {"nested": True},
            "VALUES": [42, "yes"],
            "FLOAT_VALUE": 1.0,
            "EMPTY": None,
        },
    )
    (work / "Kit/Kit.c").write_text(
        "#if PREFIX_VALUE != 42\n#error Prefix value was dropped\n#endif\n"
        "int kit_value(void) { return PREFIX_VALUE; }\n"
    )
    (selected.parent / "Sources/main.mm").write_text(
        "#include <Kit/Kit.h>\nint main(void) { return kit_value() == 42 ? 0 : 1; }\n"
    )
    (work / "Podfile").write_text(
        podfile(work)
        + """post_install do |installer|
  target = installer.pod_targets.first.native_target
  expected = { 'OPAQUE' => '{"nested" => true}', 'VALUES' => '42 yes', 'FLOAT_VALUE' => '1.0', 'EMPTY' => '' }
  expected.each do |key, value|
    observed = target.resolved_build_setting(key, true)
    raise "Incorrect config #{key}: #{observed}" unless observed.values.all? { |v| Array(v).join(' ') == value }
  end
end
"""
    )
    install_twice(fixture, work)
    fixture.build(work, "Demo", "structured-prefix-config-build")
    subprocess.run(
        [
            str(
                resources_in_app(fixture, "structured-prefix-config-build")
                / "Contents/MacOS/Demo"
            )
        ],
        check=True,
    )
    fixture.verified.append(
        "numeric_prefix_contents_and_opaque_config_values_build_and_run"
    )


def development_schemes(fixture):
    for multiple in [False, True]:
        label = "multiple" if multiple else "single"
        work, _ = create(fixture.root / ("structured-development-scheme-" + label))
        update_spec(
            work,
            scheme={
                "launch_arguments": [
                    "--fixture & value",
                    42,
                    *SCHEME_WHITESPACE_VALUES,
                ],
                "environment_variables": {
                    "RETRIES": 3,
                    "FLOAT": 1.0,
                    **scheme_environment(),
                },
                "code_coverage": True,
                "build_configurations": {
                    "Run": "Release",
                    "Test": "Release",
                    "Analyze": "Release",
                    "Archive": "Debug",
                },
            },
        )
        (work / "Podfile").write_text(
            "install! 'swiftpods', :share_schemes_for_development_pods => true, :generate_multiple_pod_projects => "
            + ("true" if multiple else "false")
            + "\n"
            + podfile(work)
        )
        install_twice(fixture, work)
        schemes = list((work / "Pods").rglob("Kit.xcscheme"))
        assert len(schemes) == 1, schemes
        scheme = ET.parse(schemes[0]).getroot()
        actions = [
            ("LaunchAction", "Release"),
            ("TestAction", "Release"),
            ("AnalyzeAction", "Release"),
            ("ArchiveAction", "Debug"),
        ]
        for action, value in actions:
            assert scheme.find(action).get("buildConfiguration") == value
        assert scheme.find("TestAction").get("codeCoverageEnabled") == "YES"
        arguments = scheme.findall(
            "LaunchAction/CommandLineArguments/CommandLineArgument"
        )
        environment = scheme.findall(
            "LaunchAction/EnvironmentVariables/EnvironmentVariable"
        )
        assert [item.get("argument") for item in arguments] == [
            "--fixture & value",
            "42",
            *SCHEME_WHITESPACE_VALUES,
        ]
        assert {item.get("key"): item.get("value") for item in environment} == {
            "RETRIES": "3",
            "FLOAT": "1.0",
            **scheme_environment(),
        }
        output = fixture.root / ("structured-scheme-archive-" + label)
        output.mkdir()
        archive_arguments = [
            arg
            for arg in fixture_build_arguments(output)
            if not str(arg).startswith("SYMROOT=")
        ]
        text = build(
            [
                "xcodebuild",
                "-project",
                schemes[0].parents[2],
                "-scheme",
                "Kit",
                "-destination",
                "generic/platform=macOS",
                *archive_arguments,
                "-archivePath",
                output / "Kit.xcarchive",
                "CODE_SIGNING_ALLOWED=NO",
                "SKIP_INSTALL=NO",
                "archive",
            ],
            work,
            fixture.root / ("structured-scheme-archive-" + label + ".log"),
        )
        assert "/Debug/Kit.build/" in text
        assert list(
            fixture_derived_data(output).glob("**/BuildProductsPath/Debug/libKit.a")
        )
        fixture.verified.append(
            "development_scheme_options_control_actual_archive_configuration_" + label
        )
    fixture.verified.append("scheme_xml_whitespace_preserved_for_development_pods")


def scheme_whitespace_execution(fixture):
    work, _ = create(fixture.root / "scheme-whitespace-execution")
    values = scheme_environment()
    update_spec(
        work,
        testspecs=[
            {
                "name": "Whitespace",
                "platforms": {"osx": "14.0"},
                "source_files": "SchemeWhitespaceTests.m",
                "scheme": {"environment_variables": values},
            }
        ],
    )
    source = "#import <XCTest/XCTest.h>\n@interface SchemeWhitespaceTests : XCTestCase @end\n@implementation SchemeWhitespaceTests\n- (void)testSchemeEnvironmentValues {\n"
    for key, value in values.items():
        source += f"XCTAssertEqualObjects(NSProcessInfo.processInfo.environment[@{json.dumps(key)}], @{json.dumps(value, ensure_ascii=False)});\n"
    (work / "Kit/SchemeWhitespaceTests.m").write_text(source + "}\n@end\n")
    (work / "Podfile").write_text(
        podfile(work).replace(
            "pod 'Kit', :path => './Kit'",
            "pod 'Kit', :path => './Kit', :testspecs => ['Whitespace']",
        )
    )
    install_twice(fixture, work)
    output = fixture.root / "scheme-whitespace-build"
    output.mkdir()
    for configuration in ["Debug", "Release"]:
        text = build(
            [
                "xcodebuild",
                "-project",
                "Pods/Pods.xcodeproj",
                "-scheme",
                "Kit-Unit-Whitespace",
                "-configuration",
                configuration,
                "-destination",
                "platform=macOS,arch=" + platform.machine(),
                *fixture_build_arguments(output),
                "CODE_SIGNING_ALLOWED=NO",
                "test",
            ],
            work,
            fixture.root / ("scheme-whitespace-" + configuration + ".log"),
            env=fixture.env,
        )
        assert "** TEST SUCCEEDED **" in text and "testSchemeEnvironmentValues" in text
    fixture.verified.append(
        "scheme_environment_whitespace_reaches_running_xctest_debug_release"
    )


def boolean_script_visibility(fixture):
    work, _ = create(fixture.root / "structured-script-visibility")
    update_spec(
        work,
        script_phases=[
            {
                "name": "Visibility",
                "script": 'printf ok > "${SCRIPT_OUTPUT_FILE_0}"',
                "show_env_vars_in_log": False,
                "output_files": ["$(DERIVED_FILE_DIR)/visibility.txt"],
            }
        ],
    )
    (work / "Podfile").write_text(podfile(work))
    install_twice(fixture, work)
    phases = [
        v
        for v in read_project(work / "Pods/Pods.xcodeproj")["objects"].values()
        if v.get("name") == "[CP-User] Visibility"
    ]
    assert len(phases) == 1 and phases[0].get("showEnvVarsInLog") == "0"
    fixture.build(work, "Demo", "structured-script-visibility-build")
    fixture.verified.append(
        "boolean_script_log_visibility_is_accepted_and_hides_environment"
    )


def run(fixture):
    numeric_selectors(fixture)
    malformed_structures(fixture)
    prefix_and_config_values(fixture)
    development_schemes(fixture)
    scheme_whitespace_execution(fixture)
    boolean_script_visibility(fixture)


def structured_input_parity(parent, engines, native, reference):
    origin, data, _, _, _ = source_fixture(parent / "structured-parity-origin")
    observations = {}
    for engine in engines:
        cli = native if engine == "native" else reference
        cases = []
        for mode in ["external", "spec"]:
            for field in ["tag", "commit"]:
                for value in NUMERIC_SELECTORS:
                    label = engine + "-" + mode + "-" + field + "-" + repr(value)
                    work = numeric_source_case(
                        parent / ("structured-parity-" + label),
                        mode,
                        field,
                        value,
                        origin,
                        data,
                    )
                    cli(work, "install")
                    cases.append(
                        {
                            "mode": mode,
                            "field": field,
                            "value": value,
                            "source": (work / "Pods/Kit/Kit.c").read_text(),
                            "types": json.loads((work / "raw-types.json").read_text()),
                        }
                    )
        work, _ = create(parent / ("structured-scheme-parity-" + engine))
        update_spec(
            work,
            scheme={
                "launch_arguments": ["--value & more", 42],
                "environment_variables": {"COUNT": 3, "FLOAT": 1.0},
                "code_coverage": True,
                "build_configurations": {
                    "Run": "Release",
                    "Test": "Release",
                    "Analyze": "Release",
                    "Archive": "Debug",
                },
            },
        )
        (work / "Podfile").write_text(
            "install! 'cocoapods', :integrate_targets => false, :share_schemes_for_development_pods => true\n"
            + podfile(work)
        )
        cli(work, "install")
        tree = ET.parse(
            work / "Pods/Pods.xcodeproj/xcshareddata/xcschemes/Kit.xcscheme"
        ).getroot()
        cases.append(
            {
                "configurations": {
                    action: tree.find(action).get("buildConfiguration")
                    for action in [
                        "TestAction",
                        "LaunchAction",
                        "AnalyzeAction",
                        "ArchiveAction",
                    ]
                },
                "coverage": tree.find("TestAction").get("codeCoverageEnabled"),
                "arguments": [
                    n.get("argument")
                    for n in tree.findall(
                        "LaunchAction/CommandLineArguments/CommandLineArgument"
                    )
                ],
                "environment": {
                    n.get("key"): n.get("value")
                    for n in tree.findall(
                        "LaunchAction/EnvironmentVariables/EnvironmentVariable"
                    )
                },
            }
        )
        invalid = [
            {"scheme": {"launch_arguments": "--bad"}},
            {"scheme": {"code_coverage": 1}},
            {"script_phases": [{"name": "Missing script"}]},
            {
                "on_demand_resources": {
                    "asset": {"paths": "*.txt", "category": "invalid"}
                }
            },
            {"on_demand_resources": {"asset": {"paths": "*.txt", "category": 42}}},
            {"license": {"type": 42}},
        ]
        for index, changes in enumerate(invalid):
            work, _ = create(parent / f"structured-lint-parity-{engine}-{index}")
            path = work / "Kit/Kit.podspec.json"
            update_spec(work, **changes)
            cli(
                work,
                "lib",
                "lint",
                str(path),
                "--quick",
                "--allow-warnings",
                success=False,
            )
            cases.append({"attributes": changes, "accepted": False})
        work, _ = create(parent / ("structured-getters-parity-" + engine))
        update_spec(
            work,
            swift_versions=["5.0"],
            screenshots="image",
            deprecated_in_favor_of="Other",
        )
        hook = """pre_install do |installer|
  s = installer.pod_targets.first.root_spec
  c = s.consumer(:osx)
  unsupported = begin
    s.consumer(:ios)
    false
  rescue ::StandardError
    true
  end
  values = { 'source_keys' => c.source.keys.map { |k| k.class.to_s }, 'license' => c.license,
             'version_class' => c.version.class.to_s, 'swift_versions' => c.swift_versions.map(&:to_s),
             'authors' => c.authors, 'screenshots' => c.screenshots, 'deprecated' => c.deprecated?,
             'unset_static_framework' => c.static_framework, 'base_name' => c.base_name,
             'stable_identity' => c.equal?(s.consumer(Pod::Platform.new(:osx, '12.0'))),
             'unsupported_consumer_rejected' => unsupported,
             'requested_minimum_supported' => s.supported_on_platform?(Pod::Platform.new(:osx, '1.0')) }
  File.write('public-getters.json', JSON.generate(values))
end
"""
        (work / "Podfile").write_text(
            "install! 'cocoapods', :integrate_targets => false\n" + podfile(work) + hook
        )
        cli(work, "install")
        cases.append(json.loads((work / "public-getters.json").read_text()))
        work, _ = create(parent / ("structured-visibility-parity-" + engine))
        update_spec(
            work,
            script_phases=[
                {"name": "Visibility", "script": "true", "show_env_vars_in_log": False}
            ],
        )
        (work / "Podfile").write_text(
            "install! 'cocoapods', :integrate_targets => false\n" + podfile(work)
        )
        cli(work, "install")
        phase = next(
            v
            for v in read_project(work / "Pods/Pods.xcodeproj")["objects"].values()
            if v.get("name") == "[CP-User] Visibility"
        )
        cases.append(
            {
                "boolean_log_visibility_input_accepted": True,
                "showEnvVarsInLog": phase.get("showEnvVarsInLog"),
            }
        )
        assert phase.get("showEnvVarsInLog") == ("0" if engine == "native" else None), (
            phase
        )
        observations[engine] = cases
    if "reference" in observations:
        assert observations["native"][:-1] == observations["reference"][:-1], (
            observations
        )
    return observations
