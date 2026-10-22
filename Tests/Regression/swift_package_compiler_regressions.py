"""Build package compiler interfaces without absorbing SDK objects into archives."""

import json
import plistlib
import shutil

from Tests.Fixtures.swift_package_compiler_fixture import c_header, create
from Tests.Fixtures.vendor_fixture import (
    fixture_build_arguments,
    fixture_derived_data,
    sdk,
)
from Tests.Fixtures.vendor_fixture import run as command
from Tests.Regression.input_contract_regressions import commit, git
from Tests.Regression.lifecycle_audit_regressions import write_project
from Tests.Regression.workspace_resource_regressions import read_project


def installed_files(work, project):
    files = [project / "project.pbxproj", *work.glob("Pods/Target Support Files/**/*")]
    files += list(work.rglob("Package.resolved"))
    return {path: path.read_bytes() for path in files if path.is_file()}


def reinstall(fixture, work, project):
    before = installed_files(work, project)
    fixture.cli(work, "install", "--deployment", "--offline")
    assert installed_files(work, project) == before, work


def build(
    fixture, work, label, destination, architectures, product_subdirectory="Debug"
):
    parent = fixture.root / label
    parent.mkdir()
    command(
        [
            "xcodebuild",
            "-toolchain",
            "com.apple.dt.toolchain.XcodeDefault",
            "-workspace",
            work / "Demo.xcworkspace",
            "-scheme",
            "SDK Owner",
            "-configuration",
            "Debug",
            "-destination",
            destination,
            "-clonedSourcePackagesDirPath",
            fixture.root / "Xcode Packages Elsewhere",
            *fixture_build_arguments(parent),
            "ARCHS=" + " ".join(architectures),
            "ONLY_ACTIVE_ARCH=NO",
            "CODE_SIGNING_ALLOWED=NO",
            "build",
        ],
        work,
        fixture.root / (label + ".log"),
    )
    products = fixture_derived_data(parent) / "Build/Products" / product_subdirectory
    for name in ["Alpha", "Beta"]:
        archive = products / ("lib" + name + ".a")
        actual = command(
            ["xcrun", "lipo", "-archs", archive],
            work,
            fixture.root / (label + "-" + name + "-archs.log"),
        )
        assert set(actual.split()) == set(architectures), actual
        for arch in architectures:
            selected = archive
            if len(architectures) > 1:
                selected = parent / (name + "-" + arch + ".a")
                command(
                    ["xcrun", "lipo", "-thin", arch, archive, "-output", selected],
                    work,
                    fixture.root / (label + "-" + name + "-" + arch + "-thin.log"),
                )
            entries = command(
                ["ar", "-t", selected],
                work,
                fixture.root / (label + "-" + name + "-" + arch + "-archive.log"),
            )
            objects = [entry for entry in entries.splitlines() if entry.endswith(".o")]
            expected = {name + ".o"}
            if name == "Alpha":
                expected.add("AlphaSwift.o")
            assert objects and set(objects) == expected, entries
    graph = read_project(work / "Demo.xcodeproj")["objects"]
    for target in graph.values():
        if target.get("isa") == "PBXNativeTarget" and target.get("name") in [
            "Alpha",
            "Beta",
        ]:
            assert not target.get("packageProductDependencies"), target
            for phase in target["buildPhases"]:
                if graph[phase].get("isa") == "PBXFrameworksBuildPhase":
                    assert not graph[phase].get("files"), graph[phase]
    if destination.startswith("platform=macOS"):
        command(
            [products / "Demo.app/Contents/MacOS/Demo"],
            work,
            fixture.root / (label + "-run.log"),
        )


def source_and_cleanup(fixture):
    work, project, origin = create(fixture.root / "spm-compiler-source")
    fixture.cli(work, "install")
    reinstall(fixture, work, project)
    support = work / "Pods/Target Support Files/Pods-Alpha/Pods-Alpha.debug.xcconfig"
    text = support.read_text()
    assert "RemoteCore/include" in text and "Transitive/include" in text, text
    assert str(fixture.root) not in text, text
    maps = work / "Pods/Target Support Files/SwiftPods-SPM"
    old_maps = set(maps.glob("*.modulemap"))
    old_map_contents = {path: path.read_bytes() for path in old_maps}
    assert len(old_maps) == 2, old_maps
    assert all("umbrella" in path.read_text() for path in old_maps)
    build(
        fixture,
        work,
        "spm-source-universal",
        "platform=macOS,arch=arm64",
        ["arm64", "x86_64"],
    )

    # Changing selected products must invalidate the graph without replacing an identical checkout.
    podfile = work / "Podfile"
    original = podfile.read_text()
    podfile.write_text(original.replace("['SourceSDK']", "['SourceSDK', 'ExtraAPI']"))
    fixture.cli(work, "install")
    reinstall(fixture, work, project)
    assert "Unused/include" in support.read_text()
    assert set(maps.glob("*.modulemap")) > old_maps
    assert all(path.read_bytes() == data for path, data in old_map_contents.items())
    podfile.write_text(original)
    fixture.cli(work, "install")
    reinstall(fixture, work, project)
    assert support.read_text() == text
    assert set(maps.glob("*.modulemap")) == old_maps

    # A new revision removes a transitive target; exports and generated maps must follow it.
    path = origin / "Package.swift"
    path.write_text(path.read_text().replace("Transitive", "Replacement"))
    (origin / "Sources/Transitive").rename(origin / "Sources/Replacement")
    (origin / "Sources/Replacement/include/Transitive.h").rename(
        origin / "Sources/Replacement/include/Replacement.h"
    )
    for path in origin.glob("Sources/**/*.c"):
        path.write_text(path.read_text().replace('"Transitive.h"', '"Replacement.h"'))
    commit(origin, "Replace a transitive interface")
    git(origin, "tag", "2.0.0")
    podfile = work / "Podfile"
    podfile.write_text(podfile.read_text().replace("1.0.0", "2.0.0"))
    for path in (work / "Sources").glob("*.m*"):
        path.write_text(
            path.read_text()
            .replace("Transitive.h", "Replacement.h")
            .replace("@import Transitive;", "@import Replacement;")
        )
    swift = work / "Sources/AlphaSwift.swift"
    swift.write_text(
        swift.read_text().replace("import Transitive", "import Replacement")
    )
    fixture.cli(work, "install")
    reinstall(fixture, work, project)
    assert "Transitive/include" not in support.read_text()
    assert "Replacement/include" in support.read_text()
    assert len(old_maps.intersection(maps.glob("*.modulemap"))) == 1
    build(
        fixture,
        work,
        "spm-source-replaced",
        "platform=macOS,arch=arm64",
        ["arm64", "x86_64"],
    )

    graph = read_project(project)
    graph["objects"][graph["rootObject"]]["userMetadata"] = "keep this"
    for item in graph["objects"].values():
        if (
            item.get("isa") == "XCBuildConfiguration"
            and item["buildSettings"].get("PRODUCT_NAME") == "Alpha"
        ):
            item["buildSettings"]["OTHER_CFLAGS"].append("-DAFTER_INSTALL=1")
    write_project(project, graph)
    podfile.write_text(
        "\n".join(
            line for line in podfile.read_text().splitlines() if "spm 'SDK'" not in line
        )
        + "\n"
    )
    fixture.cli(work, "install")
    reinstall(fixture, work, project)
    final = read_project(project)
    assert final["objects"][final["rootObject"]]["userMetadata"] == "keep this"
    assert (
        not list(maps.glob("*.modulemap")) and not (maps / "module-maps.json").exists()
    )
    for item in final["objects"].values():
        assert item.get("isa") not in [
            "XCRemoteSwiftPackageReference",
            "XCSwiftPackageProductDependency",
        ], item
        assert not (
            item.get("isa") == "PBXTargetDependency" and "productRef" in item
        ), item
        assert "SWIFTPODS_SPM_" not in json.dumps(item), item
        if (
            item.get("isa") == "XCBuildConfiguration"
            and item["buildSettings"].get("PRODUCT_NAME") == "Alpha"
        ):
            assert item["buildSettings"]["OTHER_CFLAGS"] == [
                "$(inherited)",
                "-DFIXTURE_COMPILER_FLAG=1",
                "-DAFTER_INSTALL=1",
            ]
    assert all(
        "SWIFTPODS_SPM_" not in path.read_text()
        for path in work.glob("Pods/**/*.xcconfig")
    )
    fixture.verified += [
        "two_static_spm_consumers_import_public_headers_custom_and_generated_modules_and_share_one_sdk_under_all_load",
        "swift_static_consumer_imports_clang_and_swift_sdk_modules_and_keeps_user_swift_flags",
        "universal_static_archives_contain_only_consumer_objects",
        "cross_package_transitive_products_with_platform_conditions_are_exported",
        "product_selection_changes_refresh_exports_without_changing_identical_checkout_paths",
        "offline_reinstall_preserves_project_support_files_and_pins_byte_for_byte",
        "package_replacement_and_removal_clean_compile_settings_maps_and_dependencies_and_preserve_user_edits",
    ]


def binary_destinations(fixture):
    work, project, origin = create(fixture.root / "spm-compiler-binary")
    binary = sdk(
        fixture.root,
        "PlatformKit",
        platforms=("iphoneos", "iphonesimulator", "maccatalyst"),
    )
    for header in binary.rglob("*.h"):
        header.write_text(c_header(header.read_text()))
    metadata = plistlib.loads((binary / "Info.plist").read_bytes())
    for library in metadata["AvailableLibraries"]:
        if library.get("SupportedPlatformVariant") != "maccatalyst":
            continue
        framework = binary / library["LibraryIdentifier"] / library["LibraryPath"]
        version = framework / "Versions/A"
        (version / "Resources").mkdir(parents=True)
        for name in ["PlatformKit", "Headers", "Modules"]:
            (framework / name).rename(version / name)
            (framework / name).symlink_to("Versions/Current/" + name)
        (framework / "Info.plist").rename(version / "Resources/Info.plist")
        (framework / "Versions/Current").symlink_to("A")
        (framework / "Resources").symlink_to("Versions/Current/Resources")
    shutil.move(str(binary), origin / "PlatformKit.xcframework")
    manifest = origin / "Package.swift"
    manifest.write_text(
        manifest.read_text()
        .replace(
            "targets: [\n",
            'targets: [\n        .binaryTarget(name: "PlatformKit", path: "PlatformKit.xcframework"),\n',
            1,
        )
        .replace(
            'dependencies: ["Transitive",',
            'dependencies: ["Transitive", .target(name: "PlatformKit", condition: .when(platforms: [.iOS, .macCatalyst])),',
        )
    )
    commit(origin, "Binary package dependency")
    git(origin, "tag", "1.1.0")
    podfile = work / "Podfile"
    podfile.write_text(
        podfile.read_text()
        .replace("1.0.0", "1.1.0")
        .replace("platform :osx, '13.0'", "platform :ios, '15.4'")
    )
    graph = read_project(project)
    for item in graph["objects"].values():
        if item.get("isa") == "XCBuildConfiguration" and item["buildSettings"].get(
            "PRODUCT_NAME"
        ):
            item["buildSettings"].pop("MACOSX_DEPLOYMENT_TARGET", None)
            item["buildSettings"].update(
                SDKROOT="iphoneos",
                IPHONEOS_DEPLOYMENT_TARGET="15.4",
                TARGETED_DEVICE_FAMILY="1,2",
            )
            if item["buildSettings"]["PRODUCT_NAME"] == "Demo":
                item["buildSettings"].update(
                    INFOPLIST_KEY_UILaunchScreen_Generation="YES",
                    INFOPLIST_KEY_UISupportedInterfaceOrientations="UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight",
                )
    write_project(project, graph)
    for item in graph["objects"].values():
        if item.get("isa") == "XCBuildConfiguration" and item["buildSettings"].get(
            "PRODUCT_NAME"
        ):
            item["buildSettings"].update(
                SUPPORTS_MACCATALYST="YES",
                SUPPORTED_PLATFORMS="iphoneos iphonesimulator macosx",
            )
    write_project(project, graph)
    for name in ["Alpha", "Beta"]:
        source = work / "Sources" / (name + (".m" if name == "Alpha" else ".mm"))
        source.write_text(
            """#include <TargetConditionals.h>
#import <PlatformKit/PlatformKit.h>
@import PlatformKit;
#ifdef __cplusplus
#define FIXTURE_ASSERT static_assert
#else
#define FIXTURE_ASSERT _Static_assert
#endif
#if TARGET_OS_MACCATALYST
FIXTURE_ASSERT(PlatformKit_EXPECTED == 601, "wrong Catalyst headers");
#elif TARGET_OS_SIMULATOR
FIXTURE_ASSERT(PlatformKit_EXPECTED == 202, "wrong simulator headers");
#else
FIXTURE_ASSERT(PlatformKit_EXPECTED == 101, "wrong device headers");
#endif
"""
            + source.read_text().replace(
                "return sdk_value() + transitive_value() + (int)[BridgeValue number];",
                "return sdk_value() + transitive_value() + (int)[BridgeValue number] + PlatformKit_value() - PlatformKit_EXPECTED;",
            )
        )
    fixture.cli(work, "install")
    reinstall(fixture, work, project)
    support = (
        work / "Pods/Target Support Files/Pods-Alpha/Pods-Alpha.debug.xcconfig"
    ).read_text()
    assert "RemoteCore/include" not in support, support
    for label, destination, architectures, products in [
        ("device", "generic/platform=iOS", ["arm64"], "Debug-iphoneos"),
        (
            "simulator",
            "generic/platform=iOS Simulator",
            ["arm64", "x86_64"],
            "Debug-iphonesimulator",
        ),
        (
            "catalyst",
            "platform=macOS,variant=Mac Catalyst,arch=arm64",
            ["arm64", "x86_64"],
            "Debug-maccatalyst",
        ),
    ]:
        build(
            fixture, work, "spm-binary-" + label, destination, architectures, products
        )

    before = installed_files(work, project)
    original = podfile.read_text()
    podfile.write_text(original.replace("1.1.0", "99.0.0"))
    failed = fixture.cli(work, "install", succeeds=False)
    assert any(event.get("code") == "SP-SPM-RESOLVE" for event in failed["events"]), (
        failed
    )
    fixture.cli(work, "recover")
    assert installed_files(work, project) == before
    podfile.write_text(original)
    reinstall(fixture, work, project)
    fixture.verified += [
        "transitive_binary_spm_framework_selects_device_and_simulator_headers_and_modules",
        "binary_sdk_objects_stay_out_of_static_consumer_archives_on_each_architecture",
        "failed_package_resolution_recovers_project_support_files_and_resolved_pins",
    ]


def run(fixture):
    source_and_cleanup(fixture)
    binary_destinations(fixture)
