"""Conditional source libraries, compiled resources and real binary SDKs."""

import json
import plistlib
import shutil
import subprocess
import time
from pathlib import Path

from scripts.support.bootstrap import ROOT
from Tests.Fixtures.batch_fixture import user_project
from Tests.Fixtures.vendor_fixture import run, sdk
from Tests.Integration.native_integration import serialize


def products(parent, platforms=("macosx", "iphoneos", "iphonesimulator")):
    return [
        (
            name,
            sdk(parent, name, dynamic=dynamic, library=library, platforms=platforms),
            library,
        )
        for name, dynamic, library in [
            ("ConfigStatic", False, False),
            ("ConfigDynamic", True, False),
            ("ConfigLibrary", False, True),
        ]
    ]


def podfile(
    work, linkage="static", multiple=False, configurations=("Debug", "Staging")
):
    platform = "ios" if (work / "Info.plist").exists() else "osx"
    text = f"platform :{platform}, '{'15.0' if platform == 'ios' else '13.0'}'\n"
    if linkage:
        text += f"use_frameworks! :linkage => :{linkage}\n"
    if multiple:
        text += "install! 'cocoapods', :generate_multiple_pod_projects => true\n"
    text += "project 'Demo.xcodeproj', 'Staging' => :debug\ntarget 'Demo' do\n"
    text += (
        "  pod 'ConditionalKit', :path => './Modules/ConditionalKit', :configurations => "
        + repr(list(configurations))
        + "\nend\n"
    )
    # Empty configurations give the reference empty output file lists. Declare
    # those copy/embed scripts as always run, keeping diagnostics enabled.
    text += """post_integrate do |installer|
  project = Xcodeproj::Project.open('Demo.xcodeproj')
  project.targets.each do |target|
    target.shell_script_build_phases.each do |phase|
      if ['[CP] Copy Pods Resources', '[CP] Embed Pods Frameworks'].include?(phase.name)
        phase.always_out_of_date = '1'
      end
    end
  end
  project.save
end
"""
    work.joinpath("Podfile").write_text(text)


def create(work, binaries, linkage="static", raw=False, platform="osx", multiple=False):
    work.mkdir()
    module = work / "Modules/ConditionalKit"
    module.mkdir(parents=True)
    vendor = module / "Vendor Bits"
    vendor.mkdir()
    frameworks, libraries, imports, functions = [], [], [], []
    for name, product, library in binaries:
        if raw:
            info = plistlib.loads(product.joinpath("Info.plist").read_bytes())
            entry = next(
                e
                for e in info["AvailableLibraries"]
                if e["SupportedPlatform"] == "macos"
            )
            source = product / entry["LibraryIdentifier"] / entry["LibraryPath"]
            destination = vendor / source.name
            if library:
                shutil.copy2(source, destination)
                shutil.copy2(
                    product
                    / entry["LibraryIdentifier"]
                    / entry["HeadersPath"]
                    / (name + ".h"),
                    module / (name + ".h"),
                )
            else:
                shutil.copytree(source, destination, symlinks=True)
        else:
            destination = vendor / product.name
            shutil.copytree(product, destination, symlinks=True)
        (libraries if library and raw else frameworks).append(
            destination.relative_to(module).as_posix()
        )
        imports.append(
            "#import "
            + ('"' + name + '.h"' if library else "<" + name + "/" + name + ".h>")
        )
        functions.append(name + "_value()")
    module.joinpath("ConditionalKit.h").write_text(
        '#import <Foundation/Foundation.h>\n#ifdef __cplusplus\nextern "C" {\n#endif\nint conditional_value(void);\n#ifdef __cplusplus\n}\n#endif\n@interface ConditionalProbe : NSObject\n+ (NSBundle *)bundle;\n@end\n'
    )
    module.joinpath("ConditionalKit.m").write_text(
        '#import "ConditionalKit.h"\n'
        + "\n".join(imports)
        + "\nint conditional_value(void) { return "
        + " + ".join(functions)
        + "; }\n@implementation ConditionalProbe\n+ (NSBundle *)bundle { return [NSBundle bundleForClass:self]; }\n@end\n"
    )
    resources = module / "Debug Bits"
    resources.mkdir()
    resources.joinpath("direct.txt").write_text("conditional-direct")
    localized = resources / "en.lproj"
    localized.mkdir()
    localized.joinpath("Localizable.strings").write_text(
        '"conditional" = "localized-conditional";\n'
    )
    asset = resources / "ConditionalPalette.xcassets/Conditional.colorset"
    asset.mkdir(parents=True)
    asset.parent.joinpath("Contents.json").write_text(
        '{"info":{"version":1,"author":"xcode"}}'
    )
    asset.joinpath("Contents.json").write_text(
        json.dumps(
            {
                "colors": [
                    {
                        "idiom": "universal",
                        "color": {
                            "color-space": "srgb",
                            "components": {
                                "red": "0.1",
                                "green": "0.2",
                                "blue": "0.3",
                                "alpha": "1.0",
                            },
                        },
                    }
                ],
                "info": {"version": 1, "author": "xcode"},
            }
        )
    )
    bundle = module / "Bundle"
    bundle.mkdir()
    bundle.joinpath("payload.txt").write_text("conditional-bundle")
    spec = {
        "name": "ConditionalKit",
        "version": "1.0.0",
        "summary": "Conditional fixture",
        "homepage": "https://swiftpods.org",
        "authors": ["SwiftPods"],
        "license": "MIT",
        "source": {"git": "https://example.invalid/conditional.git", "tag": "1.0.0"},
        "platforms": {platform: "15.0" if platform == "ios" else "13.0"},
        "source_files": "*.{h,m}",
        "vendored_frameworks": frameworks,
        "vendored_libraries": libraries,
        "resources": [
            "Debug Bits/direct.txt",
            "Debug Bits/en.lproj",
            "Debug Bits/ConditionalPalette.xcassets",
        ],
        "resource_bundles": {"ConditionalAssets": "Bundle/*"},
    }
    module.joinpath("ConditionalKit.podspec.json").write_text(json.dumps(spec))
    source = """#import <Foundation/Foundation.h>
#if CONDITIONAL_ON
#import <ConditionalKit/ConditionalKit.h>
#endif
static NSDictionary *conditional_validation(void) {
    NSBundle *main = [NSBundle mainBundle];
    NSBundle *direct = main;
    int value = 0;
#if CONDITIONAL_ON
    value = conditional_value();
    direct = [ConditionalProbe bundle];
#endif
    BOOL directOK = [direct pathForResource:@"direct" ofType:@"txt"] != nil;
    BOOL localized = [[direct localizedStringForKey:@"conditional" value:@"absent" table:nil] isEqualToString:@"localized-conditional"];
    BOOL compiled = [direct pathForResource:@"Assets" ofType:@"car"] != nil;
    NSString *bundlePath = [direct pathForResource:@"ConditionalAssets" ofType:@"bundle"];
    BOOL bundled = bundlePath && [[NSBundle bundleWithPath:bundlePath] pathForResource:@"payload" ofType:@"txt"] != nil;
    BOOL embedded = [[NSFileManager defaultManager] fileExistsAtPath:[[main privateFrameworksPath] stringByAppendingPathComponent:@"ConfigDynamic.framework"]];
    BOOL user = [[NSFileManager defaultManager] fileExistsAtPath:[[main resourcePath] stringByAppendingPathComponent:@"User Content/direct.txt"]];
    return @{@"value": @(value), @"direct": @(directOK), @"localized": @(localized), @"compiled": @(compiled), @"bundle": @(bundled), @"embedded": @(embedded), @"user": @(user)};
}
"""
    work.joinpath("Sources").mkdir()
    if platform == "ios":
        template = (ROOT / "Tests/Fixtures/iOS/main.mm").read_text()
        start = template.index("    int value =")
        end = template.index("\n}", start)
        template = (
            template[:start] + "    return conditional_validation();" + template[end:]
        )
        template = template.replace("#import <GameCore/GameCore.h>", source)
        work.joinpath("Sources/main.mm").write_text(template)
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
                }
            )
        )
    else:
        work.joinpath("Sources/main.mm").write_text(
            source
            + "#include <stdio.h>\nint main(void) { @autoreleasepool { NSData *data = [NSJSONSerialization dataWithJSONObject:conditional_validation() options:0 error:NULL]; puts([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String); return 0; } }\n"
        )
    own = work / "User Content"
    own.mkdir()
    own.joinpath("direct.txt").write_text("user-resource")
    user_project(work, "Demo", platform)
    path = work / "Demo.xcodeproj/project.pbxproj"
    graph = json.loads(
        subprocess.check_output(["plutil", "-convert", "json", "-o", "-", str(path)])
    )
    objects = graph["objects"]
    target = next(v for v in objects.values() if v.get("isa") == "PBXNativeTarget")
    objects["111111111111111111111111"] = {
        "isa": "PBXFileReference",
        "path": "User Content",
        "sourceTree": "<group>",
        "lastKnownFileType": "folder",
    }
    objects["222222222222222222222222"] = {
        "isa": "PBXBuildFile",
        "fileRef": "111111111111111111111111",
    }
    objects["333333333333333333333333"] = {
        "isa": "PBXResourcesBuildPhase",
        "files": ["222222222222222222222222"],
        "buildActionMask": "2147483647",
        "runOnlyForDeploymentPostprocessing": "0",
    }
    target["buildPhases"].append("333333333333333333333333")
    for item in objects.values():
        if item.get("isa") == "XCBuildConfiguration" and item["buildSettings"].get(
            "PRODUCT_NAME"
        ):
            item["buildSettings"]["GCC_PREPROCESSOR_DEFINITIONS"].append(
                "CONDITIONAL_ON=" + ("0" if item["name"] == "Release" else "1")
            )
            item["buildSettings"]["EXCLUDED_SOURCE_FILE_NAMES"] = "UserExcluded*.m"
    path.write_text("// !$*UTF8*$!\n" + serialize(graph))
    podfile(work, linkage, multiple)


def expected(configuration, platform="osx"):
    enabled = configuration != "Release"
    return {
        "value": (606 if platform == "ios" else 126) if enabled else 0,
        **{
            k: enabled
            for k in ["direct", "localized", "compiled", "bundle", "embedded"]
        },
        "user": True,
    }


def build(work, group, configuration, platform="osx", expected_configuration=None):
    destination = (
        "generic/platform=iOS Simulator"
        if platform == "ios"
        else "platform=macOS,arch=arm64"
    )
    toolchain = str(
        Path(
            subprocess.check_output(["xcrun", "--find", "swiftc"], text=True).strip()
        ).parents[2]
    )
    label = configuration + ("-enabled" if expected_configuration else "")
    run(
        [
            "xcodebuild",
            "-workspace",
            "Demo.xcworkspace",
            "-scheme",
            "Demo",
            "-configuration",
            configuration,
            "-destination",
            destination,
            "-derivedDataPath",
            group / "DerivedData",
            "CODE_SIGNING_ALLOWED=NO",
            "TOOLCHAIN_DIR=" + toolchain,
            "build",
        ],
        work,
        group / (label + "-build.log"),
    )
    folder = configuration + ("-iphonesimulator" if platform == "ios" else "")
    app = group / "DerivedData/Build/Products" / folder / "Demo.app"
    if platform == "osx":
        actual = json.loads(
            subprocess.check_output([str(app / "Contents/MacOS/Demo")], text=True)
        )
        wanted = expected(expected_configuration or configuration)
        assert actual == wanted, (configuration, actual, wanted)
        linked = subprocess.check_output(
            ["otool", "-L", str(app / "Contents/MacOS/Demo")], text=True
        )
        assert ("ConfigDynamic.framework" in linked) == wanted["embedded"]
    return app


def simulator_run(device, app, configuration):
    for command in [
        ("terminate", device, "org.swiftpods.batch.Demo"),
        ("uninstall", device, "org.swiftpods.batch.Demo"),
    ]:
        subprocess.run(["xcrun", "simctl", *command], capture_output=True)
    subprocess.run(
        ["xcrun", "simctl", "install", device, str(app)],
        check=True,
        capture_output=True,
    )
    subprocess.run(
        ["xcrun", "simctl", "launch", device, "org.swiftpods.batch.Demo"],
        check=True,
        capture_output=True,
    )
    container = Path(
        subprocess.check_output(
            [
                "xcrun",
                "simctl",
                "get_app_container",
                device,
                "org.swiftpods.batch.Demo",
                "data",
            ],
            text=True,
        ).strip()
    )
    output = container / "Documents/validation.json"
    for _ in range(150):
        if output.exists():
            break
        time.sleep(0.1)
    assert output.exists(), (
        "Conditional simulator application did not produce validation.json"
    )
    actual = json.loads(output.read_text())
    assert actual == expected(configuration, "ios"), (configuration, actual)
