#!/usr/bin/env python3
"""Regressions for manifest edits, owned Xcode objects and cache provenance."""

import copy
import functools
import hashlib
import http.server
import json
import platform
import subprocess
import threading
from pathlib import Path

from scripts.support.bootstrap import environment
from scripts.support.local_build import (
    debug_binary,
    fixture_directory,
    results_directory,
)
from scripts.support.reporting import execute
from Tests.Fixtures.swift_package_fixture import create as create_package
from Tests.Fixtures.vendor_fixture import fixture_build_arguments, run
from Tests.Integration.native_integration import project, serialize
from Tests.Integration.native_xcconfig_tests import create
from Tests.Regression.build_setting_definition_regressions import (
    run_regressions as build_setting_definition_regressions,
)
from Tests.Regression.build_setting_expression_regressions import (
    run_regressions as build_setting_expression_regressions,
)
from Tests.Regression.build_setting_type_regressions import (
    run_regressions as build_setting_type_regressions,
)
from Tests.Regression.catalog_build_regressions import run as catalog_build_regressions
from Tests.Regression.cli_capture_regressions import (
    run_regressions as cli_capture_regressions,
)
from Tests.Regression.cli_invocation_regressions import (
    run_regressions as cli_invocation_regressions,
)
from Tests.Regression.command_option_regressions import (
    run_regressions as command_option_regressions,
)
from Tests.Regression.configuration_context_regressions import (
    run_regressions as configuration_context_regressions,
)
from Tests.Regression.consumer_build_regressions import (
    run as consumer_build_regressions,
)
from Tests.Regression.dictionary_key_regressions import (
    run_regressions as dictionary_key_regressions,
)
from Tests.Regression.environment_import_regressions import (
    run_regressions as environment_import_regressions,
)
from Tests.Regression.glob_character_class_regressions import character_class_builds
from Tests.Regression.glob_scalar_regressions import (
    run_regressions as scalar_glob_builds,
)
from Tests.Regression.header_ownership_regressions import (
    run as header_ownership_regressions,
)
from Tests.Regression.header_path_regressions import (
    run_regressions as header_path_regressions,
)
from Tests.Regression.input_contract_regressions import (
    run as input_contract_regressions,
)
from Tests.Regression.integrity_doctor_path_regressions import (
    run_regressions as integrity_doctor_paths,
)
from Tests.Regression.lifecycle_audit_regressions import run as audit_regressions
from Tests.Regression.lint_input_regressions import run as lint_input_regressions
from Tests.Regression.metadata_repository_regressions import run as metadata_regressions
from Tests.Regression.name_boundary_regressions import (
    run_regressions as name_boundary_regressions,
)
from Tests.Regression.option_prefix_regressions import (
    run_regressions as option_prefix_regressions,
)
from Tests.Regression.path_input_regressions import (
    run_regressions as path_input_regressions,
)
from Tests.Regression.pbx_path_regressions import (
    run_regressions as pbx_path_regressions,
)
from Tests.Regression.process_concurrency_regressions import (
    run_regressions as process_concurrency_regressions,
)
from Tests.Regression.process_input_regressions import (
    run_regressions as process_input_regressions,
)
from Tests.Regression.process_lifetime_regressions import (
    run_regressions as process_lifetime_regressions,
)
from Tests.Regression.project_path_regressions import (
    run_regressions as project_path_regressions,
)
from Tests.Regression.project_variable_regressions import (
    run_regressions as project_variable_regressions,
)
from Tests.Regression.sdk_condition_regressions import (
    run_regressions as sdk_condition_regressions,
)
from Tests.Regression.source_api_regressions import (
    run_regressions as source_api_regressions,
)
from Tests.Regression.source_delimiter_regressions import (
    run_regressions as source_delimiter_regressions,
)
from Tests.Regression.source_input_regressions import run as source_input_regressions
from Tests.Regression.source_link_regressions import (
    run_regressions as source_link_regressions,
)
from Tests.Regression.source_string_regressions import (
    run_regressions as source_string_regressions,
)
from Tests.Regression.structured_input_regressions import (
    run as structured_input_regressions,
)
from Tests.Regression.swift_package_regressions import run as swift_package_regressions
from Tests.Regression.unicode_path_regressions import path_builds
from Tests.Regression.value_contract_regressions import (
    run as value_contract_regressions,
)
from Tests.Regression.workspace_resource_regressions import (
    run as workspace_resource_regressions,
)
from Tests.Regression.xcconfig_include_regressions import (
    run_regressions as xcconfig_include_regressions,
)
from Tests.Regression.yaml_document_regressions import (
    run_regressions as yaml_document_regressions,
)


def read_project(path):
    return json.loads(
        subprocess.check_output(
            ["plutil", "-convert", "json", "-o", "-", str(path / "project.pbxproj")]
        )
    )


class LifecycleFixture:
    def __init__(self):
        self.root = fixture_directory("native-lifecycle-")
        self.env = environment()
        self.env["SWIFTPODS_CACHE_ROOT"] = str(self.root / "cache")
        self.binary = debug_binary()
        self.sequence = 0
        self.verified = []

    def cli(self, work, *arguments, succeeds=True, stdin=None, close_stdin=False):
        self.sequence += 1
        command = [str(self.binary), *arguments, "--json"]
        if close_stdin:
            assert stdin is None
            command = [
                "/bin/sh",
                "-c",
                'exec 0<&-; exec "$@"',
                "swiftpods-closed-input",
                *command,
            ]
        result = subprocess.run(
            command,
            cwd=work,
            env=self.env,
            capture_output=True,
            text=True,
            input=stdin,
            timeout=90,
        )
        action = arguments[0].partition("=")[0]
        label = (
            "".join(
                value if value.isascii() and (value.isalnum() or value in "-_") else "_"
                for value in action
            )[:64]
            or "command"
        )
        log = self.root / (str(self.sequence) + "-" + label + ".log")
        log.write_text(result.stdout + result.stderr)
        assert result.returncode >= 0, (
            f"{log} (terminated by signal {-result.returncode})"
        )
        assert (result.returncode == 0) == succeeds, (
            f"{log} (exit status {result.returncode})"
        )
        try:
            return json.loads(result.stdout)
        except json.JSONDecodeError as error:
            raise AssertionError(
                f"Invalid JSON in {log} (exit status {result.returncode})"
            ) from error

    def build(self, work, scheme, label, *, jobs=None):
        build_root = self.root / label
        build_root.mkdir()
        workspace = next(work.glob("*.xcworkspace"))
        run(
            [
                "xcodebuild",
                "-workspace",
                workspace,
                "-scheme",
                scheme,
                "-configuration",
                "Debug",
                "-destination",
                "platform=macOS,arch=" + platform.machine(),
                *fixture_build_arguments(build_root),
                *(["-jobs", str(jobs)] if jobs is not None else []),
                "CODE_SIGNING_ALLOWED=NO",
                "build",
            ],
            work,
            self.root / (label + ".log"),
        )

    def package_lifecycle(self):
        work, selected = create(self.root / "packages")
        package_url = create_package(work / "Package", versions=("1.0.0", "2.0.0"))
        original = (work / "Podfile").read_text()
        declaration = " spm 'Net', :git => " + repr(package_url) + ", :exact => 'VERSION', :products => ['Net']\n"
        for version in ["1.0.0", "2.0.0"]:
            (work / "Podfile").write_text(
                original.replace(
                    "target 'Demo' do\n",
                    "target 'Demo' do\n" + declaration.replace("VERSION", version),
                )
            )
            self.cli(work, "install")
            objects = read_project(selected)["objects"]
            reference = next(
                value
                for value in objects.values()
                if value.get("isa") == "XCRemoteSwiftPackageReference"
            )
            assert reference["requirement"]["version"] == version
        self.cli(work, "install")
        objects = read_project(selected)["objects"]
        assert (
            sum(
                value.get("isa") == "XCSwiftPackageProductDependency"
                for value in objects.values()
            )
            == 1
        )
        (work / "Podfile").write_text(original)
        self.cli(work, "install")
        objects = read_project(selected)["objects"]
        assert not any(
            value.get("isa")
            in ("XCRemoteSwiftPackageReference", "XCSwiftPackageProductDependency")
            or value.get("productRef")
            for value in objects.values()
        )
        self.verified += [
            "owned_package_version_update",
            "owned_package_removal",
            "idempotent_package_reinstall",
        ]

    def configuration_and_hooks(self):
        work, selected = create(self.root / "configuration")
        base = selected.parent / "Configs/Base.xcconfig"
        base.write_text(
            base.read_text().replace(
                "MACOSX_DEPLOYMENT_TARGET = 13.0",
                "MY_MIN = 13.0\nMIN_ALIAS = ${MY_MIN}\nMACOSX_DEPLOYMENT_TARGET = $(MIN_ALIAS)",
            )
        )
        original = (
            (work / "Podfile")
            .read_text()
            .split("post_install")[0]
            .replace("platform :osx, '13.0'\n", "")
        )
        spec = json.loads((work / "Kit/Kit.podspec.json").read_text())
        spec["user_target_xcconfig"] = {"OTHER_CFLAGS": "$(inherited) -DFROM_KIT=1"}
        (work / "Kit/Kit.podspec.json").write_text(json.dumps(spec))
        second = work / "Second"
        second.mkdir()
        (second / "Second.c").write_text("int second(void) { return 1; }\n")
        (second / "Second.podspec.json").write_text(
            json.dumps(
                dict(
                    spec,
                    name="Second",
                    source_files="*.c",
                    user_target_xcconfig={
                        "OTHER_CFLAGS": "$(inherited) -DFROM_SECOND=1"
                    },
                )
            )
        )
        hook = """post_install do |installer|
  installer.pods_project.native_targets.each do |target|
    phase = target.source_build_phase
    next if phase.files.empty?
    original = phase.files.first
    raise 'duplicate build file' unless phase.add_file_reference(original.file_ref, true).equal?(original)
  end
end
"""
        (work / "Podfile").write_text(
            original.replace(
                " pod 'Kit', :path => './Kit'",
                " pod 'Kit', :path => './Kit'\n pod 'Second', :path => './Second'",
            )
            + hook
        )
        (selected.parent / "Sources/main.mm").write_text(
            "#ifndef FROM_KIT\n#error Missing_Kit\n#endif\n#ifndef FROM_SECOND\n#error Missing_Second\n#endif\nint main(void) { return 0; }\n"
        )
        self.cli(work, "install")
        self.build(work, "Demo", "configuration-build")
        self.verified += [
            "deployment_target_macro_inference",
            "merged_consumer_flags_build",
            "public_source_build_phase_hook",
            "hook_avoid_duplicate_build_files",
        ]

    def removed_target(self):
        work = self.root / "targets"
        work.mkdir()
        selected = work / "Demo.xcodeproj"
        project(selected)
        (work / "Sources").mkdir()
        (work / "Sources/main.mm").write_text("int main(void) { return 0; }\n")
        graph = read_project(selected)
        objects = graph["objects"]
        for value in objects.values():
            if value.get("isa") == "XCBuildConfiguration":
                value["buildSettings"]["ALWAYS_SEARCH_USER_PATHS"] = "NO"
        root = objects[graph["rootObject"]]
        first = objects[root["targets"][0]]

        def identifier(key):
            return (
                hashlib.sha256(("lifecycle:" + key).encode()).hexdigest()[:24].upper()
            )

        second_id = identifier("Other")
        second = copy.deepcopy(first)
        objects[second_id] = second
        second.update(name="Other", productName="Other")
        root["targets"].append(second_id)
        for field in ["productReference", "buildConfigurationList"]:
            old = first[field]
            new = identifier(field)
            objects[new] = copy.deepcopy(objects[old])
            second[field] = new
        objects[second["productReference"]]["path"] = "Other.app"
        objects[root["productRefGroup"]]["children"].append(second["productReference"])
        configurations = objects[second["buildConfigurationList"]]
        configurations["buildConfigurations"] = []
        for old in objects[first["buildConfigurationList"]]["buildConfigurations"]:
            new = identifier(old)
            objects[new] = copy.deepcopy(objects[old])
            objects[new]["buildSettings"]["PRODUCT_NAME"] = "Other"
            configurations["buildConfigurations"].append(new)
        second["buildPhases"] = []
        for old in first["buildPhases"]:
            new = identifier(old)
            objects[new] = copy.deepcopy(objects[old])
            second["buildPhases"].append(new)
        (selected / "project.pbxproj").write_text("// !$*UTF8*$!\n" + serialize(graph))
        for name in ["Kit", "OnlyOther"]:
            directory = work / name
            directory.mkdir()
            (directory / (name + ".c")).write_text(
                "int " + name.lower() + "(void) { return 7; }\n"
            )
            (directory / (name + ".podspec.json")).write_text(
                json.dumps(
                    {
                        "name": name,
                        "version": "1.0",
                        "source_files": "*.c",
                        "platforms": {"osx": "13.0"},
                        "summary": "Fixture",
                        "homepage": "https://swiftpods.org",
                        "authors": "Tests",
                        "license": "MIT",
                        "source": {
                            "git": "https://example.invalid/" + name + ".git",
                            "tag": "1.0",
                        },
                    }
                )
            )
        original = "platform :osx, '13.0'\nproject 'Demo.xcodeproj'\ntarget 'Demo' do\n pod 'Kit', :path => './Kit'\nend\n"
        (work / "Podfile").write_text(
            original
            + "target 'Other' do\n pod 'OnlyOther', :path => './OnlyOther'\nend\n"
        )
        self.cli(work, "install")
        self.build(work, "Other", "target-before-removal")
        (work / "Podfile").write_text(original)
        self.cli(work, "install")
        after = read_project(selected)["objects"]
        assert not after[second_id].get("dependencies")
        self.build(work, "Other", "target-after-removal")
        self.verified.append("removed_consumer_builds_without_stale_libraries")

    def deleted_subspec(self):
        work = self.root / "subspec"
        work.mkdir()
        (work / "Kit.c").write_text("int kit(void) { return 1; }\n")
        (work / "Kit.podspec").write_text("""Pod::Spec.new do |s|
  s.name = 'Kit'
  s.version = '1.0'
  s.osx.deployment_target = '13.0'
  s.subspec('Core') { |child| child.source_files = 'Kit.c' }
  s.subspec('Optional') { |child| child.dependency 'Unwanted', '~> 1' }
  s.subspecs.delete_if { |child| child.name.end_with?('/Optional') }
end
""")
        (work / "Podfile").write_text(
            "platform :osx, '13.0'\ntarget 'App' do\n pod 'Kit', :path => '.'\nend\n"
        )
        self.cli(work, "install", "--no-integrate", "--offline")
        lock = (work / "Podfile.lock").read_text()
        assert "Kit/Core" in lock and "Optional" not in lock and "Unwanted" not in lock
        self.verified.append("deleted_subspec_does_not_resolve_or_install")

    def shared_pins_and_git_provenance(self):
        work = self.root / "shared-pins"
        work.mkdir()
        origin = work / "origin"
        origin.mkdir()
        (origin / "Value.c").write_text("int value(void) { return 1; }\n")
        git_env = dict(
            self.env,
            GIT_AUTHOR_NAME="Fixtures",
            GIT_AUTHOR_EMAIL="fixtures@swiftpods.org",
            GIT_COMMITTER_NAME="Fixtures",
            GIT_COMMITTER_EMAIL="fixtures@swiftpods.org",
        )
        for command in [
            ["init", "-b", "main"],
            ["add", "."],
            ["commit", "-m", "Fixture"],
        ]:
            subprocess.run(
                ["git", "-C", str(origin), *command],
                env=git_env,
                check=True,
                capture_output=True,
            )
        commit = subprocess.check_output(
            ["git", "-C", str(origin), "rev-parse", "HEAD"], text=True
        ).strip()
        catalog = work / "specs"

        def specification(name, version):
            path = catalog / name / version / (name + ".podspec.json")
            path.parent.mkdir(parents=True)
            value = {
                "name": name,
                "version": version,
                "source_files": "*.c",
                "platforms": {"osx": "13.0"},
                "source": {"git": str(origin)},
            }
            if name != "Shared":
                value["dependencies"] = {"Shared": [">= 0"]}
            path.write_text(json.dumps(value))

        for name in ["A", "B", "Shared"]:
            specification(name, "1.0")
        (work / "Podfile").write_text(
            "source "
            + repr(str(catalog))
            + "\nplatform :osx, '13.0'\ntarget 'App' do\n pod 'A'\n pod 'B'\nend\n"
        )
        self.cli(work, "install", "--no-integrate")
        specification("Shared", "2.0")
        self.cli(work, "update", "A", "--no-integrate")
        assert "Shared (1.0)" in (work / "Podfile.lock").read_text()
        self.cli(work, "update", "A", "B", "--no-integrate")
        assert "Shared (2.0)" in (work / "Podfile.lock").read_text()
        self.verified += [
            "targeted_update_keeps_shared_pins",
            "all_parents_update_unlocks_shared",
        ]
        locked = (work / "Podfile.lock").read_bytes()
        key = hashlib.sha256((str(origin) + "\n" + commit).encode()).hexdigest()
        metadata_path = (
            Path(self.env["SWIFTPODS_CACHE_ROOT"]) / "git" / (key + ".origin.json")
        )
        metadata = json.loads(metadata_path.read_text())
        metadata["commit"] = "f" * 40
        metadata_path.write_text(json.dumps(metadata))
        self.cli(work, "cache", "verify", succeeds=False)
        failed = self.cli(work, "install", "--no-integrate", succeeds=False)
        assert (work / "Podfile.lock").read_bytes() == locked
        if failed.get("project_state") == "recovery_required":
            self.cli(work, "recover")
        self.cli(work, "update", "A", "B", "--no-integrate", "--no-repo-update")
        self.cli(work, "cache", "verify")
        self.cli(work, "install", "--no-integrate", "--offline", "--deployment")
        assert (work / "Podfile.lock").read_bytes() == locked
        self.verified += [
            "changed_git_metadata_rejected_before_lock_write",
            "git_cache_refresh_repairs_provenance",
        ]

    def exact_cache_cleanup(self):
        work = self.root / "cache-cleanup"
        payload = work / "input/Foo"
        payload.mkdir(parents=True)
        (payload / "Foo.c").write_text("int foo(void) { return 1; }\n")
        (payload / "Foo.podspec.json").write_text(
            json.dumps({"name": "Foo", "version": "1.0", "source_files": "*.c"})
        )
        web = work / "web"
        web.mkdir()
        subprocess.run(
            ["tar", "-cf", str(web / "Kit.tar"), "-C", str(payload.parent), "Foo"],
            check=True,
        )

        class Handler(http.server.SimpleHTTPRequestHandler):
            def log_message(self, *arguments):
                pass

        server = http.server.ThreadingHTTPServer(
            ("127.0.0.1", 0), functools.partial(Handler, directory=str(web))
        )
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            url = "http://127.0.0.1:" + str(server.server_port) + "/Kit.tar"
            (work / "Podfile").write_text(
                "platform :osx, '13.0'\ntarget 'App' do\n pod 'Foo', :http => "
                + repr(url)
                + "\nend\n"
            )
            self.cli(work, "install", "--no-integrate")
            self.cli(work, "cache", "clean", "Kit")
            self.cli(work, "install", "--no-integrate", "--offline", "--deployment")
        finally:
            server.shutdown()
            server.server_close()
            thread.join()
        self.verified.append("named_cache_cleanup_preserves_other_pods_offline")


def main():
    fixture = LifecycleFixture()
    print("Lifecycle fixtures:", fixture.root, flush=True)
    fixture.package_lifecycle()
    fixture.configuration_and_hooks()
    fixture.removed_target()
    fixture.deleted_subspec()
    fixture.shared_pins_and_git_provenance()
    fixture.exact_cache_cleanup()
    source_link_regressions(fixture)
    audit_regressions(fixture)
    metadata_regressions(fixture)
    source_api_regressions(fixture)
    workspace_resource_regressions(fixture)
    character_class_builds(fixture)
    scalar_glob_builds(fixture)
    path_input_regressions(fixture)
    process_input_regressions(fixture)
    process_concurrency_regressions(fixture)
    process_lifetime_regressions(fixture)
    source_string_regressions(fixture)
    dictionary_key_regressions(fixture)
    xcconfig_include_regressions(fixture)
    pbx_path_regressions(fixture)
    yaml_document_regressions(fixture)
    source_delimiter_regressions(fixture)
    sdk_condition_regressions(fixture)
    project_variable_regressions(fixture)
    configuration_context_regressions(fixture)
    build_setting_expression_regressions(fixture)
    build_setting_definition_regressions(fixture)
    build_setting_type_regressions(fixture)
    cli_capture_regressions(fixture)
    command_option_regressions(fixture)
    option_prefix_regressions(fixture)
    environment_import_regressions(fixture)
    cli_invocation_regressions(fixture)
    path_builds(fixture)
    project_path_regressions(fixture)
    name_boundary_regressions(fixture)
    header_path_regressions(fixture)
    integrity_doctor_paths(fixture)
    header_ownership_regressions(fixture)
    consumer_build_regressions(fixture)
    input_contract_regressions(fixture)
    source_input_regressions(fixture)
    lint_input_regressions(fixture)
    catalog_build_regressions(fixture)
    value_contract_regressions(fixture)
    structured_input_regressions(fixture)
    swift_package_regressions(fixture)
    (results_directory() / "native-lifecycle.json").write_text(
        json.dumps(
            {
                "status": "passed",
                "fixture": str(fixture.root),
                "verified": fixture.verified,
            },
            indent=2,
        )
        + "\n"
    )


if __name__ == "__main__":
    execute(main, "native-lifecycle.json")
