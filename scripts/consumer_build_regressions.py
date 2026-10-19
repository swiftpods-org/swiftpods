"""Build consumers that exercise archive, header, module and resource isolation."""

import json
import subprocess

from header_ownership_regressions import resources_in_app
from native_xcconfig_tests import create
from workspace_resource_regressions import read_project


def update_spec(work, **changes):
    path = work / "Kit/Kit.podspec.json"
    data = json.loads(path.read_text())
    data.update(changes)
    path.write_text(json.dumps(data))
    return data


def podfile(work):
    return (work / "Podfile").read_text().split("post_install")[0]


def install_twice(fixture, work):
    fixture.cli(work, "install")
    project = work / "Pods/Pods.xcodeproj"
    before = read_project(project)
    fixture.cli(work, "install", "--deployment")
    assert read_project(project) == before, project


def static_archives(fixture):
    work, selected = create(fixture.root / "shared-module-static-archives")
    (selected.parent / "Sources/main.mm").write_text(
        'extern "C" int kit_value(void);\nextern "C" int peer_value(void);\n'
        "int main(void) { return kit_value() == 7 && peer_value() == 9 ? 0 : 1; }\n"
    )
    data = update_spec(work, module_name="Shared")
    peer = work / "Peer"
    peer.mkdir()
    (peer / "Peer.c").write_text("int peer_value(void) { return 9; }\n")
    (peer / "Peer.h").write_text("int peer_value(void);\n")
    (peer / "Peer.podspec.json").write_text(json.dumps(dict(data, name="Peer")))
    (work / "Podfile").write_text(
        podfile(work).replace(
            "pod 'Kit', :path => './Kit'",
            "pod 'Kit', :path => './Kit'\n pod 'Peer', :path => './Peer'",
        )
        + """post_install do |installer|
  installer.pod_targets.each do |target|
    expected = 'lib' + target.label + '.a'
    raise 'Hook archive name differs from generated product' unless target.product_name == expected && target.native_target.product_reference.path == expected
  end
end
"""
    )
    install_twice(fixture, work)
    graph = read_project(work / "Pods/Pods.xcodeproj")
    objects = graph["objects"]
    products = {
        target["name"]: objects[target["productReference"]]["path"]
        for target in objects.values()
        if target.get("productType") == "com.apple.product-type.library.static"
    }
    assert products == {"Kit": "libKit.a", "Peer": "libPeer.a"}, products
    label = "shared-module-static-build"
    fixture.build(work, "Demo", label)
    binary = resources_in_app(fixture, label) / "Contents/MacOS/Demo"
    subprocess.run([str(binary)], check=True)
    fixture.verified.append(
        "static_archives_share_module_name_without_product_collision"
    )


def headers(fixture):
    for scenario in ["implicit-private", "unmatched-public"]:
        work, _ = create(fixture.root / scenario)
        library = work / "Kit"
        if scenario == "implicit-private":
            (library / "Internal.h").write_text("#define INTERNAL_VALUE 7\n")
            (library / "Kit.c").write_text(
                "#include <Kit/Internal.h>\nint kit_value(void) { return INTERNAL_VALUE; }\n"
            )
            update_spec(work, public_header_files="Kit.h")
        else:
            update_spec(work, public_header_files="Missing/*.h")
        (work / "Podfile").write_text(
            podfile(work)
            + """post_install do |installer|
  accessor = installer.pod_targets.first.file_accessors.first
  headers = accessor.public_headers.map { |path| path.basename.to_s }.sort
  raise "Incorrect public headers: #{headers}" unless headers == ['Kit.h']
end
"""
        )
        install_twice(fixture, work)
        if scenario == "implicit-private":
            assert list((work / "Pods/Headers/Private").rglob("Internal.h"))
            assert not list((work / "Pods/Headers/Public").rglob("Internal.h"))
        fixture.build(work, "Demo", scenario + "-build")
        fixture.verified.append(scenario + "_headers_build_and_match_hook_visibility")


def supplementary_module_maps(fixture):
    for kind in ["app", "test"]:
        work, _ = create(fixture.root / ("supplementary-map-" + kind))
        library = work / "Kit"
        name = "Example" if kind == "app" else "Tests"
        sources = library / name
        sources.mkdir()
        contents = (
            "@import Feature;\n#if FEATURE_VALUE != 7 || USER_FLAG != 1\n"
            "#error Custom module or user flags missing\n#endif\n"
        )
        if kind == "app":
            contents += "int main(void) { return 0; }\n"
        (sources / "Main.m").write_text(contents)
        (library / "Feature.h").write_text("#define FEATURE_VALUE 7\n")
        modulemap = library / "Custom.modulemap"
        original_map = (
            'module Kit { header "Kit.h" export * }\n'
            'module Feature { header "Feature.h" export * }\n'
        )
        modulemap.write_text(original_map)
        spec = {
            "name": name,
            "source_files": name + "/*.m",
            "pod_target_xcconfig": {
                "CLANG_ENABLE_MODULES": "YES",
                "OTHER_CFLAGS": "$(inherited) -DUSER_FLAG=1",
            },
        }
        if kind == "test":
            spec["test_type"] = "unit"
        update_spec(
            work,
            platforms={"osx": "14.0"},
            module_map="Custom.modulemap",
            public_header_files="*.h",
            **{kind + "specs": [spec]},
        )
        (work / "Podfile").write_text(
            podfile(work)
            .replace("'13.0'", "'14.0'")
            .replace(
                ":path => './Kit'",
                ":path => './Kit', :modular_headers => true, :"
                + kind
                + "specs => ['"
                + name
                + "']",
            )
        )
        install_twice(fixture, work)
        scheme = "Kit-Example" if kind == "app" else "Kit-Unit-Tests"
        fixture.build(work, scheme, "supplementary-map-build-" + kind)
        assert modulemap.read_text() == original_map
        fixture.verified.append(
            "custom_module_map_and_user_flags_reach_" + kind + "_spec"
        )


def independent_app_bundles(fixture):
    work, _ = create(fixture.root / "independent-app-bundles")
    library = work / "Kit"
    apps = []
    for name in ["First", "Second"]:
        app = library / name
        app.mkdir()
        (app / (name + ".txt")).write_text(name)
        (app / "main.m").write_text(
            "#import <Foundation/Foundation.h>\nint main(void) { @autoreleasepool {\n"
            ' NSString *path = [[NSBundle mainBundle] pathForResource:@"Shared" ofType:@"bundle"];\n'
            " if (!path) return 1;\n NSBundle *bundle = [NSBundle bundleWithPath:path];\n"
            ' NSString *payload = [bundle pathForResource:@"'
            + name
            + '" ofType:@"txt"];\n if (!payload) return 2;\n'
            " NSString *value = [NSString stringWithContentsOfFile:payload encoding:NSUTF8StringEncoding error:nil];\n"
            ' return [value isEqualToString:@"' + name + '"] ? 0 : 3;\n} }\n'
        )
        apps.append(
            {
                "name": name,
                "source_files": name + "/*.m",
                "frameworks": ["AppKit"],
                "resource_bundles": {"Shared": name + "/*.txt"},
            }
        )
    update_spec(work, appspecs=apps)
    (work / "Podfile").write_text(
        podfile(work).replace(
            ":path => './Kit'", ":path => './Kit', :appspecs => ['First', 'Second']"
        )
    )
    install_twice(fixture, work)
    for name in ["First", "Second"]:
        label = "independent-app-bundle-build-" + name
        scheme = "Kit-" + name
        fixture.build(work, scheme, label)
        app = resources_in_app(fixture, label, scheme)
        bundle = next(app.rglob("Shared.bundle"))
        markers = {path.stem: path.read_text() for path in bundle.rglob("*.txt")}
        assert markers == {name: name}, markers
        subprocess.run([str(app / "Contents/MacOS" / scheme)], check=True)
        fixture.verified.append(
            "independent_" + name + "_app_keeps_own_same_named_bundle_payload"
        )


def platform_hook(fixture):
    work, selected = create(fixture.root / "platform-support-hook")
    (work / "Podfile").write_text(
        podfile(work)
        + """post_install do |installer|
  platform = installer.pod_targets.first.platform
  raise 'macOS Symbol rejected' unless platform.supports?(:osx)
  raise 'macOS alias rejected' unless platform.supports?('macos')
  raise 'Platform copy changed' unless Pod::Platform.new(platform) == platform
  raise 'Deployment hash changed' unless Pod::Platform.new(:ios, :deployment_target => '14.0').deployment_target.to_s == '14.0'
  installer.aggregate_targets.first.user_targets.first.build_configurations.each do |config|
    config.build_settings['GCC_PREPROCESSOR_DEFINITIONS'] ||= ['$(inherited)']
    config.build_settings['GCC_PREPROCESSOR_DEFINITIONS'] << 'PLATFORM_HOOK=1'
  end
end
"""
    )
    (selected.parent / "Sources/main.mm").write_text(
        "#if PLATFORM_HOOK != 1\n#error Platform hook was skipped\n#endif\nint main(void) { return 0; }\n"
    )
    fixture.cli(work, "install")
    fixture.cli(work, "install", "--deployment")
    fixture.build(work, "Demo", "platform-support-hook-build")
    fixture.verified.append(
        "platform_name_support_and_constructor_forms_work_in_real_hook"
    )


def run(fixture):
    static_archives(fixture)
    headers(fixture)
    supplementary_module_maps(fixture)
    independent_app_bundles(fixture)
    platform_hook(fixture)
