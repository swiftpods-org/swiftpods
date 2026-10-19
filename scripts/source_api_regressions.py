"""Build sources, local preparation, prerelease hooks and isolated publication."""

import json
import platform

from lifecycle_audit_regressions import diagnostics, read_project
from metadata_repository_regressions import git, initialize
from native_xcconfig_tests import create
from vendor_fixture import fixture_build_arguments, run


def assembly(function, value):
    return (
        f".text\n.globl _{function}\n.p2align 2\n_{function}:\n"
        f"#if defined(__arm64__)\n mov w0, #{value}\n"
        f"#elif defined(__x86_64__)\n movl ${value}, %eax\n"
        "#else\n#error Unsupported test architecture\n#endif\n ret\n"
    )


def source_paths(graph, target_name):
    objects = graph["objects"]
    target = next(
        value
        for value in objects.values()
        if value.get("isa") == "PBXNativeTarget" and value.get("name") == target_name
    )
    phase = next(
        objects[identifier]
        for identifier in target["buildPhases"]
        if objects[identifier]["isa"] == "PBXSourcesBuildPhase"
    )
    return [
        objects[objects[identifier]["fileRef"]]["path"] for identifier in phase["files"]
    ]


def assembly_sources(fixture):
    work, selected = create(fixture.root / "assembly-sources")
    library = work / "Kit"
    (library / "Kit.c").unlink()
    (library / "Kit.S").write_text(assembly("kit_value", 7))
    (library / "Lower.s").write_text(
        ".data\n.globl _kit_other_value\n.p2align 2\n_kit_other_value:\n.long 3\n"
    )
    header = library / "Kit.h"
    header.write_text(
        header.read_text().replace(
            "int kit_value(void);",
            "int kit_value(void);\nextern const int kit_other_value;",
        )
    )
    main = selected.parent / "Sources/main.mm"
    main.write_text(
        main.read_text().replace("return 0;", "return kit_other_value == 3 ? 0 : 1;")
    )
    (library / "Tool.S").write_text(assembly("main", 0))
    (library / "Test.S").write_text(assembly("unit_value", 9))
    (library / "Test.m").write_text(
        "#import <XCTest/XCTest.h>\nextern int unit_value(void);\n"
        "@interface AssemblyTests : XCTestCase\n@end\n@implementation AssemblyTests\n"
        "- (void)testAssembly { XCTAssertEqual(unit_value(), 9); }\n@end\n"
    )
    spec = library / "Kit.podspec.json"
    data = json.loads(spec.read_text())
    data.update(
        source_files=["Kit.S", "Lower.s", "Kit.h"],
        appspecs=[
            {
                "name": "Tool",
                "source_files": "Tool.S",
                # Xcode 27's preview links race on one dependency-info file.
                # This assembly fixture verifies the ordinary app executable.
                "pod_target_xcconfig": {"ENABLE_DEBUG_DYLIB": "NO"},
            }
        ],
        testspecs=[
            {
                "name": "Unit",
                "source_files": ["Test.S", "Test.m"],
                "platforms": {"osx": "14.0"},
            }
        ],
    )
    spec.write_text(json.dumps(data))
    body = (work / "Podfile").read_text().split("post_install")[0]
    body = body.replace(
        ":path => './Kit'",
        ":path => './Kit', :testspecs => ['Unit'], :appspecs => ['Tool']",
    )
    (work / "Podfile").write_text(
        body
        + """post_install do |installer|
  accessor = installer.pod_targets.first.file_accessors.find { |a| a.spec.name == 'Kit' }
  sources = accessor.source_files.map { |path| path.basename.to_s }
  others = accessor.other_source_files.map { |path| path.basename.to_s }
  raise 'assembly missing from FileAccessor' unless ['Kit.S', 'Lower.s'].all? { |name| sources.include?(name) && others.include?(name) }
end
"""
    )
    fixture.cli(work, "install")
    graph = read_project(work / "Pods/Pods.xcodeproj")
    assert {path.rsplit("/", 1)[-1] for path in source_paths(graph, "Kit")} == {
        "Kit.S",
        "Lower.s",
    }
    assert any(path.endswith("/Tool.S") for path in source_paths(graph, "Kit-Tool"))
    assert any(
        path.endswith("/Test.S") for path in source_paths(graph, "Kit-Unit-Unit")
    )
    fixture.build(work, "Demo", "assembly-library-build")
    fixture.build(work, "Kit-Tool", "assembly-app-build")
    test_build = fixture.root / "assembly-tests-build"
    test_build.mkdir()
    run(
        [
            "xcodebuild",
            "-workspace",
            str(next(work.glob("*.xcworkspace"))),
            "-scheme",
            "Kit-Unit-Unit",
            "-configuration",
            "Debug",
            "-destination",
            "platform=macOS,arch=" + platform.machine(),
            *fixture_build_arguments(test_build),
            "CODE_SIGNING_ALLOWED=NO",
            "test",
        ],
        work,
        fixture.root / "assembly-tests.log",
    )
    fixture.cli(work, "install", "--offline", "--deployment")
    fixture.verified += [
        "explicit_assembly_library_app_and_test_sources",
        "assembly_library_app_build_and_xctest",
        "assembly_file_accessor_and_deployment",
    ]


def prerelease_and_serialization(fixture):
    work, _ = create(fixture.root / "prerelease-serialization")
    spec = work / "Kit/Kit.podspec.json"
    data = json.loads(spec.read_text())
    data["version"] = "1.0.0-alpha"
    spec.write_text(json.dumps(data))
    body = (work / "Podfile").read_text().split("post_install")[0]
    body = body.replace("pod 'Kit',", "pod 'Kit', '= 1.0.0-alpha.0',")
    (work / "Podfile").write_text(body)
    result = fixture.cli(work, "install", succeeds=False)
    assert "SP-RESOLVE-CONFLICT" in diagnostics(result)
    assert not (work / "Podfile.lock").exists()
    data["version"] = "1.0.0-alpha.0"
    spec.write_text(json.dumps(data))
    (work / "Podfile").write_text(
        "require 'yaml'\n"
        + body
        + """pre_install do |installer|
  version = installer.pod_targets.first.root_spec.version
  requirement = installer.podfile.dependencies.first.requirement
  [Marshal.load(Marshal.dump(version)), YAML.unsafe_load(YAML.dump(version))].each do |copy|
    raise 'version lost after serialization' unless copy.to_s == version.to_s && copy == version
    raise 'requirement lost after serialization' unless requirement.satisfied_by?(copy)
    raise 'prerelease zero collapsed' if copy == Pod::Version.new('1.0.0-alpha')
  end
  raise 'wrong prerelease order' unless Pod::Version.new('1.0.0-alpha.2') < Pod::Version.new('1.0.0-alpha.beta')
end
"""
    )
    fixture.cli(work, "install")
    lock = (work / "Podfile.lock").read_bytes()
    assert b"Kit (1.0.0-alpha.0)" in lock
    fixture.cli(work, "install", "--offline", "--deployment")
    assert (work / "Podfile.lock").read_bytes() == lock
    fixture.verified += [
        "exact_prerelease_zero_install_and_ruby_hooks",
        "ruby_version_serialization_during_install",
    ]


def local_preparation(fixture):
    work, _ = create(fixture.root / "local-preparation")
    library = work / "Kit"
    spec = library / "Kit.podspec.json"
    data = json.loads(spec.read_text())
    data["prepare_command"] = (
        "test ! -f .prepared || exit 23; touch .prepared; printf p >> count"
    )
    spec.write_text(json.dumps(data))
    fixture.cli(work, "install")
    user_file = library / "User.c"
    user_file.write_text("user modification\n")
    fixture.cli(work, "install")
    fixture.cli(work, "install", "--offline", "--deployment")
    assert (library / "count").read_text() == "p"
    assert user_file.read_text() == "user modification\n"
    data["prepare_command"] = "printf q >> count"
    spec.write_text(json.dumps(data))
    fixture.cli(work, "install")
    fixture.cli(work, "install")
    assert (library / "count").read_text() == "pq"
    fixture.cli(work, "update", "Kit")
    assert (library / "count").read_text() == "pqq"
    fixture.cli(work, "install", "--clean-install")
    assert (library / "count").read_text() == "pqqq"
    assert user_file.read_text() == "user modification\n"
    fixture.verified += [
        "local_prepare_skipped_on_unchanged_install_and_deployment",
        "local_prepare_changed_spec_update_and_clean_install_preserve_user_files",
    ]


def publication_environment(fixture):
    root = fixture.root / "publication-environment"
    origin = root / "origin"
    origin.mkdir(parents=True)
    (origin / "README").write_text("Fixture\n")
    initial = initialize(origin)
    work = root / "work"
    work.mkdir()
    spec = work / "Kit.podspec.json"
    spec.write_text(
        json.dumps(
            {
                "name": "Kit",
                "version": "1.0",
                "summary": "Fixture",
                "homepage": "https://swiftpods.org",
                "authors": "Tests",
                "license": "MIT",
                "source_files": "*.c",
                "source": {"git": "https://example.invalid/Kit.git", "tag": "1.0"},
            }
        )
    )
    previous = fixture.env.copy()
    fixture.env["SWIFTPODS_CACHE_ROOT"] = str(root / "cache")
    try:
        fixture.cli(work, "repo", "add", "private", str(origin))
        checkout = root / "cache/repositories/private"
        git(checkout, "config", "user.name", "SwiftPods Tests")
        git(checkout, "config", "user.email", "tests@example.invalid")
        hook = checkout / ".git/hooks/pre-commit"
        hook.write_text("#!/bin/sh\nexit 17\n")
        hook.chmod(0o755)
        record = checkout.with_suffix(".json").read_bytes()
        for key, relative in {
            "GIT_DIR": ".git",
            "GIT_COMMON_DIR": ".git",
            "GIT_WORK_TREE": ".",
            "GIT_INDEX_FILE": ".git/index",
            "GIT_OBJECT_DIRECTORY": ".git/objects",
            "GIT_ALTERNATE_OBJECT_DIRECTORIES": ".git/objects",
        }.items():
            fixture.env[key] = str(checkout / relative)
        result = fixture.cli(
            work,
            "repo",
            "push",
            "private",
            str(spec),
            "--local-only",
            "--quick",
            succeeds=False,
        )
        assert "SP-TOOL-FAILED" in diagnostics(result)
        assert git(checkout, "status", "--porcelain") == ""
        assert git(checkout, "rev-parse", "HEAD") == initial
        assert checkout.with_suffix(".json").read_bytes() == record
        assert not (checkout / "Kit").exists()
        hook.write_text("#!/bin/sh\nexit 0\n")
        fixture.cli(
            work, "repo", "push", "private", str(spec), "--local-only", "--quick"
        )
        assert git(checkout, "status", "--porcelain") == ""
        assert json.loads(checkout.with_suffix(".json").read_text())["revision"] == git(
            checkout, "rev-parse", "HEAD"
        )
        assert (checkout / "Kit/1.0/Kit.podspec.json").is_file()
        assert git(origin, "rev-parse", "HEAD") == initial
        assert not list(checkout.parent.glob(".publish-*"))
    finally:
        fixture.env.clear()
        fixture.env.update(previous)
    fixture.verified += [
        "publication_isolates_inherited_git_storage_variables",
        "rejected_publication_and_retry_preserve_checkout_and_registry",
    ]


def run_regressions(fixture):
    assembly_sources(fixture)
    prerelease_and_serialization(fixture)
    local_preparation(fixture)
    publication_environment(fixture)
