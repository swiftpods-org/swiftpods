"""Ten audit contracts, with compiler controls and real install/reinstall coverage."""

import json
import platform
import plistlib
import shutil
import subprocess

from scripts.support.local_build import results_directory
from Tests.Fixtures.vendor_fixture import sdk
from Tests.Integration.native_lint_interface_tests import Fixture as LintFixture
from Tests.Integration.native_xcconfig_tests import create
from Tests.Regression.header_namespace_regressions import module_fixture
from Tests.Regression.header_ownership_regressions import read_project, write_project
from Tests.Regression.module_ownership_regressions import reject_conflict, supported
from Tests.Regression.project_path_regressions import builds
from Tests.Regression.workspace_resource_regressions import add_consumer


def update_spec(work, pod, **changes):
    path = work / pod / (pod + ".podspec.json")
    data = json.loads(path.read_text())
    data.update(changes)
    path.write_text(json.dumps(data))
    return data


def clang(fixture, source, maps, label):
    command = [
        "xcrun",
        "clang",
        "-Werror",
        "-fsyntax-only",
        "-fmodules",
        "-fmodules-cache-path=" + str(fixture.root / (label + "-modules")),
        *["-fmodule-map-file=" + str(path) for path in maps],
        str(source),
    ]
    result = subprocess.run(command, capture_output=True, text=True, timeout=60)
    log = fixture.root / (label + "-clang.log")
    log.write_text(result.stdout + result.stderr)
    assert result.returncode == 0, log


def project_collision(fixture):
    for project_name in ["Separate", "pods"]:
        work, selected = create(fixture.root / ("project-name-" + project_name))
        podfile = work / "Podfile"
        body = (
            podfile.read_text()
            .split("post_install")[0]
            .replace(
                ":path => './Kit'",
                ":path => './Kit', :project_name => '" + project_name + "'",
            )
        )
        podfile.write_text(
            "install! 'cocoapods', :generate_multiple_pod_projects => true\n" + body
        )
        if project_name == "Separate":
            fixture.cli(work, "install")
            fixture.cli(work, "install", "--offline", "--deployment")
            builds(fixture, work, "separate-project-control")
            fixture.verified.append("separate-project-control")
            continue
        before = (selected / "project.pbxproj").read_bytes()
        report = fixture.cli(work, "install", succeeds=False)
        assert (selected / "project.pbxproj").read_bytes() == before
        assert not (work / "Podfile.lock").exists()
        assert any(
            e.get("code") == "SP-XCODE-PROJECT" for e in report["events"]
        ), report
        assert report.get("project_state") != "recovery_required", report


def configuration_files(fixture):
    work, selected = create(fixture.root / "case-configurations")
    graph = read_project(selected)
    for obj in graph["objects"].values():
        if obj.get("isa") == "XCBuildConfiguration":
            if obj["name"] == "Release":
                obj["name"] = "DEBUG"
            obj.pop("baseConfigurationReference", None)
            obj["buildSettings"]["CASE_CONTROL"] = obj["name"]
    write_project(selected, graph)
    # Xcode itself distinguishes the two configuration names, before integration.
    for name in ["Debug", "DEBUG"]:
        result = subprocess.run(
            [
                "xcodebuild",
                "-project",
                str(selected),
                "-target",
                "Demo",
                "-configuration",
                name,
                "-showBuildSettings",
                "-json",
            ],
            capture_output=True,
            text=True,
            timeout=60,
        )
        log = fixture.root / (
            "configuration-" + ("mixed" if name == "Debug" else "upper") + ".json"
        )
        log.write_text(result.stdout + result.stderr)
        assert result.returncode == 0, log
        assert (
            json.loads(result.stdout)[0]["buildSettings"]["CASE_CONTROL"] == name
        ), log
    fixture.verified.append("xcode-distinguishes-case-configurations")
    (work / "Podfile").write_text(
        (work / "Podfile").read_text().split("post_install")[0]
    )
    fixture.cli(work, "install")
    graph = read_project(selected)
    target = next(
        o
        for o in graph["objects"].values()
        if o.get("isa") == "PBXNativeTarget" and o.get("name") == "Demo"
    )
    ids = graph["objects"][target["buildConfigurationList"]]["buildConfigurations"]
    references = {
        graph["objects"][identifier]["name"]: graph["objects"][identifier].get(
            "baseConfigurationReference"
        )
        for identifier in ids
    }
    assert references["Debug"] and references["DEBUG"]
    assert references["Debug"] != references["DEBUG"], references


def case_sensitive_modules(fixture):
    work, selected = module_fixture(fixture.root / "case-module-names", collision=False)
    maps = []
    for pod, module in [("Kit", "Feature"), ("Other", "feature")]:
        update_spec(work, pod, module_map="Author.modulemap")
        path = work / pod / "Author.modulemap"
        path.write_text("module " + module + ' { header "' + pod + '.h" export * }\n')
        maps.append(path)
    source = selected.parent / "Sources/main.m"
    source.write_text(
        "@import Feature;\n@import feature;\n#if KIT_A != 11 || KIT_B != 31\n#error Missing case-sensitive API\n#endif\nint main(void) { return 0; }\n"
    )
    clang(fixture, source, maps, "case-sensitive-control")
    fixture.verified.append("clang-imports-case-sensitive-module-names")
    fixture.cli(work, "install")
    fixture.cli(work, "install", "--offline", "--deployment")
    builds(fixture, work, "case-sensitive-modules")


def vendor_pair_fixture(parent, *, collision=False):
    work, selected = module_fixture(parent, collision=False)
    for pod, name in [("Kit", "FirstSDK"), ("Other", "SecondSDK")]:
        archive = sdk(parent, name, platforms=("macosx",))
        destination = work / pod / archive.name
        shutil.copytree(archive, destination, symlinks=True)
        if collision:
            for modulemap in destination.glob(
                "*/" + name + ".framework/Versions/A/Modules/module.modulemap"
            ):
                modulemap.write_text(
                    'framework module Shared { umbrella header "'
                    + name
                    + '.h" export * }\n'
                )
        update_spec(work, pod, source_files=[], vendored_frameworks=archive.name)
    (selected.parent / "Sources/main.m").write_text(
        (
            "@import Shared;\n"
            if collision
            else "@import FirstSDK;\n@import SecondSDK;\n"
        )
        + "#if FirstSDK_EXPECTED != 42 || SecondSDK_EXPECTED != 42\n#error Vendored API lost\n#endif\nint main(void) { return 0; }\n"
    )
    return work, selected


def vendor_module_collision(fixture):
    supported(fixture, vendor_pair_fixture, "vendor-pair-control")
    reject_conflict(fixture, vendor_pair_fixture, "vendor-pair-conflict")


def binary_facade_fixture(parent, *, collision=False):
    work, selected = module_fixture(parent, collision=False)
    archive = sdk(parent, "FacadeSDK", platforms=("macosx",))
    shutil.copytree(archive, work / "Other" / archive.name, symlinks=True)
    update_spec(work, "Kit", module_map="Author.modulemap")
    (work / "Kit/Author.modulemap").write_text(
        'module Shared { header "Kit.h" export * }\n'
    )
    module = "Shared" if collision else "BinaryAPI"
    update_spec(
        work,
        "Other",
        source_files=[],
        vendored_frameworks=archive.name,
        module_map="Author.modulemap",
    )
    (work / "Other/Author.modulemap").write_text(
        "module " + module + ' { header "Other.h" export * }\n'
    )
    (selected.parent / "Sources/main.m").write_text(
        "@import Shared;\n"
        + ("" if collision else "@import BinaryAPI;\n")
        + "#if KIT_A != 11 || KIT_B != 31\n#error Binary facade API lost\n#endif\nint main(void) { return 0; }\n"
    )
    return work, selected


def binary_facade_collision(fixture):
    supported(fixture, binary_facade_fixture, "binary-facade-control")
    reject_conflict(fixture, binary_facade_fixture, "binary-facade-conflict")


def header_phase_position(fixture):
    for braced in [False, True]:
        label = "header-phase-" + ("braces" if braced else "parentheses")
        work, selected = create(fixture.root / label)
        graph = read_project(selected)
        target_id = next(
            identifier
            for identifier, obj in graph["objects"].items()
            if obj.get("isa") == "PBXNativeTarget" and obj.get("name") == "Demo"
        )
        target = graph["objects"][target_id]
        copy_id = "F0F0F0F0F0F0F0F0F0F0F0F0"
        graph["objects"][copy_id] = {
            "isa": "PBXCopyFilesBuildPhase",
            "files": [],
            "buildActionMask": "2147483647",
            "runOnlyForDeploymentPostprocessing": "0",
            "dstSubfolderSpec": "0",
            "dstPath": (
                "${PUBLIC_HEADERS_FOLDER_PATH}"
                if braced
                else "$(PUBLIC_HEADERS_FOLDER_PATH)"
            )
            + "/Mapped",
        }
        target["buildPhases"].insert(0, copy_id)
        write_project(selected, graph)
        podfile = work / "Podfile"
        podfile.write_text(
            podfile.read_text()
            .split("post_install")[0]
            .replace(
                "target 'Demo' do",
                "target 'Demo' do\n script_phase :name => 'Generate mapped headers', :script => 'true', :execution_position => :before_headers, :always_out_of_date => '1'",
            )
        )
        for options in [(), ("--offline", "--deployment")]:
            fixture.cli(work, "install", *options)
            current = read_project(selected)["objects"]
            phases = current[target_id]["buildPhases"]
            script = next(
                identifier
                for identifier in phases
                if current[identifier].get("name")
                == "[CP-User] Generate mapped headers"
            )
            assert phases.index(script) < phases.index(copy_id), (label, phases)
        fixture.verified.append(label)


def lint_versioned_swift(fixture):
    lint = LintFixture()
    lint.root = fixture.root / "versioned-swift-lint"
    lint.root.mkdir()
    lint.env = fixture.env.copy()
    spec = lint.library(
        "consumer",
        {"source_files": [], "vendored_frameworks": "SwiftVendor.framework"},
        {},
    )
    framework = spec.parent / "SwiftVendor.framework"
    version = framework / "Versions/A"
    modules = version / "Modules/SwiftVendor.swiftmodule"
    modules.mkdir(parents=True)
    (version / "Resources").mkdir()
    (version / "Resources/Info.plist").write_bytes(
        plistlib.dumps(
            {
                "CFBundleExecutable": "SwiftVendor",
                "CFBundleName": "SwiftVendor",
                "CFBundleIdentifier": "org.swiftpods.SwiftVendor",
                "CFBundlePackageType": "FMWK",
                "CFBundleVersion": "1",
                "CFBundleShortVersionString": "1.0",
            }
        )
    )
    (framework / "Versions/Current").symlink_to("A")
    for name, target in [
        ("Modules", "Modules"),
        ("SwiftVendor", "SwiftVendor"),
        ("Resources", "Resources"),
        ("Info.plist", "Resources/Info.plist"),
    ]:
        (framework / name).symlink_to("Versions/Current/" + target)
    source = lint.root / "Value.swift"
    source.write_text("public func vendorValue() -> Int32 { 7 }\n")
    libraries = []
    for arch in ["arm64", "x86_64"]:
        library = lint.root / (arch + ".a")
        result = subprocess.run(
            [
                "xcrun",
                "swiftc",
                "-warnings-as-errors",
                "-target",
                arch + "-apple-macos14.0",
                "-module-name",
                "SwiftVendor",
                "-parse-as-library",
                "-emit-library",
                "-static",
                "-emit-module",
                "-emit-module-path",
                str(modules / (arch + "-apple-macos.swiftmodule")),
                str(source),
                "-o",
                str(library),
            ],
            capture_output=True,
            text=True,
            timeout=120,
        )
        assert result.returncode == 0 and not result.stderr, result.stderr
        libraries.append(str(library))
    subprocess.run(
        [
            "xcrun",
            "lipo",
            "-create",
            *libraries,
            "-output",
            str(version / "SwiftVendor"),
        ],
        check=True,
        timeout=60,
    )
    probe = lint.root / "Probe.swift"
    probe.write_text("import SwiftVendor\nlet value = vendorValue()\n")
    command = [
        "xcrun",
        "swiftc",
        "-warnings-as-errors",
        "-typecheck",
        "-target",
        platform.machine() + "-apple-macos14.0",
        "-F",
        str(spec.parent),
        str(probe),
    ]
    result = subprocess.run(command, capture_output=True, text=True, timeout=60)
    (lint.root / "valid-typecheck.log").write_text(result.stdout + result.stderr)
    assert result.returncode == 0 and not result.stderr, result.stderr
    lint.lint(spec, ["--skip-tests"], True, "versioned-swift-valid")
    fixture.verified.append("versioned-swift-valid-compiler-and-lint")
    for module in modules.glob("*.swiftmodule"):
        module.write_bytes(b"invalid Swift module\n")
    result = subprocess.run(command, capture_output=True, text=True, timeout=60)
    (lint.root / "broken-typecheck.log").write_text(result.stdout + result.stderr)
    assert (
        result.returncode > 0
        and "error:" in result.stderr
        and "SwiftVendor" in result.stderr
    ), result.stderr
    fixture.verified.append("broken-versioned-swift-interface-rejected-by-swiftc")
    report = lint.lint(spec, ["--skip-tests"], False, "versioned-swift-broken")
    assert any(
        error["code"] == "SP-LINT-CONSUMER" for error in report["errors"]
    ), report


def comment_map_fixture(parent, *, comment=False):
    work, selected = module_fixture(parent, collision=False)
    for pod, module in [("Kit", "FirstModule"), ("Other", "SecondModule")]:
        update_spec(work, pod, module_map="Author.modulemap")
        (work / pod / "Author.modulemap").write_text(
            ("/* authored */ " if comment else "")
            + "framework module "
            + module
            + ' { header "'
            + pod
            + '.h" export * }\n'
        )
    return work, selected


def commented_framework_maps(fixture):
    supported(fixture, comment_map_fixture, "framework-map-control")
    supported(fixture, comment_map_fixture, "framework-map-comment", comment=True)


def script_reorder(fixture):
    work, selected = create(fixture.root / "script-reorder")
    (selected.parent / "Sources/main.mm").write_text("int main(void) { return 0; }\n")
    original = (work / "Podfile").read_text().split("post_install")[0]

    def manifest(names):
        phases = "".join(
            " script_phase :name => '"
            + name
            + "', :script => 'printf "
            + name
            + ' >> "${PODS_PODFILE_DIR_PATH}/phase-order.txt"'
            + "', :execution_position => :before_compile, :always_out_of_date => '1'\n"
            for name in names
        )
        (work / "Podfile").write_text(
            original.replace("target 'Demo' do\n", "target 'Demo' do\n" + phases)
        )

    for names in [["A", "B"], ["B", "A"]]:
        manifest(names)
        fixture.cli(work, "install")
        output = work / "phase-order.txt"
        output.unlink(missing_ok=True)
        fixture.build(work, "Demo", "script-reorder-" + "".join(names))
        assert output.read_text() == "".join(names), output.read_text()
        fixture.verified.append("user-script-order-" + "".join(names))


def search_module_fixture(parent, *, collision=False):
    work, selected = module_fixture(parent, collision=collision)
    add_consumer(selected)
    (work / "Podfile").write_text(
        "platform :osx, '13.0'\nproject '../Apps/External.xcodeproj'\nuse_modular_headers!\n"
        "target 'Other' do\n pod 'Other', :path => './Other'\n target 'Demo' do\n inherit! :search_paths\n pod 'Kit', :path => './Kit'\n end\nend\n"
    )
    return work, selected


def search_module_collision(fixture):
    supported(fixture, search_module_fixture, "search-modules-control")
    reject_conflict(fixture, search_module_fixture, "search-modules-conflict")


CASES = [
    ("project-path-case-collision", project_collision),
    ("configuration-file-case-collision", configuration_files),
    ("case-sensitive-module-names", case_sensitive_modules),
    ("binary-module-collision", vendor_module_collision),
    ("binary-explicit-module-map", binary_facade_collision),
    ("braced-header-phase-position", header_phase_position),
    ("versioned-swift-lint", lint_versioned_swift),
    ("commented-framework-map", commented_framework_maps),
    ("reordered-user-script-phases", script_reorder),
    ("search-only-module-collision", search_module_collision),
]


def run_regressions(fixture):
    results = []
    for name, run in CASES:
        print("Audit contract:", name, flush=True)
        try:
            run(fixture)
            results.append({"case": name, "status": "passed"})
        except (AssertionError, RuntimeError) as error:
            results.append({"case": name, "status": "failed", "error": str(error)})
        (fixture.root / "audit-coverage.json").write_text(
            json.dumps(results, indent=2) + "\n"
        )
        (fixture.root / "audit-controls.json").write_text(
            json.dumps(fixture.verified, indent=2) + "\n"
        )
    failed = [row["case"] for row in results if row["status"] == "failed"]
    assert not failed, "Audit contract failures: " + ", ".join(failed)


def main():
    from Tests.Integration.native_lifecycle_tests import LifecycleFixture

    fixture = LifecycleFixture()
    print("Audit coverage fixtures:", fixture.root, flush=True)
    run_regressions(fixture)
    (results_directory() / "native-audit-coverage.json").write_text(
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
    from scripts.support.reporting import execute

    execute(main, "native-audit-coverage.json")
