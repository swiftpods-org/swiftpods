#!/usr/bin/env python3
"""Exercise the Swift engine with no reference engine or runtime gems on its path."""

import json
import shutil
import subprocess
import tempfile
from pathlib import Path

from bootstrap import ROOT, environment
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


def project(path, platform="osx"):
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


def exercise(variant):
    base = ROOT / ".build/native-integration"
    base.mkdir(exist_ok=True)
    fixture = Path(tempfile.mkdtemp(prefix="run-", dir=base))
    shutil.copytree(ROOT / "Tests/Fixtures/MixedLanguages", fixture / "project")
    work = fixture / "project"
    podfile = work / "Podfile"
    text = podfile.read_text()
    if variant == "dynamic-framework":
        text = text.replace(":linkage => :static", ":linkage => :dynamic")
    if variant == "static-library":
        text = text.replace("use_frameworks! :linkage => :static\n", "")
    podfile.write_text(text)
    if variant == "dynamic-framework":
        shutil.copy2(
            ROOT / "Tests/Fixtures/iOS/GameCoreIntent.swift",
            work / "Modules/GameCore/Sources/FixtureIntent.swift",
        )
    project(work / "Demo.xcodeproj")
    env = environment()
    env["SWIFTPODS_CACHE_ROOT"] = str(fixture / "cache")
    env["GEM_HOME"] = str(fixture / "no-global-gems")
    env["GEM_PATH"] = env["GEM_HOME"]
    cli = ROOT / ".build/debug/swiftpods"

    def run(*args, success=True):
        result = subprocess.run(
            [str(cli), *args, "--json"],
            cwd=work,
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

    installed = run("install")
    assert installed["exit_status"] == 0
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
    run("install", "--deployment", "--offline")
    assert (work / "Podfile.lock").read_bytes() == original_lock
    graph = run("graph")
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
    app = fixture / "DerivedData/Build/Products/Debug/Demo.app/Contents/MacOS/Demo"
    result = subprocess.check_output([str(app)], cwd=work, text=True)
    assert "mixed=15 resources=ok privacy=ok" in result, result
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
            "four live Ruby hooks",
            "hook build settings",
            "deployment/offline reinstall",
            "graph and why freshness",
            "external engine load rejected",
        ],
        "variant": variant,
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
        exercise(variant)
        for variant in ("static-framework", "dynamic-framework", "static-library")
    ]
    report = {
        "status": "passed",
        "engine": "swift",
        "scenarios": scenarios,
        "verified": [
            "three native linkage variants build and run with resources and live hooks"
        ],
        "unverified": [
            "complete reference compatibility",
            "Intel",
            "physical devices",
            "signing",
        ],
    }
    (ROOT / "test-results/native-integration.json").write_text(
        json.dumps(report, indent=2) + "\n"
    )
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    execute(main, "native-integration.json")
