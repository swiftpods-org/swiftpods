"""Build source filters and runtime dependencies for each Xcode destination."""

import json

from Tests.Fixtures.vendor_fixture import fixture_build_arguments, fixture_derived_data
from Tests.Fixtures.vendor_fixture import run as command
from Tests.Regression.consumer_build_regressions import update_spec
from Tests.Regression.lifecycle_audit_regressions import write_project
from Tests.Regression.linkage_safety_regressions import consumer, execute
from Tests.Regression.workspace_resource_regressions import read_project


def cxx_consumer(fixture, name, source_name="main.mm"):
    work, selected = consumer(fixture, name)
    (work / "Kit/Kit.c").unlink()
    (work / "Kit/Kit.cpp").write_text(
        '#include <string>\nextern "C" int kit_value(void) { '
        'std::string s("a string longer than the small string optimization"); return s.size()>20?7:1; }\n'
    )
    update_spec(work, source_files="*.{cpp,h}", libraries=["c++"])
    source = selected.parent / "Sources" / source_name
    if source_name != "main.mm":
        (source.parent / "main.mm").rename(source)
    source.write_text("int unused_cpp(void) { return 0; }\n")
    (source.parent / "main.m").write_text(
        "extern int kit_value(void);\nint main(void) { return kit_value()==7?0:1; }\n"
    )
    graph = read_project(selected)
    objects = graph["objects"]
    ref = next(
        key
        for key, obj in objects.items()
        if obj.get("isa") == "PBXFileReference"
        and obj.get("path", "").endswith("main.mm")
    )
    objects[ref]["path"] = "Sources/" + source_name
    main, build = "F000000000000000000000C1", "F000000000000000000000C2"
    objects[main] = {
        **objects[ref],
        "path": "Sources/main.m",
        "lastKnownFileType": "sourcecode.c.objc",
    }
    objects[build] = {"isa": "PBXBuildFile", "fileRef": main}
    for obj in list(objects.values()):
        if obj.get("isa") == "PBXGroup" and ref in obj.get("children", []):
            obj["children"].append(main)
        if obj.get("isa") == "PBXSourcesBuildPhase":
            obj["files"].append(build)
    return work, selected, graph, ref


def install(fixture, work):
    fixture.cli(work, "install")
    managed = [*work.glob("Pods/**/*.xcconfig"), *work.glob("Pods/**/*.pbxproj")]
    before = {path: path.read_bytes() for path in managed}
    fixture.cli(work, "install", "--deployment", "--offline")
    assert all(path.read_bytes() == data for path, data in before.items()), work


def universal_build(fixture, work, label):
    parent = fixture.root / label
    parent.mkdir()
    command(
        [
            "xcodebuild",
            "-workspace",
            next(work.glob("*.xcworkspace")),
            "-scheme",
            "Demo",
            "-configuration",
            "Debug",
            "-destination",
            "platform=macOS,arch=arm64",
            *fixture_build_arguments(parent),
            "ARCHS=arm64 x86_64",
            "ONLY_ACTIVE_ARCH=NO",
            "CODE_SIGNING_ALLOWED=NO",
            "build",
        ],
        work,
        fixture.root / (label + ".log"),
    )
    executable = (
        fixture_derived_data(parent)
        / "Build/Products/Debug/Demo.app/Contents/MacOS/Demo"
    )
    architectures = command(
        ["xcrun", "lipo", "-archs", executable],
        work,
        fixture.root / (label + "-architectures.log"),
    )
    assert set(architectures.split()) == {"arm64", "x86_64"}, architectures
    execute(fixture, work, label)


def platform_filters(fixture):
    for kind, filters, included in [
        ("platformFilter", "ios", False),
        ("platformFilters", ["ios"], False),
        ("platformFilters", ["macos"], True),
    ]:
        name = "source-platform-" + kind + ("-included" if included else "-excluded")
        work, selected, graph, reference = cxx_consumer(fixture, name)
        for obj in graph["objects"].values():
            if obj.get("isa") == "PBXBuildFile" and obj.get("fileRef") == reference:
                obj[kind] = filters
        write_project(selected, graph)
        install(fixture, work)
        support = work / "Pods/Target Support Files/Pods-Demo/Pods-Demo.debug.xcconfig"
        assert ("-lc++" in support.read_text()) != included
        label = name + "-build"
        fixture.build(work, "Demo", label)
        execute(fixture, work, label)
        fixture.verified.append("platform_filtered_source_links_and_runs_" + name)


def architecture_filters(fixture):
    for declared in ["target", "project", "xcconfig", "included"]:
        name = "architecture-filter-" + declared
        work, selected, graph, _ = cxx_consumer(fixture, name)
        objects = graph["objects"]
        if declared in ["target", "project"]:
            root = (
                graph["rootObject"]
                if declared == "project"
                else next(
                    key
                    for key, obj in objects.items()
                    if obj.get("isa") == "PBXNativeTarget" and obj.get("name") == "Demo"
                )
            )
            for config in objects[objects[root]["buildConfigurationList"]][
                "buildConfigurations"
            ]:
                objects[config]["buildSettings"][
                    "EXCLUDED_SOURCE_FILE_NAMES[arch=arm*]"
                ] = "main.mm"
        else:
            base = selected.parent / "Configs/Base.xcconfig"
            body = "EXCLUDED_SOURCE_FILE_NAMES[arch=arm*] = main.mm\n"
            if declared == "included":
                body = "EXCLUDED_SOURCE_FILE_NAMES = *.mm\nINCLUDED_SOURCE_FILE_NAMES[arch=x86_64*] = main.mm\n"
            base.write_text(base.read_text() + body)
        write_project(selected, graph)
        install(fixture, work)
        assert (
            "SWIFTPODS_LINKER_FLAGS"
            in (
                work / "Pods/Target Support Files/Pods-Demo/Pods-Demo.debug.xcconfig"
            ).read_text()
        )
        universal_build(fixture, work, name + "-build")
        fixture.verified.append(
            "universal_consumer_selects_runtime_per_architecture_" + declared
        )


def sdk_filters(fixture):
    work, selected, graph, reference = cxx_consumer(fixture, "ios-platform")
    update_spec(work, platforms={"ios": "15.4"})
    podfile = work / "Podfile"
    podfile.write_text(
        podfile.read_text().replace("platform :osx, '13.0'", "platform :ios, '15.4'")
    )
    (selected.parent / "Configs/Base.xcconfig").write_text(
        "SDKROOT = iphoneos\nIPHONEOS_DEPLOYMENT_TARGET = 15.4\n"
    )
    for item in graph["objects"].values():
        if item.get("isa") == "PBXBuildFile" and item.get("fileRef") == reference:
            item["platformFilter"] = "ios"
        if item.get("isa") == "XCBuildConfiguration":
            settings = item["buildSettings"]
            settings.pop("MACOSX_DEPLOYMENT_TARGET", None)
            if settings.get("PRODUCT_NAME"):
                settings.update(
                    SDKROOT="iphoneos",
                    IPHONEOS_DEPLOYMENT_TARGET="15.4",
                    SUPPORTS_MACCATALYST="YES",
                    TARGETED_DEVICE_FAMILY="1,2",
                    SUPPORTED_PLATFORMS="iphoneos iphonesimulator macosx",
                )
    write_project(selected, graph)
    install(fixture, work)
    for label, destination in [
        ("simulator", "generic/platform=iOS Simulator"),
        ("catalyst", "platform=macOS,variant=Mac Catalyst,arch=arm64"),
    ]:
        parent = fixture.root / ("ios-platform-" + label)
        parent.mkdir()
        command(
            [
                "xcodebuild",
                "-toolchain",
                "com.apple.dt.toolchain.XcodeDefault",
                "-workspace",
                next(work.glob("*.xcworkspace")),
                "-scheme",
                "Demo",
                "-configuration",
                "Debug",
                "-destination",
                destination,
                *fixture_build_arguments(parent),
                "CODE_SIGNING_ALLOWED=NO",
                "build",
            ],
            work,
            fixture.root / ("ios-platform-" + label + ".log"),
        )
        fixture.verified.append("source_platform_filter_selects_runtime_for_" + label)


def unicode_filters(fixture):
    for label, separator in [("nbsp", "\u00a0"), ("em-space", "\u2003")]:
        name = "unicode-exclusion-" + label
        source = "main" + separator + "optional.mm"
        work, selected, graph, _ = cxx_consumer(fixture, name, source)
        for obj in graph["objects"].values():
            if obj.get("isa") == "XCBuildConfiguration" and obj["buildSettings"].get(
                "PRODUCT_NAME"
            ):
                obj["buildSettings"]["EXCLUDED_SOURCE_FILE_NAMES"] = source
        write_project(selected, graph)
        install(fixture, work)
        assert (
            "-lc++"
            in (
                work / "Pods/Target Support Files/Pods-Demo/Pods-Demo.debug.xcconfig"
            ).read_text()
        )
        fixture.build(work, "Demo", name + "-build")
        execute(fixture, work, name + "-build")
        fixture.verified.append("unicode_source_exclusion_preserves_literal_" + label)


def pod_filters(fixture):
    for conditional in [False, True]:
        name = "pod-source-exclusion-" + ("conditional" if conditional else "plain")
        work, selected = consumer(fixture, name)
        producer = fixture.root / (name + "-producer")
        producer.mkdir()
        source = producer / "Vendor.cpp"
        source.write_text(
            '#include <string>\nextern "C" int vendor_value(void) { '
            'std::string s("a string longer than the small string optimization"); return s.size()>20?7:1; }\n'
        )
        archives = []
        for arch in ["arm64", "x86_64"]:
            obj, archive = producer / (arch + ".o"), producer / (arch + ".a")
            command(
                [
                    "xcrun",
                    "clang++",
                    "-Wall",
                    "-Wextra",
                    "-Werror",
                    "-mmacosx-version-min=13.0",
                    "-arch",
                    arch,
                    "-c",
                    source,
                    "-o",
                    obj,
                ],
                work,
                producer / (arch + "-compile.log"),
            )
            command(
                ["xcrun", "libtool", "-static", "-o", archive, obj],
                work,
                producer / (arch + "-archive.log"),
            )
            archives.append(archive)
        command(
            [
                "xcrun",
                "lipo",
                "-create",
                *archives,
                "-output",
                work / "Kit/libVendor.a",
            ],
            work,
            producer / "universal.log",
        )
        (work / "Kit/Kit.c").write_text(
            "extern int vendor_value(void);\nint kit_value(void) { return vendor_value(); }\n"
        )
        (work / "Kit/Unused.mm").write_text("int unused_cpp(void) { return 0; }\n")
        exclusion = "EXCLUDED_SOURCE_FILE_NAMES" + (
            "[arch=arm*]" if conditional else ""
        )
        update_spec(
            work,
            source_files=["Kit.c", "Kit.h", "Unused.mm"],
            libraries=["c++"],
            vendored_libraries="libVendor.a",
            pod_target_xcconfig={exclusion: "Unused.mm"},
        )
        if conditional:
            binary = work / "BinarySDK"
            binary.mkdir()
            (work / "Kit/libVendor.a").rename(binary / "libVendor.a")
            (binary / "BinarySDK.podspec.json").write_text(
                json.dumps(
                    {
                        "name": "BinarySDK",
                        "version": "1.0",
                        "platforms": {"osx": "13.0"},
                        "vendored_libraries": "libVendor.a",
                        "libraries": ["c++"],
                    }
                )
            )
            update_spec(work, vendored_libraries=[], dependencies={"BinarySDK": []})
            podfile = work / "Podfile"
            podfile.write_text(
                podfile.read_text().replace(
                    "end\n", " pod 'BinarySDK', :path => './BinarySDK'\nend\n"
                )
            )
        (work / "Podfile").write_text(
            "use_frameworks! :linkage => :dynamic\n" + (work / "Podfile").read_text()
        )
        (selected.parent / "Sources/main.mm").write_text(
            "#include <Kit/Kit.h>\nint main(void) { return kit_value()==7?0:1; }\n"
        )
        install(fixture, work)
        graph = read_project(work / "Pods/Pods.xcodeproj")
        for item in graph["objects"].values():
            if item.get("isa") == "XCBuildConfiguration":
                for key, value in item["buildSettings"].items():
                    if (
                        key.startswith("SWIFTPODS_LINKER_FLAGS")
                        or key == "OTHER_LDFLAGS"
                    ):
                        words = value if isinstance(value, list) else value.split()
                        assert words.count("-lc++") <= 1, (key, value)
        universal_build(fixture, work, name + "-build")
        fixture.verified.append(
            "dynamic_pod_selects_own_runtime_per_source_exclusion_" + name
        )


def run(fixture):
    platform_filters(fixture)
    architecture_filters(fixture)
    sdk_filters(fixture)
    unicode_filters(fixture)
    pod_filters(fixture)
