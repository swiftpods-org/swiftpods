#!/usr/bin/env python3
"""Exercise the Swift engine with no reference engine or runtime gems on its path."""

import json
import platform
import plistlib
import shutil
import subprocess

from bootstrap import ROOT, environment, project_state_directory
from local_build import debug_binary, fixture_directory, results_directory
from reporting import execute


def serialize(value):
    if isinstance(value, dict):
        return (
            "{"
            + "".join(
                json.dumps(str(key), ensure_ascii=False) + "=" + serialize(item) + ";"
                for key, item in value.items()
            )
            + "}"
        )
    if isinstance(value, list):
        return "(" + ",".join(serialize(item) for item in value) + ")"
    return json.dumps(str(value), ensure_ascii=False)


def project(path, platform="osx", *, scoped_variants=False):
    objects = {
        "PROJ": {
            "isa": "PBXProject",
            "buildConfigurationList": "PROJECT_CONFIGS",
            "mainGroup": "GROUP",
            "productRefGroup": "PRODUCTS",
            "targets": ["TARGET"],
            "compatibilityVersion": "Xcode 14.0",
            "developmentRegion": "en",
            "knownRegions": ["en", "Base"],
            "projectDirPath": "",
            "projectRoot": "",
        },
        "GROUP": {
            "isa": "PBXGroup",
            "sourceTree": "<group>",
            "children": ["MAIN", "PRODUCTS"],
        },
        "PRODUCTS": {
            "isa": "PBXGroup",
            "sourceTree": "<group>",
            "name": "Products",
            "children": ["PRODUCT"],
        },
        "MAIN": {
            "isa": "PBXFileReference",
            "path": "Sources/main.mm",
            "sourceTree": "<group>",
            "lastKnownFileType": "sourcecode.cpp.objcpp",
        },
        "PRODUCT": {
            "isa": "PBXFileReference",
            "path": "Demo.app",
            "sourceTree": "BUILT_PRODUCTS_DIR",
            "explicitFileType": "wrapper.application",
        },
        "BUILD": {"isa": "PBXBuildFile", "fileRef": "MAIN"},
        "SOURCES": {
            "isa": "PBXSourcesBuildPhase",
            "files": ["BUILD"],
            "buildActionMask": "2147483647",
            "runOnlyForDeploymentPostprocessing": "0",
        },
        "FRAMEWORKS": {
            "isa": "PBXFrameworksBuildPhase",
            "files": [],
            "buildActionMask": "2147483647",
            "runOnlyForDeploymentPostprocessing": "0",
        },
        "TARGET": {
            "isa": "PBXNativeTarget",
            "name": "Demo",
            "productName": "Demo",
            "productReference": "PRODUCT",
            "productType": "com.apple.product-type.application",
            "buildConfigurationList": "TARGET_CONFIGS",
            "buildPhases": ["SOURCES", "FRAMEWORKS"],
            "buildRules": [],
            "dependencies": [],
        },
    }
    settings = {
        "SDKROOT": "macosx",
        "MACOSX_DEPLOYMENT_TARGET": "13.0",
        "PRODUCT_NAME": "Demo",
        "PRODUCT_BUNDLE_IDENTIFIER": "org.swiftpods.fixture",
        "GENERATE_INFOPLIST_FILE": "YES",
        "CODE_SIGNING_ALLOWED": "NO",
        "CLANG_CXX_LANGUAGE_STANDARD": "c++17",
        "SWIFT_VERSION": "5.0",
        "GCC_TREAT_WARNINGS_AS_ERRORS": "YES",
        "SWIFT_TREAT_WARNINGS_AS_ERRORS": "YES",
        "GCC_PREPROCESSOR_DEFINITIONS": ["$(inherited)", "FIXTURE_USER_FLAG=1"],
        "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
    }
    if platform == "ios":
        settings.pop("MACOSX_DEPLOYMENT_TARGET")
        settings.update(
            SDKROOT="iphoneos",
            IPHONEOS_DEPLOYMENT_TARGET="15.0",
            TARGETED_DEVICE_FAMILY="1,2",
            GENERATE_INFOPLIST_FILE="NO",
            INFOPLIST_FILE="Info.plist",
            CLANG_ENABLE_OBJC_ARC="YES",
        )
        objects["INTENT"] = {
            "isa": "PBXFileReference",
            "path": "Sources/FixtureIntent.swift",
            "sourceTree": "<group>",
            "lastKnownFileType": "sourcecode.swift",
        }
        objects["INTENT_BUILD"] = {"isa": "PBXBuildFile", "fileRef": "INTENT"}
        objects["SOURCES"]["files"].append("INTENT_BUILD")
        objects["GROUP"]["children"].append("INTENT")
        objects["UIKIT"] = {
            "isa": "PBXFileReference",
            "path": "System/Library/Frameworks/UIKit.framework",
            "sourceTree": "SDKROOT",
            "lastKnownFileType": "wrapper.framework",
        }
        objects["UIKIT_BUILD"] = {"isa": "PBXBuildFile", "fileRef": "UIKIT"}
        objects["FRAMEWORKS"]["files"].append("UIKIT_BUILD")
        objects["GROUP"]["children"].append("UIKIT")
    for prefix in ("PROJECT", "TARGET"):
        ids = []
        for name in ("Debug", "Release"):
            identifier = prefix + "_" + name
            ids.append(identifier)
            objects[identifier] = {
                "isa": "XCBuildConfiguration",
                "name": name,
                "buildSettings": settings if prefix == "TARGET" else {},
            }
        objects[prefix + "_CONFIGS"] = {
            "isa": "XCConfigurationList",
            "buildConfigurations": ids,
            "defaultConfigurationName": "Release",
            "defaultConfigurationIsVisible": "0",
        }
    if scoped_variants:
        settings["CONFIGURATION_BUILD_DIR"] = "$(BUILD_DIR)/Apps/$(CONFIGURATION)$(EFFECTIVE_PLATFORM_NAME)"
        objects["PROJ"]["targets"].append("OTHER_TARGET")
        objects["PRODUCTS"]["children"].append("OTHER_PRODUCT")
        objects["OTHER_PRODUCT"] = dict(objects["PRODUCT"], path="Other.app")
        objects["OTHER_BUILD"] = dict(objects["BUILD"])
        objects["OTHER_MAIN"] = dict(objects["MAIN"], path="Sources/other.mm")
        objects["GROUP"]["children"].append("OTHER_MAIN")
        objects["OTHER_BUILD"]["fileRef"] = "OTHER_MAIN"
        (path.parent / "Sources/other.mm").write_text('''#import <Foundation/Foundation.h>
#import <FixtureVendor/FixtureVendor.h>
#include <FixtureArchive.h>
#include <stdio.h>
int main(void) {
    @autoreleasepool {
        NSString *file = [[NSBundle mainBundle] pathForResource:@"payload $Data" ofType:@"txt"];
        NSString *payload = [NSString stringWithContentsOfFile:file encoding:NSUTF8StringEncoding error:nil];
        NSString *catalog = [[NSBundle mainBundle] localizedStringForKey:@"fixture_catalog" value:nil table:@"Loose"];
        if (![payload isEqualToString:@"SwiftPods Loose"] || ![catalog isEqualToString:@"SwiftPods Catalog"]) return 3;
        if (fixture_vendor() != 7 || fixture_archive() != 9) return 4;
        printf("vendor=ok loose=ok catalog=ok\\n");
        return 0;
    }
}
''')
        objects["OTHER_SOURCES"] = dict(objects["SOURCES"], files=["OTHER_BUILD"])
        objects["OTHER_FRAMEWORKS"] = dict(objects["FRAMEWORKS"])
        objects["OTHER_TARGET"] = dict(objects["TARGET"], name="Other", productName="Other",
            productReference="OTHER_PRODUCT", buildPhases=["OTHER_SOURCES", "OTHER_FRAMEWORKS"],
            buildConfigurationList="OTHER_CONFIGS")
        objects["OTHER_CONFIGS"] = dict(objects["TARGET_CONFIGS"],
            buildConfigurations=["OTHER_Debug", "OTHER_Release"])
        for configuration in ("Debug", "Release"):
            objects["OTHER_" + configuration] = dict(objects["TARGET_" + configuration],
                buildSettings=dict(settings, PRODUCT_NAME="Other", PRODUCT_BUNDLE_IDENTIFIER="org.swiftpods.fixture.other"))
    # Real Xcode identifiers have 24 hexadecimal characters.
    import hashlib

    mapping = {
        key: hashlib.sha256(key.encode()).hexdigest()[:24].upper() for key in objects
    }

    def ids(value):
        if isinstance(value, dict):
            return {mapping.get(key, key): ids(item) for key, item in value.items()}
        if isinstance(value, list):
            return [ids(item) for item in value]
        return mapping.get(value, value)

    path.mkdir()
    (path / "project.pbxproj").write_text(
        "// !$*UTF8*$!\n"
        + serialize(
            {
                "archiveVersion": "1",
                "objectVersion": "56",
                "classes": {},
                "objects": ids(objects),
                "rootObject": mapping["PROJ"],
            }
        )
    )


def vendor_fixture(work):
    root = work / "Modules/VendorBits"
    root.mkdir()
    build = root / "Build"
    build.mkdir()
    architecture = platform.machine()
    target = architecture + "-apple-macos13.0"

    def run(*args):
        subprocess.run(args, check=True, capture_output=True)

    source = build / "vendor.c"
    source.write_text("int fixture_vendor(void) { return 7; }\n")
    framework = build / "FixtureVendor.framework"
    version = framework / "Versions/A"
    (version / "Headers").mkdir(parents=True)
    (version / "Resources").mkdir()
    (version / "Headers/FixtureVendor.h").write_text(
        '#ifdef __cplusplus\nextern "C" {\n#endif\n'
        "int fixture_vendor(void);\n#ifdef __cplusplus\n}\n#endif\n"
    )
    (version / "Resources/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleExecutable": "FixtureVendor", "CFBundleIdentifier": "org.swiftpods.fixture.vendor",
        "CFBundlePackageType": "FMWK", "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0",
    }))
    (framework / "Versions/Current").symlink_to("A")
    for name in ("FixtureVendor", "Headers", "Resources"):
        (framework / name).symlink_to("Versions/Current/" + name)
    run("xcrun", "clang", "-target", target, "-dynamiclib", str(source), "-install_name",
        "@rpath/FixtureVendor.framework/Versions/A/FixtureVendor", "-o", str(version / "FixtureVendor"))
    run("xcodebuild", "-create-xcframework", "-framework", str(framework), "-output", str(root / "FixtureVendor.xcframework"))
    source.write_text("int fixture_archive(void) { return 9; }\n")
    run("xcrun", "clang", "-target", target, "-c", str(source), "-o", str(build / "archive.o"))
    run("xcrun", "libtool", "-static", "-o", str(build / "libFixtureArchive.a"), str(build / "archive.o"))
    headers = build / "ArchiveHeaders"
    headers.mkdir()
    (headers / "FixtureArchive.h").write_text(
        '#ifdef __cplusplus\nextern "C" {\n#endif\n'
        "int fixture_archive(void);\n#ifdef __cplusplus\n}\n#endif\n"
    )
    run("xcodebuild", "-create-xcframework", "-library", str(build / "libFixtureArchive.a"),
        "-headers", str(headers), "-output", str(root / "FixtureArchive.xcframework"))
    loose = root / "Loose assets"
    loose.mkdir()
    (loose / "payload $Data.txt").write_text("SwiftPods Loose")
    (loose / "en.lproj").mkdir()
    (loose / "en.lproj/Vendor.strings").write_text('"vendor" = "Localized Vendor";\n')
    (loose / "Loose.xcstrings").write_text(json.dumps({
        "sourceLanguage": "en", "version": "1.0", "strings": {"fixture_catalog": {"localizations": {
            language: {"stringUnit": {"state": "translated", "value": value}}
            for language, value in (("en", "SwiftPods Catalog"), ("fr", "Catalogue SwiftPods"))
        }}},
    }))
    (root / "VendorBits.podspec").write_text("""Pod::Spec.new do |s|
  s.name = 'VendorBits'
  s.version = '1.0'
  s.summary = 'Binary and loose resource fixture'
  s.homepage = 'https://example.invalid/vendor'
  s.license = { :type => 'MIT' }
  s.author = 'SwiftPods'
  s.source = { :git => 'https://example.invalid/vendor.git', :tag => s.version.to_s }
  s.osx.deployment_target = '13.0'
  s.vendored_frameworks = 'FixtureVendor.xcframework'
  s.vendored_libraries = 'FixtureArchive.xcframework'
  s.resources = 'Loose assets/*'
end
""")
    main = work / "Sources/main.mm"
    text = main.read_text().replace('#include <stdio.h>', '#include <stdio.h>\n#import <FixtureVendor/FixtureVendor.h>\n#include <FixtureArchive.h>')
    text = text.replace('        printf(', '''        NSString *loose = [[NSBundle mainBundle] pathForResource:@"payload $Data" ofType:@"txt"];
        NSString *payload = [NSString stringWithContentsOfFile:loose encoding:NSUTF8StringEncoding error:nil];
        NSString *catalog = [[NSBundle mainBundle] localizedStringForKey:@"fixture_catalog" value:nil table:@"Loose"];
        if (![payload isEqualToString:@"SwiftPods Loose"] || ![catalog isEqualToString:@"SwiftPods Catalog"]) return 3;
        if (fixture_vendor() != 7 || fixture_archive() != 9) return 4;
        printf("vendor=ok loose=ok catalog=ok\\n");
        printf(''')
    main.write_text(text)


def exercise(variant, *, multiple_projects=False, scoped_variants=False, cli=None):
    fixture = fixture_directory("native-integration-")
    shutil.copytree(ROOT / "Tests/Fixtures/MixedLanguages", fixture / "project")
    work = fixture / "project"
    vendor_fixture(work)
    podfile = work / "Podfile"
    text = podfile.read_text()
    text = text.replace("  fixture_dependencies if", "  pod 'VendorBits', :path => 'Modules/VendorBits'\n  fixture_dependencies if")
    if variant == "dynamic-framework":
        text = text.replace(":linkage => :static", ":linkage => :dynamic")
    if variant == "static-library":
        text = text.replace("use_frameworks! :linkage => :static\n", "")
    if multiple_projects:
        text = text.replace(
            ":deterministic_uuids => true",
            ":deterministic_uuids => true, :generate_multiple_pod_projects => true",
        )
    if scoped_variants:
        text = text.replace("\npre_install do", """
target 'Other' do
  use_frameworks! :linkage => :dynamic
  pod 'VendorBits', :path => 'Modules/VendorBits'
end

pre_install do""", 1)
    podfile.write_text(text)
    if variant == "dynamic-framework":
        shutil.copy2(
            ROOT / "Tests/Fixtures/iOS/GameCoreIntent.swift",
            work / "Modules/GameCore/Sources/FixtureIntent.swift",
        )
    project(work / "Demo.xcodeproj", scoped_variants=scoped_variants)
    env = environment()
    env["SWIFTPODS_CACHE_ROOT"] = str(fixture / "cache")
    env["GEM_HOME"] = str(fixture / "no-global-gems")
    env["GEM_PATH"] = env["GEM_HOME"]
    cli = cli or debug_binary()

    def run(*args, success=True, directory=work):
        result = subprocess.run(
            [str(cli), *args, "--json"],
            cwd=directory,
            env=env,
            capture_output=True,
            text=True,
            timeout=90,
        )
        if success and result.returncode:
            raise RuntimeError(result.stderr + result.stdout)
        if not success and not result.returncode:
            raise RuntimeError("Expected command failure: " + str(args))
        return json.loads(result.stdout)

    nested = work / "Sources"
    installed = run("install", directory=nested)
    assert installed["exit_status"] == 0
    assert not (nested / "Pods").exists()
    assert not project_state_directory(nested).exists()
    consumer_graph = json.loads(
        subprocess.check_output(
            ["plutil", "-convert", "json", "-o", "-", str(work / "Demo.xcodeproj/project.pbxproj")],
            text=True,
        )
    )["objects"]
    consumer = next(
        obj for obj in consumer_graph.values()
        if obj.get("isa") == "PBXNativeTarget" and obj.get("name") == "Demo"
    )
    assert len(consumer["dependencies"]) == 1
    assert sum(obj.get("isa") == "PBXBuildFile" for obj in consumer_graph.values()) == (2 if scoped_variants else 1)
    assert sum(
        obj.get("lastKnownFileType") == "wrapper.pb-project"
        for obj in consumer_graph.values()
    ) == 1
    assert (
        next(event for event in installed["events"] if event["kind"] == "started")[
            "engine"
        ]
        == "swift"
    )
    assert (work / "hook-trace.txt").read_text().splitlines() == [
        "pre_install",
        "pre_integrate",
        "post_install",
        "post_integrate",
    ]
    generated = (work / "Pods/Pods.xcodeproj/project.pbxproj").read_text()
    assert "SWIFTPODS_HOOK_MARKER" in generated
    original_lock = (work / "Podfile.lock").read_bytes()
    original_project = (work / "Demo.xcodeproj/project.pbxproj").read_bytes()
    run("install", "--deployment", "--offline", directory=nested)
    assert (work / "Podfile.lock").read_bytes() == original_lock
    assert (work / "Demo.xcodeproj/project.pbxproj").read_bytes() == original_project
    assert not (nested / "Pods").exists()
    assert not project_state_directory(nested).exists()
    graph = run("graph", directory=nested)
    assert graph["freshness"] == "tracked_inputs_match", graph.get("changed_inputs")
    why = run("why", "GameCore")
    assert why["dependency_chains"], why
    log = fixture / "xcodebuild.log"
    with log.open("wb") as output:
        build = subprocess.run(
            [
                "xcodebuild",
                "-workspace",
                "Demo.xcworkspace",
                "-scheme",
                "Demo",
                "-configuration",
                "Debug",
                "-derivedDataPath",
                str(fixture / "DerivedData"),
                "CODE_SIGNING_ALLOWED=NO",
                "build",
            ],
            cwd=work,
            stdout=output,
            stderr=subprocess.STDOUT,
        )
    if build.returncode:
        raise RuntimeError("Xcode build failed; see " + str(log))
    text = log.read_text()
    if " warning:" in text or "\nwarning:" in text:
        raise RuntimeError("Xcode emitted warnings; see " + str(log))
    products = fixture / "DerivedData/Build/Products"
    output = products / ("Apps/Debug" if scoped_variants else "Debug")
    app = output / "Demo.app/Contents/MacOS/Demo"
    result = subprocess.check_output([str(app)], cwd=work, text=True)
    assert "mixed=15 resources=ok privacy=ok" in result, result
    assert "vendor=ok loose=ok catalog=ok" in result, result
    if scoped_variants:
        other_log = fixture / "xcodebuild-other.log"
        with other_log.open("wb") as output_log:
            other = subprocess.run([
                "xcodebuild", "-workspace", "Demo.xcworkspace", "-scheme", "Other",
                "-configuration", "Debug", "-derivedDataPath", str(fixture / "DerivedData"),
                "CODE_SIGNING_ALLOWED=NO", "build",
            ], cwd=work, stdout=output_log, stderr=subprocess.STDOUT)
        if other.returncode or " warning:" in other_log.read_text() or "\nwarning:" in other_log.read_text():
            raise RuntimeError("Other consumer build failed or emitted warnings; see " + str(other_log))
        other_result = subprocess.check_output([str(output / "Other.app/Contents/MacOS/Other")], cwd=work, text=True)
        assert "vendor=ok loose=ok catalog=ok" in other_result, other_result
    # The adapter rejects accidental fallback to any installed reference engine.
    (work / "Podfile").write_text("require 'cocoapods/installer/analyzer'\n")
    rejected = run("install", success=False)
    assert any(
        "forbidden" in event.get("message", "") for event in rejected.get("events", [])
    )
    report = {
        "status": "passed",
        "engine": "swift",
        "fixture": str(fixture),
        "verified": [
            "mixed Swift/ObjC/ObjC++/C/C++ build and run",
            "localized resources and privacy manifest",
            "sandboxed scripts copy a dynamic XCFramework and compiled loose resources",
            "static XCFramework archive links through xcconfig",
            "four live Ruby hooks",
            "hook build settings",
            "parent Podfile discovery from nested invocation",
            "single aggregate dependency and project reference",
            "deployment/offline reinstall",
            "graph and why freshness",
            "external engine load rejected",
        ],
        "variant": variant,
        "multiple_projects": multiple_projects,
        "scoped_variants": scoped_variants,
        "unverified": [
            "complete reference compatibility",
            "Intel",
            "physical devices",
            "signing",
        ],
    }
    return report


def main():
    scenarios = [
        exercise(variant, multiple_projects=multiple_projects)
        for multiple_projects in (False, True)
        for variant in ("static-framework", "dynamic-framework", "static-library")
    ]
    scenarios.append(exercise("static-framework", multiple_projects=True, scoped_variants=True))
    report = {
        "status": "passed",
        "engine": "swift",
        "scenarios": scenarios,
        "verified": [
            "three native linkage variants build and run in single and multiple projects with resources and live hooks"
        ],
        "unverified": [
            "complete reference compatibility",
            "Intel",
            "physical devices",
            "signing",
        ],
    }
    (results_directory() / "native-integration.json").write_text(
        json.dumps(report, indent=2) + "\n"
    )
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    execute(main, "native-integration.json")
