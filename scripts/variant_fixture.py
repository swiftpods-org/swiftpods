"""Distinct consumers of one pod, including real transitive SDKs and specs."""

import json
import shutil
import subprocess
from pathlib import Path

from batch_fixture import user_project
from native_integration import serialize
from vendor_fixture import fixture_build_arguments, run

CONSUMERS = [
    ("LibraryA", None, "A", "13.0", True),
    ("LibraryB", None, "B", "13.0", False),
    ("StaticB", "static", "B", "13.1", False),
    ("DynamicA", "dynamic", "A", "13.0", True),
    ("NewerA", "static", "A", "14.0", False),
    ("SameA", None, "A", "13.0", False),
]


def podfile(work, multiple=True, consumers=CONSUMERS):
    text = "platform :osx, '13.0'\nworkspace 'Variants'\n"
    if multiple:
        text += "install! 'cocoapods', :generate_multiple_pod_projects => true\n"
    for name, mode, leaf, deployment, supplementary in consumers:
        text += f"target '{name}' do\n  platform :osx, '{deployment}'\n  project '{name}.xcodeproj', 'Staging' => :debug\n"
        if mode:
            text += f"  use_frameworks! :linkage => :{mode}\n"
        text += "  pod 'VariantPeer', :path => './Modules/VariantPeer'\n"
        text += (
            "  pod 'VariantKit', :path => './Modules/VariantKit', :subspecs => ['"
            + leaf
            + "']"
        )
        if supplementary:
            text += ", :testspecs => ['Checks'], :appspecs => ['Example']"
        text += "\nend\n"
    text += """pre_install do |installer|
  raise 'Missing pod target variants' unless installer.pod_targets.count { |t| t.pod_name == 'VariantKit' } == 5
  raise 'Missing transitive variants' unless installer.pod_targets.count { |t| t.pod_name == 'VariantPeer' } == 4
end
post_install do |installer|
  projects = installer.generated_projects
  targets = projects.flat_map { |p| p.targets.to_a }
  targets.select { |t| t.isa == 'PBXNativeTarget' && (t.product_type == 'com.apple.product-type.library.static' || t.product_type == 'com.apple.product-type.framework') }.each do |target|
    target.build_configurations.each { |c| c.build_settings['VARIANT_HOOK'] = 'preserved' }
  end
  projects.each(&:save)
  installer.pods_project.save
end
"""
    work.joinpath("Podfile").write_text(text)


def create(work, binary, multiple=True, strict_headers=True):
    work.mkdir()
    module = work / "Modules/VariantKit"
    peer = work / "Modules/VariantPeer"
    module.mkdir(parents=True)
    peer.mkdir(parents=True)
    common = module / "Common"
    common.mkdir()
    common.joinpath("VariantKit.h").write_text(
        '#import <Foundation/Foundation.h>\n#ifdef __cplusplus\nextern "C" {\n#endif\nint variant_value(void);\n#ifdef __cplusplus\n}\n#endif\n@interface VariantProbe : NSObject\n+ (NSBundle *)bundle;\n@end\n'
    )
    common.joinpath("Anchor.m").write_text(
        '#import "VariantKit.h"\n@implementation VariantProbe\n+ (NSBundle *)bundle { return [NSBundle bundleForClass:self]; }\n@end\n'
    )
    subspecs = []
    for leaf, value in [("A", 11), ("B", 22)]:
        folder = module / leaf
        folder.mkdir()
        folder.joinpath(leaf + ".h").write_text("#define VARIANT_" + leaf + " 1\n")
        folder.joinpath(leaf + ".c").write_text(
            "#include <VariantPeer/VariantPeer.h>\nint variant_value(void) { return "
            + str(value)
            + " + peer_value(); }\n"
        )
        folder.joinpath("choice.txt").write_text(leaf)
        subspecs.append(
            {
                "name": leaf,
                "source_files": leaf + "/*.{c,h}",
                "resources": leaf + "/choice.txt",
                "dependencies": {"VariantKit/Common": []},
            }
        )
    bundle = module / "Bundle"
    bundle.mkdir()
    bundle.joinpath("shared.txt").write_text("shared")
    checks = module / "Checks"
    checks.mkdir()
    checks.joinpath("check.txt").write_text("check")
    checks.joinpath("Check.m").write_text("""#import <XCTest/XCTest.h>
#import <VariantKit/VariantKit.h>
@interface VariantChecks : XCTestCase @end
@implementation VariantChecks
- (void)testVariantAndOwnResources {
  XCTAssertEqual(variant_value(), 53);
  NSBundle *own = [NSBundle bundleForClass:self.class];
  XCTAssertNotNil([own pathForResource:@"check" ofType:@"txt"]);
  XCTAssertNotNil([own pathForResource:@"VariantChecks" ofType:@"bundle"]);
  NSBundle *library = [VariantProbe bundle];
  XCTAssertNotNil([library pathForResource:@"choice" ofType:@"txt"]);
  XCTAssertNotNil([library pathForResource:@"VariantAssets" ofType:@"bundle"]);
}
@end
""")
    example = module / "Example"
    example.mkdir()
    example.joinpath("main.m").write_text(
        '#import <Foundation/Foundation.h>\n#import <VariantKit/VariantKit.h>\n#include <stdio.h>\nint main(void) { @autoreleasepool { if (variant_value()!=53) return 1; NSBundle *bundle=[VariantProbe bundle]; if (![bundle pathForResource:@"VariantAssets" ofType:@"bundle"]) return 2; puts("variant-example=53"); return 0; } }\n'
    )
    data = {
        "name": "VariantKit",
        "version": "1.0",
        "summary": "Target variants fixture",
        "homepage": "https://swiftpods.org",
        "authors": ["SwiftPods"],
        "license": "MIT",
        "source": {"git": "https://example.invalid/variants.git", "tag": "1.0"},
        "platforms": {"osx": "13.0"},
        "subspecs": subspecs
        + [
            {
                "name": "Common",
                "source_files": "Common/*.{h,m}",
                "dependencies": {"VariantPeer": []},
                "resource_bundles": {"VariantAssets": "Bundle/*"},
            }
        ],
        "testspecs": [
            {
                "name": "Checks",
                "test_type": "unit",
                "platforms": {"osx": "14.0"},
                "source_files": "Checks/*.m",
                "resources": "Checks/check.txt",
                "resource_bundles": {"VariantChecks": "Checks/check.txt"},
                "dependencies": {"VariantKit/A": []},
            }
        ],
        "appspecs": [
            {
                "name": "Example",
                "source_files": "Example/*.m",
                "dependencies": {"VariantKit/A": []},
            }
        ],
    }
    module.joinpath("VariantKit.podspec.json").write_text(json.dumps(data))
    shutil.copytree(binary, peer / binary.name, symlinks=True)
    peer.joinpath("VariantPeer.h").write_text(
        '#ifdef __cplusplus\nextern "C" {\n#endif\nint peer_value(void);\n#ifdef __cplusplus\n}\n#endif\n'
    )
    peer.joinpath("VariantPeer.c").write_text(
        "#include <VariantBinary/VariantBinary.h>\nint peer_value(void) { return VariantBinary_value(); }\n"
    )
    peer.joinpath("VariantPeer.podspec.json").write_text(
        json.dumps(
            {
                "name": "VariantPeer",
                "version": "1.0",
                "summary": "Transitive variant SDK",
                "homepage": "https://swiftpods.org",
                "authors": ["SwiftPods"],
                "license": "MIT",
                "source": {"git": "https://example.invalid/peer.git", "tag": "1.0"},
                "platforms": {"osx": "13.0"},
                "source_files": "*.{h,c}",
                "vendored_frameworks": binary.name,
            }
        )
    )
    work.joinpath("Sources").mkdir()
    work.joinpath("Sources/main.mm").write_text("""#import <Foundation/Foundation.h>
#import <VariantKit/VariantKit.h>
#if WANTED_A
#import <VariantKit/A.h>
#if STRICT_HEADERS && __has_include(<VariantKit/B.h>)
#error Variant B header leaked into A consumer
#endif
#else
#import <VariantKit/B.h>
#if STRICT_HEADERS && __has_include(<VariantKit/A.h>)
#error Variant A header leaked into B consumer
#endif
#endif
#include <stdio.h>
int main(void) { @autoreleasepool {
  int value=variant_value();
  NSBundle *library=[VariantProbe bundle];
  NSString *choice=[NSString stringWithContentsOfFile:[library pathForResource:@"choice" ofType:@"txt"] encoding:NSUTF8StringEncoding error:NULL];
  if (!choice || ![choice isEqualToString:(WANTED_A ? @"A" : @"B")]) return 2;
  if (![library pathForResource:@"VariantAssets" ofType:@"bundle"]) return 3;
  printf("variant=%d choice=%s\\n",value,choice.UTF8String);
  return value == WANTED_VALUE ? 0 : 4;
} }
""")
    for name, mode, leaf, deployment, supplementary in CONSUMERS:
        user_project(work, name)
        path = work / (name + ".xcodeproj/project.pbxproj")
        graph = json.loads(
            subprocess.check_output(
                ["plutil", "-convert", "json", "-o", "-", str(path)]
            )
        )
        for item in graph["objects"].values():
            if item.get("isa") == "XCBuildConfiguration" and item["buildSettings"].get(
                "PRODUCT_NAME"
            ):
                item["buildSettings"]["MACOSX_DEPLOYMENT_TARGET"] = deployment
                item["buildSettings"]["GCC_PREPROCESSOR_DEFINITIONS"] = [
                    "$(inherited)",
                    "STRICT_HEADERS=" + ("1" if strict_headers else "0"),
                    "WANTED_A=" + ("1" if leaf == "A" else "0"),
                    "WANTED_VALUE=" + str(53 if leaf == "A" else 64),
                ]
        path.write_text("// !$*UTF8*$!\n" + serialize(graph))
    podfile(work, multiple)
    return data


def build_consumers(work, group, configuration="Debug"):
    toolchain = str(
        Path(
            subprocess.check_output(["xcrun", "--find", "swiftc"], text=True).strip()
        ).parents[2]
    )
    entries = []
    for name, mode, leaf, deployment, selected in CONSUMERS:
        path = work / (name + ".xcodeproj/project.pbxproj")
        graph = json.loads(
            subprocess.check_output(
                ["plutil", "-convert", "json", "-o", "-", str(path)]
            )
        )
        target = next(
            key
            for key, item in graph["objects"].items()
            if item.get("isa") == "PBXNativeTarget"
        )
        entries.append(
            f'<BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="{name}.app" BlueprintName="{name}" ReferencedContainer="container:{name}.xcodeproj"/></BuildActionEntry>'
        )
    # Explicit aggregate entries make the workspace scheme independent of
    # implicit product discovery, as schemes generated by the reference do.
    graph = json.loads(
        subprocess.check_output(
            [
                "plutil",
                "-convert",
                "json",
                "-o",
                "-",
                str(work / "Pods/Pods.xcodeproj/project.pbxproj"),
            ]
        )
    )
    for key, target in graph["objects"].items():
        if target.get("isa") not in [
            "PBXNativeTarget",
            "PBXAggregateTarget",
        ] or not target.get("name", "").startswith("Pods-"):
            continue
        product = (
            graph["objects"]
            .get(target.get("productReference"), {})
            .get("path", target["name"])
        )
        entries.append(
            f'<BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{key}" BuildableName="{product}" BlueprintName="{target["name"]}" ReferencedContainer="container:Pods/Pods.xcodeproj"/></BuildActionEntry>'
        )
    schemes = work / "Variants.xcworkspace/xcshareddata/xcschemes"
    schemes.mkdir(parents=True, exist_ok=True)
    schemes.joinpath("AllConsumers.xcscheme").write_text(
        '<?xml version="1.0" encoding="UTF-8"?><Scheme LastUpgradeVersion="2700" version="1.3"><BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>'
        + "".join(entries)
        + "</BuildActionEntries></BuildAction></Scheme>"
    )
    run(
        [
            "xcodebuild",
            "-workspace",
            "Variants.xcworkspace",
            "-scheme",
            "AllConsumers",
            "-configuration",
            configuration,
            "-destination",
            "platform=macOS,arch=arm64",
            *fixture_build_arguments(group),
            "CODE_SIGNING_ALLOWED=NO",
            "TOOLCHAIN_DIR=" + toolchain,
            "build",
        ],
        work,
        group / ("AllConsumers-" + configuration + ".log"),
    )
    for name, mode, leaf, deployment, supplementary in CONSUMERS:
        app = group / "DerivedData/Build/Products" / configuration / (name + ".app")
        output = subprocess.check_output(
            [str(app / "Contents/MacOS" / name)], text=True
        ).strip()
        assert output == f"variant={53 if leaf == 'A' else 64} choice={leaf}", (
            name,
            output,
        )
        frameworks = app / "Contents/Frameworks"
        embedded = (
            {p.name for p in frameworks.glob("*.framework")}
            if frameworks.exists()
            else set()
        )
        assert embedded == (
            {"VariantKit.framework", "VariantPeer.framework"}
            if mode == "dynamic"
            else set()
        ), (name, embedded)


def supplementary(work, group):
    path = work / "Pods/Pods.xcodeproj/xcshareddata/xcschemes"
    tests = sorted(p.stem for p in path.glob("*-Unit-Checks.xcscheme"))
    apps = sorted(p.stem for p in path.glob("*-Example.xcscheme"))
    assert len(tests) == 2 and len(apps) == 2, (tests, apps)
    for scheme in tests + apps:
        action = "test" if scheme in tests else "build"
        text = run(
            [
                "xcodebuild",
                "-project",
                "Pods/Pods.xcodeproj",
                "-scheme",
                scheme,
                "-configuration",
                "Debug",
                "-destination",
                "platform=macOS,arch=arm64",
                *fixture_build_arguments(group),
                "CODE_SIGNING_ALLOWED=NO",
                action,
            ],
            work,
            group / (scheme + ".log"),
        )
        if action == "test":
            assert (
                "testVariantAndOwnResources" in text and "** TEST SUCCEEDED **" in text
            )
        else:
            app = next(
                (group / "DerivedData/Build/Products").rglob(
                    scheme + ".app/Contents/MacOS/" + scheme
                )
            )
            assert (
                subprocess.check_output([str(app)], text=True).strip()
                == "variant-example=53"
            )


def contract(work):
    graphs = [
        json.loads(
            subprocess.check_output(["plutil", "-convert", "json", "-o", "-", str(p)])
        )
        for p in work.glob("Pods/*.xcodeproj/project.pbxproj")
    ]
    libraries = {}
    for graph in graphs:
        objects = graph["objects"]
        for target in objects.values():
            if target.get("productType") not in [
                "com.apple.product-type.framework",
                "com.apple.product-type.library.static",
            ]:
                continue
            settings = objects[
                objects[target["buildConfigurationList"]]["buildConfigurations"][0]
            ]["buildSettings"]
            assert settings["VARIANT_HOOK"] == "preserved"
            libraries[target["name"]] = settings
    assert len([name for name in libraries if name.startswith("VariantKit")]) == 5, (
        libraries.keys()
    )
    assert len([name for name in libraries if name.startswith("VariantPeer")]) == 4, (
        libraries.keys()
    )
    return libraries
