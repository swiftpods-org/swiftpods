"""Real consumers for input semantics, provenance, public interfaces and ODR."""

import copy
import hashlib
import json
import platform
import subprocess

from consumer_build_regressions import install_twice, podfile, update_spec
from native_integration import serialize
from native_xcconfig_tests import create
from vendor_fixture import fixture_build_arguments
from workspace_resource_regressions import read_project


def save_project(path, graph):
    (path / "project.pbxproj").write_text("// !$*UTF8*$!\n" + serialize(graph))


def git(repository, *args):
    return subprocess.check_output(
        ["git", "-C", str(repository), *args], text=True, stderr=subprocess.STDOUT
    ).strip()


def commit(repository, message):
    git(repository, "add", ".")
    git(
        repository,
        "-c",
        "user.name=Fixture",
        "-c",
        "user.email=fixture@swiftpods.org",
        "-c",
        "commit.gpgsign=false",
        "commit",
        "-m",
        message,
    )
    return git(repository, "rev-parse", "HEAD")


def diagnostic(report, code):
    events = report.get("events", []) + [report.get("diagnostic", {})]
    assert any(event.get("code") == code for event in events), report


def recover(fixture, work, report):
    if report.get("project_state") == "recovery_required":
        fixture.cli(work, "recover")


def snapshot_provenance(fixture):
    work, _ = create(fixture.root / "snapshot-provenance")
    repo = work / "Kit"

    def hg(*args):
        return subprocess.check_output(
            ["hg", "--cwd", str(repo), *args], text=True, stderr=subprocess.STDOUT
        ).strip()

    hg("init")
    hg("add")
    hg("commit", "-u", "Fixture <fixture@swiftpods.org>", "-m", "one")
    first = hg("log", "-r", ".", "--template", "{node}")
    (work / "Podfile").write_text(
        podfile(work).replace(":path => './Kit'", ":hg => " + repr(str(repo)))
    )
    fixture.cli(work, "install", "--no-integrate")
    locked = (work / "Podfile.lock").read_bytes()
    source = (work / "Pods/Kit/Kit.c").read_bytes()
    (repo / "Kit.c").write_text("int kit_value(void) { return 9; }\n")
    hg("commit", "-u", "Fixture <fixture@swiftpods.org>", "-m", "two")
    second = hg("log", "-r", ".", "--template", "{node}")
    originals = {}
    try:
        for path in (fixture.root / "cache/snapshots").glob("*.origin.json"):
            metadata = json.loads(path.read_text())
            if metadata.get("checkout", {}).get("hg") != str(repo):
                continue
            originals[path] = path.read_bytes()
            metadata["checkout"]["revision"] = second
            path.write_text(json.dumps(metadata))
        assert len(originals) == 2
        diagnostic(
            fixture.cli(work, "cache", "verify", succeeds=False), "SP-CACHE-INTEGRITY"
        )
        report = fixture.cli(
            work, "install", "--no-integrate", "--offline", succeeds=False
        )
        diagnostic(report, "SP-CACHE-INTEGRITY")
        assert (work / "Podfile.lock").read_bytes() == locked
        assert (work / "Pods/Kit/Kit.c").read_bytes() == source
        recover(fixture, work, report)
    finally:
        for path, data in originals.items():
            path.write_bytes(data)
    fixture.cli(work, "install", "--no-integrate", "--offline", "--deployment")
    assert first in (work / "Podfile.lock").read_text()
    fixture.verified.append(
        "snapshot_provenance_corruption_rejected_without_lock_or_source_changes"
    )


def incremental_provenance(fixture):
    work, _ = create(fixture.root / "incremental-provenance")
    repo = work / "Kit"
    git(repo, "init", "-b", "main")
    first = commit(repo, "one")
    (work / "Podfile").write_text(
        "install! 'cocoapods', :incremental_installation => true\n"
        + podfile(work).replace(":path => './Kit'", ":git => " + repr(str(repo)))
    )
    for _ in range(2):
        fixture.cli(work, "install", "--no-integrate")
    locked = (work / "Podfile.lock").read_bytes()
    source = (work / "Pods/Kit/Kit.c").read_bytes()
    path = work / "Pods/Target Support Files/Kit/source-state.json"
    original = path.read_bytes()
    (repo / "Kit.c").write_text("int kit_value(void) { return 9; }\n")
    second = commit(repo, "two")
    metadata = json.loads(original)
    metadata["checkout"]["commit"] = second
    path.write_text(json.dumps(metadata))
    report = fixture.cli(work, "install", "--no-integrate", "--offline", succeeds=False)
    diagnostic(report, "SP-CACHE-INTEGRITY")
    assert (work / "Podfile.lock").read_bytes() == locked
    assert (work / "Pods/Kit/Kit.c").read_bytes() == source
    recover(fixture, work, report)
    path.write_bytes(original)
    fixture.cli(work, "install", "--no-integrate", "--offline", "--deployment")
    assert first in (work / "Podfile.lock").read_text()
    fixture.verified.append(
        "incremental_provenance_corruption_rejected_without_lock_or_source_changes"
    )


def modules(fixture):
    for scenario in ["derived-module", "header-module-api", "disabled-map"]:
        work, selected = create(fixture.root / scenario)
        body = podfile(work)
        if scenario == "disabled-map":
            update_spec(work, module_map=False)
            (work / "Podfile").write_text(
                body.replace(
                    ":path => './Kit'", ":path => './Kit', :modular_headers => true"
                )
            )
            install_twice(fixture, work)
            assert not list((work / "Pods/Headers/Public").rglob("*.modulemap"))
        else:
            name = "Kit--Core" if scenario == "derived-module" else "Kit"
            module = "Kit_Core" if scenario == "derived-module" else "Custom_Kit"
            data = update_spec(
                work,
                name=name,
                **(
                    {"header_dir": "Custom-Kit"}
                    if scenario == "header-module-api"
                    else {}
                ),
            )
            if name != "Kit":
                (work / "Kit/Kit.podspec.json").unlink()
                (work / "Kit" / (name + ".podspec.json")).write_text(json.dumps(data))
            graph = read_project(selected)
            for obj in graph["objects"].values():
                if obj.get("isa") == "XCBuildConfiguration":
                    obj["buildSettings"]["CLANG_ENABLE_MODULES"] = "YES"
                if obj.get("isa") == "PBXFileReference" and str(
                    obj.get("path", "")
                ).endswith("main.mm"):
                    obj.update(
                        path=obj["path"][:-3] + ".m",
                        lastKnownFileType="sourcecode.c.objc",
                    )
            save_project(selected, graph)
            (selected.parent / "Sources/main.m").write_text(
                "@import "
                + module
                + ";\nint main(void) { return kit_value() == 7 ? 0 : 1; }\n"
            )
            (work / "Podfile").write_text(
                "use_frameworks! :linkage => :static\nrequire 'cocoapods-core/specification/dsl'\n"
                + body.replace("pod 'Kit'", "pod '" + name + "'")
                + """post_install do |installer|
  target = installer.pod_targets.first
  native = installer.target_installation_results.pod_target_installation_results.fetch(target.label).native_target
  raise 'Module identity differs' unless target.root_spec.module_name == target.product_module_name && target.product_name == native.product_reference.path && target.product_module_name == native.build_configurations.first.build_settings['PRODUCT_MODULE_NAME']
end
"""
            )
            install_twice(fixture, work)
        fixture.build(work, "Demo", scenario + "-build")
        fixture.verified.append(scenario + "_consumer_and_reinstall")


def on_demand_resources(fixture):
    work, selected = create(fixture.root / "odr-inputs")
    repo = work / "Kit"
    assets = repo / "Assets"
    assets.mkdir()
    for name in ["payload", "other", "full"]:
        (assets / (name + ".txt")).write_text(name)
    for language in ["en", "fr"]:
        localized = assets / (language + ".lproj")
        localized.mkdir()
        (localized / "Localizable.strings").write_text('"hello" = "Hello";\n')
    update_spec(
        work,
        on_demand_resources={
            "Short": "Assets/payload.txt",
            "Array": ["Assets/other.txt"],
            "Full": {"paths": "Assets/full.txt"},
            "Language": {"paths": "Assets/**/*.strings", "category": "initial_install"},
            "English": {"paths": "Assets/en.lproj/*.strings", "category": "prefetched"},
        },
        appspecs=[{"name": "Example", "source_files": "Example.m"}],
    )
    (repo / "Example.m").write_text("int main(void) { return 0; }\n")
    git(repo, "init", "-b", "main")
    commit(repo, "resources")
    (work / "Podfile").write_text(
        podfile(work).replace(
            ":path => './Kit'",
            ":git => " + repr(str(repo)) + ", :appspecs => ['Example']",
        )
    )
    install_twice(fixture, work)
    assert all(
        (work / "Pods/Kit/Assets" / (name + ".txt")).is_file()
        for name in ["payload", "other", "full"]
    )
    for project in [selected, work / "Pods/Pods.xcodeproj"]:
        objects = read_project(project)["objects"]
        observed = {}
        for obj in objects.values():
            if obj.get("isa") != "PBXBuildFile":
                continue
            ref = objects.get(obj.get("fileRef"), {})
            path = ref.get("path", "")
            if path.endswith(".strings"):
                observed[path] = obj.get("settings", {}).get("ASSET_TAGS")
        assert len(observed) == 2, observed
        for path, tags in observed.items():
            assert tags == (
                ["English", "Language"] if "en.lproj" in path else ["Language"]
            ), (path, tags)
    fixture.verified += [
        "short_array_and_full_odr_inputs_survive_cleanup",
        "localized_odr_keep_distinct_tags_in_user_and_supplementary_targets",
    ]


def lint_interfaces(fixture):
    work, _ = create(fixture.root / "lint-interface")
    library = work / "Kit"
    header = library / "Kit.h"
    original = header.read_bytes()
    (library / "LICENSE").write_text("MIT License\n")
    header.write_text("#error Invalid public interface\n")
    for flags in [[], ["--use-libraries"]]:
        report = fixture.cli(
            work,
            "lib",
            "lint",
            str(library / "Kit.podspec.json"),
            "--platforms=osx",
            *flags,
            succeeds=False,
        )
        validation = next(
            event["data"] for event in report["events"] if event["kind"] == "validation"
        )
        assert validation[
            "status"
        ] == "failed" and "Invalid public interface" in json.dumps(validation)
    for layout in ["platform-header-directory", "mapped-framework-headers"]:
        scoped_work, _ = create(fixture.root / layout)
        scoped_library = scoped_work / "Kit"
        scoped_spec = scoped_library / "Kit.podspec.json"
        (scoped_library / "LICENSE").write_text("MIT License\n")
        scoped_header = scoped_library / "Kit.h"
        if layout == "platform-header-directory":
            update_spec(scoped_work, osx={"header_dir": "PlatformKit"})
            flags = ["--use-libraries"]
        else:
            scoped_header = scoped_library / "Include/Deep/Kit.h"
            scoped_header.parent.mkdir(parents=True)
            update_spec(
                scoped_work,
                source_files=["Kit.c", "Include/**/*.h"],
                header_mappings_dir="Include",
                osx={"module_map": False},
            )
            flags = []
        scoped_header.write_text("#error Scoped public interface\n")
        report = fixture.cli(
            scoped_work,
            "lib",
            "lint",
            str(scoped_spec),
            "--platforms=osx",
            *flags,
            succeeds=False,
        )
        validation = next(
            event["data"] for event in report["events"] if event["kind"] == "validation"
        )
        assert validation[
            "status"
        ] == "failed" and "Scoped public interface" in json.dumps(validation)
        scoped_header.write_bytes(original)
        fixture.cli(
            scoped_work, "lib", "lint", str(scoped_spec), "--platforms=osx", *flags
        )
        fixture.verified.append(layout + "_public_interface_is_validated")
    objc_work, _ = create(fixture.root / "lint-objc-interface")
    objc_library = objc_work / "Kit"
    (objc_library / "LICENSE").write_text("MIT License\n")
    (objc_library / "Kit.h").write_text(
        "#import <Foundation/Foundation.h>\n@interface Kit : NSObject { __weak NSObject *_delegate; }\n@property(nonatomic, weak) NSObject *delegate;\n@end\n"
    )
    (objc_library / "Kit.m").write_text('#import "Kit.h"\n@implementation Kit\n@end\n')
    update_spec(
        objc_work, source_files="*.{m,h}", requires_arc=True, frameworks=["Foundation"]
    )
    fixture.cli(
        objc_work,
        "lib",
        "lint",
        str(objc_library / "Kit.podspec.json"),
        "--platforms=osx",
    )
    fixture.verified.append("lint_imports_an_arc_objc_public_interface")
    header.write_bytes(original)
    for flags in [[], ["--use-libraries"]]:
        fixture.cli(
            work,
            "lib",
            "lint",
            str(library / "Kit.podspec.json"),
            "--platforms=osx",
            *flags,
        )
    update_spec(
        work,
        platforms={
            "osx": "14.0",
            "ios": "16.0",
            "tvos": "16.0",
            "watchos": "9.0",
            "visionos": "1.0",
        },
    )
    for platform_name in ["osx", "ios", "tvos", "watchos", "visionos"]:
        fixture.cli(
            work,
            "lib",
            "lint",
            str(library / "Kit.podspec.json"),
            "--platforms=" + platform_name,
        )
    fixture.verified.append("lint_public_consumers_build_for_all_five_platforms")
    (library / "Kit.swift").write_text("public func value() -> Int { 7 }\n")
    update_spec(work, source_files="*.swift", swift_versions=["5.0"])
    for flags in [[], ["--use-libraries"]]:
        fixture.cli(
            work,
            "lib",
            "lint",
            str(library / "Kit.podspec.json"),
            "--platforms=osx",
            *flags,
        )
    fixture.verified += [
        "lint_rejects_broken_public_header_in_framework_and_library",
        "lint_compiles_valid_objc_and_swift_consumers_in_both_modes",
    ]


def add_consumer(selected):
    graph = read_project(selected)
    objects = graph["objects"]
    project = objects[graph["rootObject"]]
    original = next(
        obj for obj in objects.values() if obj.get("isa") == "PBXNativeTarget"
    )

    def clone(identifier):
        new = hashlib.sha256(("Other:" + identifier).encode()).hexdigest()[:24].upper()
        objects[new] = copy.deepcopy(objects[identifier])
        return new

    target = copy.deepcopy(original)
    identifier = hashlib.sha256(b"Other:target").hexdigest()[:24].upper()
    objects[identifier] = target
    project["targets"].append(identifier)
    target.update(name="Other", productName="Other")
    target["productReference"] = clone(original["productReference"])
    objects[target["productReference"]]["path"] = "Other.app"
    objects[project["productRefGroup"]]["children"].append(target["productReference"])
    target["buildConfigurationList"] = clone(original["buildConfigurationList"])
    configurations = [
        clone(value)
        for value in objects[original["buildConfigurationList"]]["buildConfigurations"]
    ]
    objects[target["buildConfigurationList"]]["buildConfigurations"] = configurations
    for identifier in configurations:
        objects[identifier].pop("baseConfigurationReference", None)
        objects[identifier]["buildSettings"]["PRODUCT_NAME"] = "Other"
    target["buildPhases"] = [clone(value) for value in original["buildPhases"]]
    for phase in target["buildPhases"]:
        objects[phase]["files"] = [
            clone(value) for value in objects[phase].get("files", [])
        ]
    save_project(selected, graph)


def inheritance_case(parent, cli, env):
    work, selected = create(parent)
    add_consumer(selected)
    (selected.parent / "Sources/main.mm").write_text(
        "#include <Kit/Kit.h>\nint main(void) { return kit_value() == 7 ? 0 : 1; }\n"
    )
    declaration = "platform :osx, '13.0'\nproject '../Apps/External.xcodeproj'\ntarget 'Demo' do\n pod 'Kit', :path => './Kit'\n target 'Other' do\n  inherit! :none\n  pod 'Kit', :path => './Kit'\n end\nend\n"
    (work / "Podfile").write_text(declaration)
    cli(work, "install")
    build_root = parent / "consumer-build"
    build_root.mkdir()
    result = subprocess.run(
        [
            "xcodebuild",
            "-workspace",
            str(next(work.glob("*.xcworkspace"))),
            "-scheme",
            "Other",
            "-configuration",
            "Debug",
            "-destination",
            "platform=macOS,arch=" + platform.machine(),
            *fixture_build_arguments(build_root),
            "CODE_SIGNING_ALLOWED=NO",
            "build",
        ],
        cwd=work,
        env=env,
        capture_output=True,
        text=True,
        timeout=180,
    )
    output = result.stdout + result.stderr
    (parent / "consumer.log").write_text(output)
    return {
        "input_sha256": hashlib.sha256(declaration.encode()).hexdigest(),
        "build_status": result.returncode,
        "diagnostics": [
            line
            for line in output.splitlines()
            if "error:" in line or "warning:" in line or "Undefined symbols" in line
        ],
    }


def run(fixture):
    snapshot_provenance(fixture)
    incremental_provenance(fixture)
    modules(fixture)
    on_demand_resources(fixture)
    lint_interfaces(fixture)
