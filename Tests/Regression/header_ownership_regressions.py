"""Regression fixtures for header generation, bundle identity and hook ownership."""

import hashlib
import json
import platform
import plistlib
import re

from scripts.support.processes import run_logged
from Tests.Fixtures.vendor_fixture import fixture_build_arguments
from Tests.Integration.native_integration import serialize
from Tests.Integration.native_xcconfig_tests import create
from Tests.Regression.workspace_resource_regressions import add_consumer, read_project


def write_project(selected, graph):
    (selected / "project.pbxproj").write_text("// !$*UTF8*$!\n" + serialize(graph))


def resources_in_app(fixture, label, target="Demo"):
    return fixture.root / label / "DerivedData/Build/Products/Debug" / (target + ".app")


def ownership(fixture):
    work, selected = create(fixture.root / "foreign-phases")
    add_consumer(selected)
    graph = read_project(selected)
    objects = graph["objects"]
    other = next(
        o
        for o in objects.values()
        if o.get("name") == "Other" and o.get("isa") == "PBXNativeTarget"
    )
    saved = {}
    for name in [
        "[CP-User] Keep Other script",
        "[CP] Embed Pods Frameworks",
        "User control phase",
    ]:
        identifier = (
            hashlib.sha256(("foreign:" + name).encode()).hexdigest()[:24].upper()
        )
        objects[identifier] = {
            "isa": "PBXShellScriptBuildPhase",
            "name": name,
            "files": [],
            "buildActionMask": "2147483647",
            "runOnlyForDeploymentPostprocessing": "0",
            "shellPath": "/bin/sh",
            "shellScript": 'printf kept > "${SCRIPT_OUTPUT_FILE_0}"\n',
            "inputPaths": [],
            "outputPaths": ["$(DERIVED_FILE_DIR)/" + identifier],
        }
        other["buildPhases"].append(identifier)
        saved[identifier] = objects[identifier]
    original = json.dumps(other, sort_keys=True)
    write_project(selected, graph)
    for command in [("install",), ("install",), ("deintegrate",)]:
        fixture.cli(work, *command)
        current = read_project(selected)["objects"]
        actual = next(
            o
            for o in current.values()
            if o.get("name") == "Other" and o.get("isa") == "PBXNativeTarget"
        )
        assert json.dumps(actual, sort_keys=True) == original, command
        assert all(current[key] == value for key, value in saved.items()), command
    fixture.verified.append(
        "unselected_target_phases_survive_install_reinstall_deintegrate"
    )


def private_headers(fixture):
    work, _ = create(fixture.root / "private-library-headers")
    library = work / "Kit"
    (library / "Private.h").write_text("#define PRIVATE_VALUE 7\n")
    (library / "Project.h").write_text("#define PROJECT_VALUE 7\n")
    (library / "Kit.c").write_text(
        "#include <Kit/Private.h>\n#include <Kit/Project.h>\n"
        "int kit_value(void) { return PRIVATE_VALUE + PROJECT_VALUE - 7; }\n"
    )
    spec = library / "Kit.podspec.json"
    data = json.loads(spec.read_text())
    data.update(
        public_header_files="Kit.h",
        private_header_files="Private.h",
        project_header_files="Project.h",
    )
    spec.write_text(json.dumps(data))
    fixture.cli(work, "install")
    fixture.cli(work, "install", "--deployment")
    for name in ["Private.h", "Project.h"]:
        paths = list((work / "Pods/Headers/Private").rglob(name))
        assert len(paths) == 1 and paths[0].resolve() == (library / name).resolve(), (
            paths
        )
        assert not list((work / "Pods/Headers/Public").rglob(name))
    fixture.build(work, "Demo", "private-library-headers-build")
    fixture.verified.append(
        "private_project_library_headers_build_without_public_exposure"
    )


def module_maps(fixture):
    for language in ["objc", "swift"]:
        work, selected = create(fixture.root / ("custom-map-" + language))
        graph = read_project(selected)
        for obj in graph["objects"].values():
            if obj.get("isa") == "XCBuildConfiguration":
                obj["buildSettings"].update(
                    CLANG_ENABLE_MODULES="YES", SWIFT_VERSION="5.0"
                )
            if obj.get("isa") == "PBXFileReference" and str(
                obj.get("path", "")
            ).endswith("main.mm"):
                suffix = ".m" if language == "objc" else ".swift"
                obj["path"] = obj["path"][:-3] + suffix
                obj["lastKnownFileType"] = (
                    "sourcecode.c.objc" if language == "objc" else "sourcecode.swift"
                )
        source = selected.parent / "Sources/main.mm"
        source.unlink()
        if language == "objc":
            (source.parent / "main.m").write_text(
                "@import Feature;\n#if FEATURE_VALUE != 7\n#error Custom module missing\n#endif\nint main(void) { return 0; }\n"
            )
        else:
            (source.parent / "main.swift").write_text(
                "import Feature\nimport AppIntents\n"
                "struct FeatureIntent: AppIntent {\n"
                ' static var title: LocalizedStringResource = "Feature"\n'
                " func perform() async throws -> some IntentResult & ReturnsValue<Int> {\n"
                "  .result(value: Int(FEATURE_VALUE))\n }\n}\n"
                "precondition(FEATURE_VALUE == 7)\n"
            )
        write_project(selected, graph)
        library = work / "Kit"
        (library / "Feature.h").write_text("#define FEATURE_VALUE 7\n")
        contents = 'module Kit { header "Kit.h" export * }\nmodule Feature { header "Feature.h" export * }\n'
        if language == "objc":
            contents = "framework " + contents
        modulemap = library / "Custom.modulemap"
        modulemap.write_text(contents)
        spec = library / "Kit.podspec.json"
        data = json.loads(spec.read_text())
        data.update(module_map="Custom.modulemap", public_header_files="*.h")
        spec.write_text(json.dumps(data))
        fixture.cli(work, "install")
        fixture.cli(work, "install", "--deployment")
        fixture.build(work, "Demo", "custom-map-build-" + language)
        assert modulemap.read_text() == contents
        fixture.verified.append("custom_module_map_reaches_" + language + "_consumer")


def build_generated_headers(fixture, work, label):
    """Keep the known Xcode scheduling advisory visible; compiler warnings fail."""
    build_root = fixture.root / label
    build_root.mkdir()
    log = fixture.root / (label + ".log")
    status = run_logged(
        [
            "xcodebuild",
            "-workspace",
            next(work.glob("*.xcworkspace")),
            "-scheme",
            "Demo",
            "-configuration",
            "Debug",
            "-destination",
            "platform=macOS,arch=" + platform.machine(),
            *fixture_build_arguments(build_root),
            "CODE_SIGNING_ALLOWED=NO",
            "build",
        ],
        work,
        log,
    )
    text = log.read_text(errors="replace")
    warnings = [line for line in text.splitlines() if "warning:" in line]
    advisory = re.compile(
        r"^.*Pods\.xcodeproj: warning: tasks in 'Copy Headers' are delayed by unsandboxed script phases; "
        r"set ENABLE_USER_SCRIPT_SANDBOXING=YES to enable sandboxing \(in target 'Kit' from project 'Pods'\)$"
    )
    assert status == 0 and all(advisory.fullmatch(line) for line in warnings), log
    return warnings


def generated_headers(fixture):
    for mode in ["static", "dynamic"]:
        work, selected = create(fixture.root / ("generated-header-" + mode))
        library = work / "Kit"
        (library / "Headers/Sub").mkdir(parents=True)
        (library / "Headers/Private").mkdir()
        (library / "Kit.h").unlink()
        header = library / "Headers/Sub/Kit.h"
        header.write_text("#define GENERATED_VALUE 1\nint kit_value(void);\n")
        (library / "Headers/Private/Inner.h").write_text("#define PRIVATE_VALUE 1\n")
        (library / "Headers/Flat.h").write_text("// flat public header\n")
        (library / "Kit.c").write_text(
            "#include <Kit/Sub/Kit.h>\n#include <Kit/Private/Inner.h>\n"
            "#if GENERATED_VALUE != 7 || PRIVATE_VALUE != 7\n#error Stale generated header\n#endif\n"
            "int kit_value(void) { return GENERATED_VALUE; }\n"
        )
        script = (
            "printf '#define GENERATED_VALUE 7\\nint kit_value(void);\\n' > \"${PODS_TARGET_SRCROOT}/Headers/Sub/Kit.h\"\n"
            "printf '#define PRIVATE_VALUE 7\\n' > \"${PODS_TARGET_SRCROOT}/Headers/Private/Inner.h\"\n"
        )
        spec = library / "Kit.podspec.json"
        data = json.loads(spec.read_text())
        data.update(
            source_files=["*.c", "Headers/**/*.h"],
            header_mappings_dir="Headers",
            public_header_files=["Headers/Sub/*.h", "Headers/Flat.h"],
            private_header_files="Headers/Private/*.h",
            script_phases=[
                {
                    "name": "Generate",
                    "script": script,
                    "execution_position": "before_headers",
                    "always_out_of_date": "1",
                }
            ],
        )
        spec.write_text(json.dumps(data))
        main = selected.parent / "Sources/main.mm"
        main.write_text(
            main.read_text().replace(
                "#include <Kit/Kit.h>", 'extern "C" {\n#include <Kit/Sub/Kit.h>\n}'
            )
        )
        (work / "Podfile").write_text(
            "use_frameworks! :linkage => :"
            + mode
            + "\n"
            + (work / "Podfile").read_text()
        )
        fixture.cli(work, "install")
        label = "generated-header-build-" + mode
        warnings = build_generated_headers(fixture, work, label)
        framework = (
            fixture.root / label / "DerivedData/Build/Products/Debug/Kit.framework"
        )
        assert "GENERATED_VALUE 7" in (framework / "Headers/Sub/Kit.h").read_text()
        assert (
            "PRIVATE_VALUE 7"
            in (framework / "PrivateHeaders/Private/Inner.h").read_text()
        )
        assert (framework / "Headers/Flat.h").exists()
        # Preserve the advisory as evidence instead of suppressing Xcode output.
        (fixture.root / (label + "-advisories.json")).write_text(
            json.dumps(warnings, indent=2)
        )
        fixture.verified.append(
            "before_headers_generates_public_private_headers_" + mode
        )


def bundle_identity(fixture):
    work, selected = create(fixture.root / "ambiguous-bundle-pairs")
    add_consumer(selected)
    (selected.parent / "Sources/main.mm").write_text("int main(void) { return 0; }\n")
    for name, bundle in [("Kit-A", "Shared"), ("Kit", "A-Shared")]:
        library = work / name
        library.mkdir(exist_ok=True)
        (library / "Value.c").write_text(
            "void " + name.replace("-", "_").lower() + "(void) {}\n"
        )
        (library / (name + ".txt")).write_text(name + " marker\n")
        (library / (name + ".podspec.json")).write_text(
            json.dumps(
                {
                    "name": name,
                    "version": "1.0",
                    "source_files": "*.c",
                    "platforms": {"osx": "13.0"},
                    "resource_bundles": {bundle: "*.txt"},
                }
            )
        )
    (work / "Podfile").write_text(
        "platform :osx, '13.0'\nproject '../Apps/External.xcodeproj'\n"
        "target 'Demo' do\n pod 'Kit-A', :path => './Kit-A'\nend\n"
        "target 'Other' do\n pod 'Kit', :path => './Kit'\nend\n"
    )
    fixture.cli(work, "install")
    before = (work / "Pods/Pods.xcodeproj/project.pbxproj").read_bytes()
    fixture.cli(work, "install")
    assert (work / "Pods/Pods.xcodeproj/project.pbxproj").read_bytes() == before
    objects = read_project(work / "Pods/Pods.xcodeproj")["objects"]
    targets = [
        o
        for o in objects.values()
        if o.get("productType") == "com.apple.product-type.bundle"
    ]
    assert len(targets) == 2 and len({o["name"] for o in targets}) == 2
    assert len({o["productReference"] for o in targets}) == 2
    for target, name, bundle, absent in [
        ("Demo", "Kit-A", "Shared", "Kit"),
        ("Other", "Kit", "A-Shared", "Kit-A"),
    ]:
        label = "ambiguous-bundle-build-" + target
        fixture.build(work, target, label)
        app = resources_in_app(fixture, label, target)
        markers = list(app.rglob(name + ".txt"))
        assert len(markers) == 1 and markers[0].read_text() == name + " marker\n"
        assert bundle + ".bundle" in str(markers[0])
        assert not list(app.rglob(absent + ".txt"))
    fixture.verified.append(
        "ambiguous_bundle_display_names_keep_distinct_products_and_payloads"
    )


def hook_lookups(fixture):
    work, _ = create(fixture.root / "hook-subspec-platform")
    spec = work / "Kit/Kit.podspec.json"
    data = json.loads(spec.read_text())
    data.update(source_files=[], subspecs=[{"name": "Core", "source_files": "*.{c,h}"}])
    spec.write_text(json.dumps(data))
    body = (work / "Podfile").read_text().replace("pod 'Kit',", "pod 'Kit/Core',")
    body += """pre_install do |installer|
  sandbox = installer.sandbox
  raise 'wrong subspec path' unless sandbox.pod_dir('Kit/Core') == sandbox.pod_dir('Kit')
  raise 'missing root spec' unless sandbox.specification('Kit/Core').equal?(sandbox.specification('Kit'))
  raise 'platform comparison skipped target' unless installer.pod_targets.select { |pod| pod.platform == :osx }.map(&:pod_name) == ['Kit']
end
"""
    (work / "Podfile").write_text(body)
    fixture.cli(work, "install")
    fixture.cli(work, "install", "--deployment")
    fixture.verified.append(
        "real_hook_sandbox_subspec_lookup_and_platform_symbol_comparison"
    )


def bundle_identifier(fixture):
    work, _ = create(fixture.root / "resource-bundle-identifier")
    library = work / "Kit"
    (library / "payload.txt").write_text("payload\n")
    spec = library / "Kit.podspec.json"
    data = json.loads(spec.read_text())
    data.update(
        resource_bundles={"Kit_Resources": "payload.txt", "Kit+Assets": "payload.txt"}
    )
    spec.write_text(json.dumps(data))
    fixture.cli(work, "install")
    label = "resource-bundle-identifier-build"
    fixture.build(work, "Demo", label)
    app = resources_in_app(fixture, label)
    for name, expected in [
        ("Kit_Resources", "Kit-Resources"),
        ("Kit+Assets", "Kit-Assets"),
    ]:
        bundle = next(app.rglob(name + ".bundle"))
        info = plistlib.loads(next(bundle.rglob("Info.plist")).read_bytes())
        assert info["CFBundleIdentifier"] == "org.swiftpods." + expected, info
        assert next(bundle.rglob("payload.txt")).read_text() == "payload\n"
    fixture.verified.append(
        "bundle_identifiers_normalize_underscore_plus_without_renaming_products"
    )


def run(fixture):
    ownership(fixture)
    private_headers(fixture)
    module_maps(fixture)
    generated_headers(fixture)
    bundle_identity(fixture)
    hook_lookups(fixture)
    bundle_identifier(fixture)
