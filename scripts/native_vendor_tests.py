#!/usr/bin/env python3
"""Build/run real vendored SDK consumers through the independent Swift engine."""

import json
import platform as host_platform
import plistlib
import shutil
import subprocess
import time
from pathlib import Path

from bootstrap import ROOT, environment
from local_build import debug_binary, fixture_directory, results_directory
from native_integration import project
from reporting import execute
from vendor_fixture import run, sdk


def fixture(base, products, platform, raw=False, transitive=False):
    work = base / ("consumer-" + platform)
    work.mkdir()
    work.joinpath("Sources").mkdir()
    module = work / "Modules/VendorAdapter"
    module.mkdir(parents=True)
    imports, checks, frameworks, libraries = [], [], [], []
    for name, product, library in products:
        if raw:
            # A separate raw macOS distribution exercises .framework and .a.
            metadata = plistlib.loads(product.joinpath("Info.plist").read_bytes())
            entry = next(
                item
                for item in metadata["AvailableLibraries"]
                if item["SupportedPlatform"] == "macos"
            )
            selected = product / entry["LibraryIdentifier"] / entry["LibraryPath"]
            destination = module / selected.name
            if library:
                shutil.copy2(selected, destination)
                shutil.copy2(
                    product
                    / entry["LibraryIdentifier"]
                    / entry["HeadersPath"]
                    / (name + ".h"),
                    module / (name + ".h"),
                )
            else:
                shutil.copytree(selected, destination, symlinks=True)
        else:
            destination = module / product.name
            shutil.copytree(product, destination, symlinks=True)
        (libraries if library else frameworks).append(destination.name)
        imports.append(
            "#import "
            + ('"' + name + '.h"' if library else "<" + name + "/" + name + ".h>")
        )
        checks.append(f"if ({name}_value() != {name}_EXPECTED) return -1;")
    module.joinpath("VendorAdapter.h").write_text(
        '#ifdef __cplusplus\nextern "C" {\n#endif\nint vendor_adapter_value(void);\n#ifdef __cplusplus\n}\n#endif\n'
    )
    module.joinpath("VendorAdapter.m").write_text(
        "\n".join(
            [
                '#import "VendorAdapter.h"',
                *imports,
                "int vendor_adapter_value(void) {",
                *checks,
                "return "
                + " + ".join(name + "_value()" for name, _, _ in products)
                + ";",
                "}",
            ]
        )
        + "\n"
    )
    # An explicit user search path is needed for this private fixture header.
    module.joinpath("CustomHeaders").mkdir()
    module.joinpath("CustomHeaders/UserHeader.h").write_text(
        "#define USER_HEADER_PRESERVED 1\n"
    )
    with module.joinpath("VendorAdapter.m").open("a") as output:
        output.write(
            '#include "UserHeader.h"\n_Static_assert(USER_HEADER_PRESERVED == 1, "pod xcconfig search path lost");\n'
        )
    spec = {
        "name": "VendorAdapter",
        "version": "1.0",
        "platforms": {platform: "13.0" if platform == "osx" else "15.0"},
        "source_files": "VendorAdapter.{h,m}",
        "vendored_frameworks": frameworks,
        "vendored_libraries": libraries,
        "pod_target_xcconfig": {
            "HEADER_SEARCH_PATHS": ["$(inherited)", str(module / "CustomHeaders")]
        },
    }
    source = ""
    if transitive:
        binary_source = base / "BinarySDKSource"
        binary_source.mkdir()
        for item in frameworks + libraries:
            shutil.move(module / item, binary_source / item)
        run(["git", "init", "-b", "main", binary_source], base, base / "git-init.log")
        run(["git", "-C", binary_source, "add", "."], base, base / "git-add.log")
        run(
            [
                "git",
                "-C",
                binary_source,
                "-c",
                "user.name=SwiftPods Fixture",
                "-c",
                "user.email=fixture@swiftpods.org",
                "-c",
                "commit.gpgsign=false",
                "commit",
                "-m",
                "SDK fixture",
            ],
            base,
            base / "git-commit.log",
        )
        commit = subprocess.check_output(
            ["git", "-C", str(binary_source), "rev-parse", "HEAD"], text=True
        ).strip()
        catalog = work / "Specs/BinarySDK/1.0"
        catalog.mkdir(parents=True)
        catalog.joinpath("BinarySDK.podspec.json").write_text(
            json.dumps(
                {
                    "name": "BinarySDK",
                    "version": "1.0",
                    "vendored_frameworks": frameworks,
                    "vendored_libraries": libraries,
                    "source": {"git": str(binary_source), "commit": commit},
                }
            )
        )
        spec.pop("vendored_frameworks")
        spec.pop("vendored_libraries")
        spec["dependencies"] = {"BinarySDK": []}
        source = "source './Specs'\n"
    module.joinpath("VendorAdapter.podspec.json").write_text(json.dumps(spec))
    work.joinpath("Podfile").write_text(
        source
        + f"platform :{platform}, '{'13.0' if platform == 'osx' else '15.0'}'\nproject 'Demo.xcodeproj'\ntarget 'Demo' do\n  pod 'VendorAdapter', :path => './Modules/VendorAdapter'\nend\n"
    )
    if platform == "osx":
        work.joinpath("Sources/main.mm").write_text(
            '#include <stdio.h>\nextern "C" {\n#include <VendorAdapter/VendorAdapter.h>\n}\nint main(void) { printf("vendor=%d\\n", vendor_adapter_value()); return 0; }\n'
        )
    else:
        source = (ROOT / "Tests/Fixtures/iOS/main.mm").read_text()
        start = source.index("    int value =")
        end = source.index("\n}", start)
        source = (
            source[:start]
            + '    return @{@"vendor": @(vendor_adapter_value())};'
            + source[end:]
        )
        source = source.replace(
            "#import <GameCore/GameCore.h>", "#define SWIFTPODS_VENDOR_FIXTURE 1"
        )
        work.joinpath("Sources/main.mm").write_text(source)
        shutil.copy2(
            ROOT / "Tests/Fixtures/iOS/FixtureIntent.swift",
            work / "Sources/FixtureIntent.swift",
        )
        work.joinpath("Info.plist").write_bytes(
            plistlib.dumps(
                {
                    "CFBundleExecutable": "$(EXECUTABLE_NAME)",
                    "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)",
                    "CFBundleName": "Demo",
                    "CFBundlePackageType": "APPL",
                    "CFBundleVersion": "1",
                    "CFBundleShortVersionString": "1.0",
                    "UILaunchScreen": {},
                    "UISupportedInterfaceOrientations": [
                        "UIInterfaceOrientationPortrait",
                        "UIInterfaceOrientationPortraitUpsideDown",
                        "UIInterfaceOrientationLandscapeLeft",
                        "UIInterfaceOrientationLandscapeRight",
                    ],
                    "UIApplicationSceneManifest": {
                        "UIApplicationSupportsMultipleScenes": False,
                        "UISceneConfigurations": {},
                    },
                }
            )
        )
    project(work / "Demo.xcodeproj", platform)
    return work


def install(work, env, log):
    result = subprocess.run(
        [str(debug_binary()), "install", "--json"],
        cwd=work,
        env=env,
        capture_output=True,
        text=True,
        timeout=90,
    )
    log.write_text(result.stderr + result.stdout)
    assert result.returncode == 0, "Install failed: " + str(log)
    assert json.loads(result.stdout)["exit_status"] == 0


def build(work, base, destination, label):
    derived = base / ("DerivedData-" + label)
    text = run(
        [
            "xcodebuild",
            "-workspace",
            "Demo.xcworkspace",
            "-scheme",
            "Demo",
            "-configuration",
            "Debug",
            "-destination",
            destination,
            "-derivedDataPath",
            derived,
            "CODE_SIGNING_ALLOWED=NO",
            "build",
        ],
        work,
        base / (label + "-build.log"),
    )
    assert "** BUILD SUCCEEDED **" in text
    return derived


def embedded(app, platform):
    directory = app / ("Contents/Frameworks" if platform == "osx" else "Frameworks")
    return (
        sorted(item.name for item in directory.iterdir()) if directory.exists() else []
    )


def simulator_run(base, app, expected):
    # Own a disposable simulator; never boot/erase/shutdown the user's device.
    runtimes = json.loads(
        subprocess.check_output(["xcrun", "simctl", "list", "runtimes", "-j"])
    )["runtimes"]
    runtime = max(
        (
            item
            for item in runtimes
            if item.get("isAvailable")
            and item["identifier"].startswith("com.apple.CoreSimulator.SimRuntime.iOS-")
            and host_platform.machine()
            in item.get("supportedArchitectures", [host_platform.machine()])
        ),
        key=lambda item: tuple(map(int, item["version"].split("."))),
    )
    device_type = next(
        item["identifier"]
        for item in runtime["supportedDeviceTypes"]
        if item["productFamily"] == "iPhone"
    )
    device = subprocess.check_output(
        [
            "xcrun",
            "simctl",
            "create",
            "SwiftPods Vendor Fixture",
            device_type,
            runtime["identifier"],
        ],
        text=True,
    ).strip()
    try:
        run(["xcrun", "simctl", "boot", device], base, base / "simulator-boot.log")
        run(
            ["xcrun", "simctl", "bootstatus", device, "-b"],
            base,
            base / "simulator-ready.log",
        )
        run(
            ["xcrun", "simctl", "install", device, app],
            base,
            base / "simulator-install.log",
        )
        run(
            ["xcrun", "simctl", "launch", device, "org.swiftpods.fixture"],
            base,
            base / "simulator-launch.log",
        )
        container = Path(
            subprocess.check_output(
                [
                    "xcrun",
                    "simctl",
                    "get_app_container",
                    device,
                    "org.swiftpods.fixture",
                    "data",
                ],
                text=True,
            ).strip()
        )
        validation = container / "Documents/validation.json"
        for _ in range(100):
            if validation.exists():
                break
            time.sleep(0.1)
        assert validation.exists(), (
            "Simulator application did not produce validation.json"
        )
        result = json.loads(validation.read_text())
        assert result == {"vendor": expected}, result
        base.joinpath("simulator-validation.json").write_text(json.dumps(result) + "\n")
    finally:
        subprocess.run(["xcrun", "simctl", "shutdown", device], capture_output=True)
        subprocess.run(
            ["xcrun", "simctl", "delete", device], check=True, capture_output=True
        )


def objc_archive_regression(base, env):
    producer = base / "objc-sdk"
    producer.mkdir()
    declaration = (
        "#import <Foundation/Foundation.h>\n"
        "@interface SwiftPodsVendorObject : NSObject\n+ (int)value;\n@end\n"
    )
    source = producer / "Vendor.m"
    source.write_text(
        declaration
        + "@implementation SwiftPodsVendorObject\n+ (int)value { return 42; }\n@end\n"
    )
    run(
        [
            "xcrun",
            "clang",
            "-target",
            host_platform.machine() + "-apple-macos13.0",
            "-Wall",
            "-Wextra",
            "-Werror",
            "-c",
            source,
            "-o",
            producer / "Vendor.o",
        ],
        producer,
        producer / "compile.log",
        env,
    )
    run(
        [
            "xcrun",
            "libtool",
            "-static",
            "-o",
            producer / "libVendor.a",
            producer / "Vendor.o",
        ],
        producer,
        producer / "archive.log",
        env,
    )
    (producer / "BinaryPod.podspec.json").write_text(
        json.dumps(
            {
                "name": "BinaryPod",
                "version": "1.0",
                "platforms": {"osx": "13.0"},
                "vendored_libraries": "libVendor.a",
                "frameworks": "Foundation",
                "weak_frameworks": "StoreKit",
            }
        )
    )
    scenarios = []
    for linkage in ("library", "static"):
        work = base / ("objc-" + linkage)
        work.mkdir()
        (work / "Sources").mkdir()
        (work / "Sources/main.mm").write_text(
            declaration
            + "int main(void) { return [SwiftPodsVendorObject value] == 42 ? 0 : 1; }\n"
        )
        (work / "Podfile").write_text(
            "platform :osx, '13.0'\n"
            + ("use_frameworks! :linkage => :static\n" if linkage == "static" else "")
            + "project 'Demo.xcodeproj'\ntarget 'Demo' do\n"
            + "  pod 'BinaryPod', :path => '../objc-sdk'\nend\n"
        )
        project(work / "Demo.xcodeproj")
        install(work, env, work / "install.log")
        derived = build(
            work, work, "platform=macOS,arch=" + host_platform.machine(), "objc"
        )
        products = derived / "Build/Products/Debug"
        archive = run(
            ["xcrun", "nm", "-gU", products / "libBinaryPod.a"],
            work,
            work / "archive-symbols.log",
            env,
        )
        assert "_OBJC_CLASS_$_SwiftPodsVendorObject" not in archive
        app = products / "Demo.app/Contents/MacOS/Demo"
        symbols = run(["xcrun", "nm", "-gU", app], work, work / "app-symbols.log", env)
        assert (
            sum(
                line.endswith(" _OBJC_CLASS_$_SwiftPodsVendorObject")
                for line in symbols.splitlines()
            )
            == 1
        )
        run([app], work, work / "run.log", env)
        scenarios.append(
            {
                "platform": "macos",
                "format": "Objective-C archive",
                "pod_linkage": linkage,
            }
        )
    return scenarios


def main():
    base = fixture_directory("native-vendor-")
    print("Vendor fixtures:", base, flush=True)
    products = [
        ("VendorStatic", sdk(base, "VendorStatic"), False),
        ("VendorDynamic", sdk(base, "VendorDynamic", dynamic=True), False),
        ("VendorLibrary", sdk(base, "VendorLibrary", library=True), True),
    ]
    env = environment()
    env["GEM_HOME"] = str(base / "no-global-gems")
    env["GEM_PATH"] = env["GEM_HOME"]
    env["SWIFTPODS_CACHE_ROOT"] = str(base / "cache")
    scenarios = objc_archive_regression(base, env)
    mac_destination = "platform=macOS,arch=" + host_platform.machine()
    for raw in (False, True):
        group = base / ("raw" if raw else "xcframework")
        group.mkdir()
        work = fixture(group, products, "osx", raw)
        install(work, env, group / "install.log")
        derived = build(work, group, mac_destination, "macos")
        app = derived / "Build/Products/Debug/Demo.app"
        output = subprocess.check_output([str(app / "Contents/MacOS/Demo")], text=True)
        assert output.strip() == "vendor=126", output
        assert embedded(app, "osx") == ["VendorDynamic.framework"], embedded(app, "osx")
        lock = work.joinpath("Podfile.lock").read_bytes()
        run(
            [
                debug_binary(),
                "install",
                "--deployment",
                "--offline",
                "--json",
            ],
            work,
            group / "reinstall.log",
            env,
        )
        assert lock == work.joinpath("Podfile.lock").read_bytes()
        scenarios.append(
            {
                "platform": "macos",
                "format": "raw" if raw else "xcframework",
                "value": 126,
                "embedded": embedded(app, "osx"),
            }
        )
        if raw:
            # Removing an SDK must remove its link/embed references as well.
            module = work / "Modules/VendorAdapter"
            spec_path = module / "VendorAdapter.podspec.json"
            spec = json.loads(spec_path.read_text())
            spec["vendored_frameworks"].remove("VendorDynamic.framework")
            spec_path.write_text(json.dumps(spec))
            source_path = module / "VendorAdapter.m"
            source = source_path.read_text().replace(
                "#import <VendorDynamic/VendorDynamic.h>\n", ""
            )
            source = source.replace(
                "if (VendorDynamic_value() != VendorDynamic_EXPECTED) return -1;\n", ""
            )
            source_path.write_text(source.replace(" + VendorDynamic_value()", ""))
            shutil.rmtree(module / "VendorDynamic.framework")
            install(work, env, group / "remove-sdk.log")
            graph = json.loads(
                subprocess.check_output(
                    [
                        "plutil",
                        "-convert",
                        "json",
                        "-o",
                        "-",
                        str(work / "Demo.xcodeproj/project.pbxproj"),
                    ]
                )
            )
            assert not any(
                "VendorDynamic" in item.get("path", "")
                for item in graph["objects"].values()
                if item["isa"] == "PBXFileReference"
            )
            derived = build(work, group, mac_destination, "removed-sdk")
            app = derived / "Build/Products/Debug/Demo.app"
            assert (
                subprocess.check_output(
                    [str(app / "Contents/MacOS/Demo")], text=True
                ).strip()
                == "vendor=84"
            )
            assert embedded(app, "osx") == []
            project_before = work.joinpath(
                "Demo.xcodeproj/project.pbxproj"
            ).read_bytes()
            spec["vendored_frameworks"].append("Missing.framework")
            spec_path.write_text(json.dumps(spec))
            rejected = subprocess.run(
                [str(debug_binary()), "install", "--json"],
                cwd=work,
                env=env,
                capture_output=True,
                text=True,
                timeout=90,
            )
            assert rejected.returncode != 0
            assert any(
                event.get("code") == "SP-VENDOR-MISSING"
                for event in json.loads(rejected.stdout)["events"]
            )
            assert (
                project_before
                == work.joinpath("Demo.xcodeproj/project.pbxproj").read_bytes()
            )
            scenarios.append(
                {
                    "platform": "macos",
                    "format": "removed SDK",
                    "value": 84,
                    "embedded": [],
                }
            )
    for linkage in ("static", "dynamic"):
        group = base / ("wrapper-" + linkage)
        group.mkdir()
        work = fixture(group, products, "osx")
        podfile = work / "Podfile"
        podfile.write_text(
            "use_frameworks! :linkage => :" + linkage + "\n" + podfile.read_text()
        )
        install(work, env, group / "install.log")
        derived = build(work, group, mac_destination, "macos")
        app = derived / "Build/Products/Debug/Demo.app"
        assert (
            subprocess.check_output(
                [str(app / "Contents/MacOS/Demo")], text=True
            ).strip()
            == "vendor=126"
        )
        expected = (
            ["VendorAdapter.framework", "VendorDynamic.framework"]
            if linkage == "dynamic"
            else ["VendorDynamic.framework"]
        )
        assert embedded(app, "osx") == expected, embedded(app, "osx")
        scenarios.append(
            {
                "platform": "macos",
                "format": "xcframework",
                "pod_linkage": linkage + " framework",
                "value": 126,
                "embedded": expected,
            }
        )
    work = fixture(base, products, "ios", transitive=True)
    install(work, env, base / "ios-install.log")
    lock = work.joinpath("Podfile.lock").read_bytes()
    simulator = build(work, base, "generic/platform=iOS Simulator", "simulator")
    app = simulator / "Build/Products/Debug-iphonesimulator/Demo.app"
    assert embedded(app, "ios") == ["VendorDynamic.framework"], embedded(app, "ios")
    simulator_run(base, app, 606)
    device = build(work, base, "generic/platform=iOS", "device")
    device_app = device / "Build/Products/Debug-iphoneos/Demo.app"
    assert embedded(device_app, "ios") == ["VendorDynamic.framework"]
    assert lock == work.joinpath("Podfile.lock").read_bytes(), (
        "Build destination changed the installed lock"
    )
    scenarios += [
        {"platform": "ios-simulator", "value": 606, "execution": "passed"},
        {"platform": "ios-device", "execution": "unsigned build only"},
    ]
    report = {
        "status": "passed",
        "engine": "swift",
        "fixture": str(base),
        "scenarios": scenarios,
        "verified": [
            "static/dynamic vendored frameworks and static libraries",
            "native XCFramework destination selection with distinct binary/header payloads",
            "macOS build and run with static library/static framework/dynamic framework wrapper pods",
            "iOS simulator build and run",
            "iOS unsigned device build from same install",
            "transitive binary SDK pod from pinned Git source",
            "dynamic SDK embedding only",
            "SDK removal cleans link and embed references",
            "missing declared SDK rejected",
            "pod xcconfig search paths preserved",
            "offline deployment reinstall",
        ],
        "unverified": [
            "physical devices",
            "signing",
            "Intel execution",
            "all third-party SDKs",
        ],
    }
    results_directory().joinpath("native-vendor.json").write_text(
        json.dumps(report, indent=2) + "\n"
    )
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    execute(main, "native-vendor.json")
