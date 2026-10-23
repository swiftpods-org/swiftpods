"""Regression fixtures for header generation, bundle identity and hook ownership."""

import hashlib
import json
import platform
import plistlib
import re
import subprocess

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


def consumer_resource_bundle_identity(fixture):
    work, selected = create(fixture.root / "consumer-resource-bundle-collision")
    graph = read_project(selected)
    objects = graph["objects"]
    consumer = next(o for o in objects.values() if o.get("isa") == "PBXNativeTarget")
    consumer.update(name="A-B", productName="A-B")
    objects[consumer["productReference"]]["path"] = "A-B.app"
    for key in objects[consumer["buildConfigurationList"]]["buildConfigurations"]:
        objects[key]["buildSettings"]["PRODUCT_NAME"] = "A-B"
    write_project(selected, graph)
    for path in (selected.parent / "Configs").glob("*.xcconfig"):
        path.write_text(path.read_text().replace("Pods-Demo", "Pods-A-B"))
    (selected.parent / "Sources/main.mm").write_text("int main(void) { return 0; }\n")
    library = work / "Kit"
    (library / "Loose.txt").write_text("loose payload\n")
    (library / "Bundled.txt").write_text("bundled payload\n")
    spec = library / "Kit.podspec.json"
    data = json.loads(spec.read_text())
    data.update(
        name="Pods-A", resources="Loose.txt",
        resource_bundles={"B-Resources": "Bundled.txt"},
    )
    spec.rename(library / "Pods-A.podspec.json")
    (library / "Pods-A.podspec.json").write_text(json.dumps(data))
    body = (work / "Podfile").read_text().split("post_install")[0]
    (work / "Podfile").write_text(
        body.replace("target 'Demo'", "target 'A-B'").replace("pod 'Kit'", "pod 'Pods-A'")
    )
    fixture.cli(work, "install")
    project = work / "Pods/Pods.xcodeproj/project.pbxproj"
    before = project.read_bytes()
    fixture.cli(work, "install", "--deployment", "--offline")
    assert project.read_bytes() == before
    label = "consumer-resource-bundle-build"
    fixture.build(work, "A-B", label)
    app = resources_in_app(fixture, label, "A-B")
    bundled = list(app.rglob("Bundled.txt"))
    loose = list(app.rglob("Loose.txt"))
    assert len(bundled) == 1 and bundled[0].read_text() == "bundled payload\n"
    assert "B-Resources.bundle" in str(bundled[0])
    assert len(loose) == 1 and loose[0].read_text() == "loose payload\n"
    assert "B-Resources.bundle" not in str(loose[0])
    fixture.verified.append(
        "pod_bundle_and_consumer_resources_keep_distinct_configs_phases_and_payloads"
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
    consumer_resource_bundle_identity(fixture)
    hook_lookups(fixture)
    bundle_identifier(fixture)
    authored_umbrellas(fixture)
    header_collisions(fixture)
    quoted_header_namespace(fixture)


def authored_umbrellas(fixture):
    for mode in ["library", "modular-library", "static", "dynamic"]:
        label = "authored-umbrella-" + mode
        work, selected = create(fixture.root / label)
        library = work / "Kit"
        authored = library / "Kit-umbrella.h"
        original = b"#pragma once\n#define KIT_PUBLIC_VALUE 7\n"
        authored.write_bytes(original)
        # The generated fallback name can itself be an authored API.
        (library / "Kit-swiftpods-umbrella-1.h").write_text("#pragma once\n")
        podfile = work / "Podfile"
        text = podfile.read_text()
        if mode in ["static", "dynamic"]:
            text = "use_frameworks! :linkage => :" + mode + "\n" + text
        elif mode == "modular-library":
            text = "use_modular_headers!\n" + text
        podfile.write_text(text)
        graph = read_project(selected)
        for obj in graph["objects"].values():
            if obj.get("isa") == "XCBuildConfiguration":
                obj["buildSettings"]["CLANG_ENABLE_MODULES"] = "YES"
            if obj.get("isa") == "PBXFileReference" and obj.get("path") == "Sources/main.mm":
                obj["path"] = "Sources/main.m"
                obj["lastKnownFileType"] = "sourcecode.c.objc"
        write_project(selected, graph)
        old_main = selected.parent / "Sources/main.mm"
        main = old_main.with_suffix(".m")
        old_main.rename(main)
        main.write_text(
            ("@import Kit;\n" if mode != "library" else "")
            + "#include <Kit/Kit-umbrella.h>\n"
            + "#if KIT_PUBLIC_VALUE != 7\n#error Authored public umbrella was replaced\n#endif\n"
            + main.read_text()
        )
        fixture.cli(work, "install")
        project_before = (selected / "project.pbxproj").read_bytes()
        lock_before = (work / "Podfile.lock").read_bytes()
        fixture.cli(work, "install", "--offline", "--deployment")
        assert (selected / "project.pbxproj").read_bytes() == project_before
        assert (work / "Podfile.lock").read_bytes() == lock_before
        assert authored.read_bytes() == original
        fixture.build(work, "Demo", label + "-build")
        app = resources_in_app(fixture, label + "-build")
        assert "value=7" in subprocess.check_output(
            [str(app / "Contents/MacOS/Demo")], text=True
        )
        assert authored.read_bytes() == original
        fixture.verified.append("authored_public_umbrella_preserved_" + mode)


def header_collisions(fixture):
    for mode in ["library", "static", "dynamic"]:
        label = "header-case-collision-" + mode
        work, selected = create(fixture.root / label)
        library = work / "Kit"
        for folder, name, macro in [
            ("First", "Foo.h", "FIRST_HEADER"),
            ("Second", "foo.h", "SECOND_HEADER"),
        ]:
            directory = library / folder
            directory.mkdir()
            (directory / name).write_text("#pragma once\n#define " + macro + " 1\n")
        spec = library / "Kit.podspec.json"
        data = json.loads(spec.read_text())
        data["source_files"] = "**/*.{c,h}"
        spec.write_text(json.dumps(data))
        if mode != "library":
            podfile = work / "Podfile"
            podfile.write_text("use_frameworks! :linkage => :" + mode + "\n" + podfile.read_text())
        project_before = (selected / "project.pbxproj").read_bytes()
        rejected = fixture.cli(work, "install", succeeds=False)
        assert any(event.get("code") == "SP-SPEC-HEADER-COLLISION" for event in rejected["events"])
        assert (selected / "project.pbxproj").read_bytes() == project_before
        assert not (work / "Podfile.lock").exists()
        if rejected.get("project_state") == "recovery_required":
            fixture.cli(work, "recover")
        (library / "Second/foo.h").rename(library / "Second/Bar.h")
        main = selected.parent / "Sources/main.mm"
        main.write_text(
            "#include <Kit/Foo.h>\n#include <Kit/Bar.h>\n"
            "#if FIRST_HEADER != 1 || SECOND_HEADER != 1\n#error Header lost\n#endif\n"
            + main.read_text()
        )
        fixture.cli(work, "install")
        fixture.build(work, "Demo", label + "-control-build")
        fixture.verified.append("header_collision_rejected_and_distinct_headers_build_" + mode)


def quoted_header_namespace(fixture):
    work, _ = create(fixture.root / "quoted-header-namespace")
    spec = work / "Kit/Kit.podspec.json"
    data = json.loads(spec.read_text())
    data["header_dir"] = 'Quoted">Headers'
    spec.write_text(json.dumps(data))
    podfile = work / "Podfile"
    podfile.write_text("use_modular_headers!\n" + podfile.read_text())
    fixture.cli(work, "install")
    modulemap = next((work / "Pods/Headers/Public").rglob("module.modulemap"))
    module = re.search(r"module\s+(\w+)", modulemap.read_text()).group(1)
    source = work / "use.m"
    source.write_text("@import " + module + ";\nint use(void) { return kit_value(); }\n")
    sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
    log = fixture.root / "quoted-header-namespace.log"
    status = run_logged(
        [
            "xcrun", "clang", "-fsyntax-only", "-fmodules", "-Werror", "-isysroot", sdk,
            "-fmodule-map-file=" + str(modulemap),
            "-fmodules-cache-path=" + str(work / "module-cache"), source,
        ],
        work, log,
    )
    assert status == 0, log
    fixture.verified.append("quoted_header_namespace_keeps_valid_relative_includes")
