"""Workspace ownership, resource product identity and mapped private headers."""

import copy
import hashlib
import json
import platform
import subprocess
from xml.etree import ElementTree as ET

from Tests.Fixtures.vendor_fixture import fixture_build_arguments
from Tests.Fixtures.vendor_fixture import run as run_command
from Tests.Integration.native_integration import project, serialize
from Tests.Integration.native_xcconfig_tests import create


def read_project(path):
    return json.loads(
        subprocess.check_output(
            ["plutil", "-convert", "json", "-o", "-", str(path / "project.pbxproj")]
        )
    )


def add_consumer(selected):
    """Clone the fixture app with its own configuration, phases and build files."""
    graph = read_project(selected)
    objects = graph["objects"]
    root = objects[graph["rootObject"]]
    first = next(o for o in objects.values() if o.get("isa") == "PBXNativeTarget")

    def clone(old):
        new = (
            hashlib.sha256(("other-consumer:" + old).encode()).hexdigest()[:24].upper()
        )
        assert new not in objects
        objects[new] = copy.deepcopy(objects[old])
        return new

    second_id = hashlib.sha256(b"other-consumer").hexdigest()[:24].upper()
    second = copy.deepcopy(first)
    objects[second_id] = second
    root["targets"].append(second_id)
    second.update(name="Other", productName="Other")
    second["productReference"] = clone(first["productReference"])
    objects[second["productReference"]]["path"] = "Other.app"
    objects[root["productRefGroup"]]["children"].append(second["productReference"])
    second["buildConfigurationList"] = clone(first["buildConfigurationList"])
    configs = []
    for old in objects[first["buildConfigurationList"]]["buildConfigurations"]:
        new = clone(old)
        objects[new]["buildSettings"].update(
            PRODUCT_NAME="Other", SDKROOT="macosx", MACOSX_DEPLOYMENT_TARGET="13.0"
        )
        objects[new].pop("baseConfigurationReference", None)
        configs.append(new)
    objects[second["buildConfigurationList"]]["buildConfigurations"] = configs
    phases = []
    for old in first["buildPhases"]:
        new = clone(old)
        objects[new]["files"] = [
            clone(build) for build in objects[old].get("files", [])
        ]
        phases.append(new)
    second["buildPhases"] = phases
    (selected / "project.pbxproj").write_text("// !$*UTF8*$!\n" + serialize(graph))


def workspace_ownership(fixture):
    work, _ = create(fixture.root / "workspace-ownership")
    fixture.cli(work, "install")
    path = next(work.glob("*.xcworkspace")) / "contents.xcworkspacedata"
    root = ET.parse(path).getroot()
    managed = next(
        element.attrib["location"]
        for element in root.findall("FileRef")
        if "Pods.xcodeproj" in element.attrib["location"]
    )
    group = ET.SubElement(root, "Group", location="group:Sub", name="User projects")
    for location in [managed, "group:Unrelated.xcodeproj"]:
        ET.SubElement(group, "FileRef", location=location)
    (work / "Sub/Pods").mkdir(parents=True)
    project(work / "Sub/Pods/Pods.xcodeproj")
    project(work / "Sub/Unrelated.xcodeproj")
    path.write_text(ET.tostring(root, encoding="unicode"))
    user_project = work / "Sub/Pods/Pods.xcodeproj/project.pbxproj"
    original = user_project.read_bytes()
    fixture.cli(work, "install")
    assert len(ET.parse(path).getroot().findall("Group/FileRef")) == 2
    fixture.cli(work, "deintegrate")
    root = ET.parse(path).getroot()
    assert [e.attrib["location"] for e in root.findall("Group/FileRef")] == [
        managed,
        "group:Unrelated.xcodeproj",
    ]
    assert not any(e.attrib["location"] == managed for e in root.findall("FileRef"))
    assert user_project.read_bytes() == original
    fixture.cli(work, "install")
    assert any(
        e.attrib["location"] == managed
        for e in ET.parse(path).getroot().findall("FileRef")
    )
    assert user_project.read_bytes() == original
    fixture.verified.append("nested_workspace_ownership_survives_reinstall_deintegrate")


def workspace_whitespace(fixture):
    for label, whitespace in [("tab", "\t"), ("lf", "\n"), ("cr", "\r")]:
        work, selected = create(fixture.root / ("workspace-whitespace-" + label))
        renamed_parent = selected.parent.with_name("Apps" + whitespace + "Folder")
        selected.parent.rename(renamed_parent)
        renamed = renamed_parent / selected.name
        podfile = work / "Podfile"
        podfile.write_text(
            "workspace 'Demo'\n"
            + podfile.read_text().replace(
                "'../Apps/External.xcodeproj'",
                json.dumps("../" + renamed_parent.name + "/" + renamed.name),
            )
        )
        path = work / "Demo.xcworkspace/contents.xcworkspacedata"
        path.parent.mkdir()
        reference = "absolute:" + str(renamed)
        root = ET.Element("Workspace", version="1.0")
        ET.SubElement(root, "FileRef", location=reference)
        path.write_bytes(ET.tostring(root))
        for stage in ["before", "install", "reinstall", "deintegrate"]:
            if stage != "before":
                fixture.cli(
                    work, "deintegrate" if stage == "deintegrate" else "install"
                )
            locations = [
                e.attrib["location"] for e in ET.parse(path).getroot().iter("FileRef")
            ]
            expected = [reference] + (
                ["group:Pods/Pods.xcodeproj"]
                if stage in ["install", "reinstall"]
                else []
            )
            assert locations == expected, (label, stage, locations)
            output = run_command(
                ["xcodebuild", "-workspace", path.parent, "-list", "-json"],
                work,
                fixture.root / ("workspace-" + label + "-" + stage + "-list.log"),
                env=fixture.env,
            )
            assert "Demo" in json.loads(output)["workspace"]["schemes"], (
                label,
                stage,
                output,
            )
            if label == "tab" and stage == "install":
                for configuration in ["Debug", "Release"]:
                    build_root = fixture.root / ("workspace-tab-" + configuration)
                    build_root.mkdir()
                    run_command(
                        [
                            "xcodebuild",
                            "-workspace",
                            path.parent,
                            "-scheme",
                            "Demo",
                            "-configuration",
                            configuration,
                            "-destination",
                            "platform=macOS,arch=" + platform.machine(),
                            *fixture_build_arguments(build_root),
                            "CODE_SIGNING_ALLOWED=NO",
                            "build",
                        ],
                        work,
                        fixture.root
                        / ("workspace-tab-" + configuration + "-build.log"),
                        env=fixture.env,
                    )
        fixture.verified.append(
            "workspace_"
            + label
            + "_user_path_survives_install_reinstall_deintegrate_and_xcode_list"
        )
    fixture.verified.append("workspace_tab_project_builds_debug_and_release")


def resource_bundles(fixture):
    for mode in ["library", "static", "dynamic"]:
        work, selected = create(fixture.root / ("bundle-identity-" + mode))
        add_consumer(selected)
        (selected.parent / "Sources/main.mm").write_text(
            "int main(void) { return 0; }\n"
        )
        for name in ["KitA", "KitB"]:
            library = work / name
            library.mkdir()
            (library / "Value.c").write_text("void " + name.lower() + "(void) {}\n")
            (library / (name + ".txt")).write_text(name + " marker\n")
            (library / (name + ".podspec.json")).write_text(
                json.dumps(
                    {
                        "name": name,
                        "version": "1.0",
                        "platforms": {"osx": "13.0"},
                        "source_files": "*.c",
                        "resource_bundles": {"Shared": "*.txt"},
                    }
                )
            )
        body = "platform :osx, '13.0'\nproject '../Apps/External.xcodeproj'\n"
        if mode != "library":
            body += "use_frameworks! :linkage => :" + mode + "\n"
        for target, name in [("Demo", "KitA"), ("Other", "KitB")]:
            body += (
                "target '"
                + target
                + "' do\n pod '"
                + name
                + "', :path => './"
                + name
                + "'\nend\n"
            )
        (work / "Podfile").write_text(body)
        fixture.cli(work, "install")
        fixture.cli(work, "install")
        objects = read_project(work / "Pods/Pods.xcodeproj")["objects"]
        bundles = [
            o
            for o in objects.values()
            if o.get("productType") == "com.apple.product-type.bundle"
        ]
        assert {o["name"] for o in bundles} == {"KitA-Shared", "KitB-Shared"}, bundles
        assert len({o["productReference"] for o in bundles}) == 2
        for target, name, other in [
            ("Demo", "KitA", "KitB"),
            ("Other", "KitB", "KitA"),
        ]:
            label = "bundle-" + mode + "-" + target
            fixture.build(work, target, label)
            app = (
                fixture.root
                / label
                / "DerivedData/Build/Products/Debug"
                / (target + ".app")
            )
            markers = list(app.rglob(name + ".txt"))
            assert len(markers) == 1 and markers[0].read_text() == name + " marker\n", (
                markers
            )
            assert not list(app.rglob(other + ".txt")), app
        fixture.cli(work, "deintegrate")
        user_objects = read_project(selected)["objects"]
        assert not any(
            o.get("name") == "[SwiftPods] Copy Resource Bundles"
            for o in user_objects.values()
        )
        assert all(
            o["fileRef"] in user_objects
            for o in user_objects.values()
            if "fileRef" in o
        )
        assert (work / "KitA/KitA.txt").read_text() == "KitA marker\n"
        assert (work / "KitB/KitB.txt").read_text() == "KitB marker\n"
        fixture.verified.append("same_named_bundles_keep_owner_and_payload_" + mode)


def mapped_headers(fixture):
    work, selected = create(fixture.root / "mapped-private-headers")
    library = work / "Kit"
    (library / "Headers/Public").mkdir(parents=True)
    (library / "Headers/Private").mkdir()
    (library / "Kit.h").rename(library / "Headers/Public/Kit.h")
    (library / "Headers/Private/Inner.h").write_text("#define KIT_PRIVATE_VALUE 7\n")
    (library / "Kit.c").write_text(
        "#include <Kit/Private/Inner.h>\nint kit_value(void) { return KIT_PRIVATE_VALUE; }\n"
    )
    spec = library / "Kit.podspec.json"
    data = json.loads(spec.read_text())
    data.update(
        source_files=["*.c", "Headers/**/*.h"],
        public_header_files="Headers/Public/*.h",
        private_header_files="Headers/Private/*.h",
        header_mappings_dir="Headers",
    )
    spec.write_text(json.dumps(data))
    main = selected.parent / "Sources/main.mm"
    main.write_text(main.read_text().replace("<Kit/Kit.h>", "<Kit/Public/Kit.h>"))
    (work / "Podfile").write_text(
        "use_frameworks! :linkage => :static\n" + (work / "Podfile").read_text()
    )
    fixture.cli(work, "install")
    fixture.cli(work, "install", "--deployment")
    label = "mapped-private-headers-build"
    fixture.build(work, "Demo", label)
    framework = fixture.root / label / "DerivedData/Build/Products/Debug/Kit.framework"
    assert (
        framework / "PrivateHeaders/Private/Inner.h"
    ).read_text() == "#define KIT_PRIVATE_VALUE 7\n"
    assert (framework / "Headers/Public/Kit.h").exists()
    assert not (framework / "Headers/Private/Inner.h").exists()
    fixture.verified.append(
        "framework_private_header_mapping_builds_without_public_promotion"
    )


def subspec_lockfile_hook(fixture):
    work, _ = create(fixture.root / "subspec-lockfile-hook")
    spec = work / "Kit/Kit.podspec.json"
    data = json.loads(spec.read_text())
    data.update(source_files=[], subspecs=[{"name": "Core", "source_files": "*.{c,h}"}])
    spec.write_text(json.dumps(data))
    body = (work / "Podfile").read_text().replace("pod 'Kit',", "pod 'Kit/Core',")
    body += """pre_install do |installer|
  if File.file?('Podfile.lock')
    lock = Pod::Lockfile.from_file(Pathname('Podfile.lock'))
    File.write('lock-hook.json', JSON.generate({names: lock.pod_names, root: lock.version('Kit')&.to_s, subspec: lock.version('Kit/Core')&.to_s, absent: lock.version('Kit/Missing')}))
  end
end
"""
    (work / "Podfile").write_text(body)
    fixture.cli(work, "install")
    for args in [("install",), ("install", "--deployment")]:
        fixture.cli(work, *args)
        result = json.loads((work / "lock-hook.json").read_text())
        assert result == {
            "names": ["Kit/Core"],
            "root": "1.0",
            "subspec": "1.0",
            "absent": None,
        }, result
    fixture.verified.append("real_hook_root_version_lookup_for_subspec_lockfile")


def run(fixture):
    workspace_ownership(fixture)
    workspace_whitespace(fixture)
    resource_bundles(fixture)
    mapped_headers(fixture)
    subspec_lockfile_hook(fixture)
