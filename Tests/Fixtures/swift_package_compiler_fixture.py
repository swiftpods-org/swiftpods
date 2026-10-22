"""A package linked once by an app and imported by two static consumers."""

import copy
import hashlib
import json

from Tests.Integration.native_integration import project
from Tests.Regression.input_contract_regressions import commit, git
from Tests.Regression.lifecycle_audit_regressions import write_project
from Tests.Regression.workspace_resource_regressions import read_project


def identifiers(value, mapping):
    if isinstance(value, dict):
        return {
            mapping.get(key, key): identifiers(item, mapping)
            for key, item in value.items()
        }
    if isinstance(value, list):
        return [identifiers(item, mapping) for item in value]
    return mapping.get(value, value)


def c_header(body):
    return (
        '#pragma once\n#ifdef __cplusplus\nextern "C" {\n#endif\n'
        + body
        + "\n#ifdef __cplusplus\n}\n#endif\n"
    )


def create(root):
    helper = root / "DependencyRepository"
    (helper / "Sources/RemoteCore/include").mkdir(parents=True)
    (helper / "Package.swift").write_text("""// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "RemoteMetadata", platforms: [.macOS(.v13), .iOS(.v15)],
    products: [.library(name: "DependencyAPI", targets: ["RemoteCore"])],
    targets: [.target(name: "RemoteCore")])
""")
    (helper / "Sources/RemoteCore/include/RemoteAPI.h").write_text(
        c_header("int remote_value(void);\n")
    )
    (helper / "Sources/RemoteCore/Remote.c").write_text(
        "int remote_value(void) { return 0; }\n"
    )
    git(helper, "init", "-b", "main")
    commit(helper, "Remote dependency")
    git(helper, "tag", "1.0.0")
    origin = root / "SourceSDK"
    for name, headers in [
        ("Interface", "Public"),
        ("Transitive", "include"),
        ("Unused", "include"),
    ]:
        (origin / "Sources" / name / headers).mkdir(parents=True)
    (origin / "Package.swift").write_text(
        """// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "SourceSDK", platforms: [.macOS(.v13), .iOS(.v15)],
    products: [.library(name: "SourceSDK", targets: ["Interface", "SwiftBridge"]),
        .library(name: "ExtraAPI", targets: ["Unused"])],
    dependencies: [.package(url: "DEPENDENCY_URL", exact: "1.0.0")],
    targets: [
        .target(name: "SwiftBridge"),
        .target(name: "Unused"),
        .target(name: "Transitive"),
        .target(name: "Interface", dependencies: ["Transitive",
            .product(name: "DependencyAPI", package: "dependencyrepository", condition: .when(platforms: [.macOS]))], publicHeadersPath: "Public"),
    ])
""".replace("DEPENDENCY_URL", helper.as_uri())
    )
    (origin / "Sources/Interface/Public/Interface.h").write_text(
        c_header("int *sdk_pointer(void);\nint sdk_value(void);\n")
    )
    (origin / "Sources/Unused/include/Unused.h").write_text(
        c_header("int unused_value(void);\n")
    )
    (origin / "Sources/Unused/Unused.c").write_text(
        "int unused_value(void) { return 0; }\n"
    )
    (origin / "Sources/Interface/Public/module.modulemap").write_text(
        'module Interface { header "Interface.h" export * }\n'
    )
    (origin / "Sources/Interface/Interface.c").write_text(
        '#include "Interface.h"\n#include "Transitive.h"\n#include <TargetConditionals.h>\n'
        "#if TARGET_OS_OSX\n#include <RemoteAPI.h>\n#define REMOTE_VALUE remote_value()\n#else\n#define REMOTE_VALUE 0\n#endif\n"
        "static int value = 7;\nint *sdk_pointer(void) { return &value; }\n"
        "int sdk_value(void) { return transitive_value() + REMOTE_VALUE; }\n"
    )
    (origin / "Sources/Transitive/include/Transitive.h").write_text(
        c_header(
            "typedef struct { int value; } TransitiveState;\nint transitive_value(void);\n"
        )
    )
    (origin / "Sources/Transitive/Transitive.c").write_text(
        '#include "Transitive.h"\nint transitive_value(void) { return 17; }\n'
    )
    (origin / "Sources/SwiftBridge").mkdir()
    (origin / "Sources/SwiftBridge/Bridge.swift").write_text(
        "import Foundation\n@objc public final class BridgeValue: NSObject {\n"
        "    @objc public static func number() -> Int { 0 }\n}\n"
    )
    git(origin, "init", "-b", "main")
    commit(origin, "Source SDK")
    git(origin, "tag", "1.0.0")
    work = root / "Consumer With Spaces"
    (work / "Sources").mkdir(parents=True)
    selected = work / "Demo.xcodeproj"
    project(selected)
    graph = read_project(selected)
    names = [
        "PROJ",
        "GROUP",
        "PRODUCTS",
        "MAIN",
        "PRODUCT",
        "BUILD",
        "SOURCES",
        "FRAMEWORKS",
        "TARGET",
    ]
    names += [
        prefix + suffix
        for prefix in ["PROJECT_", "TARGET_"]
        for suffix in ["Debug", "Release", "CONFIGS"]
    ]
    graph = identifiers(
        graph,
        {
            hashlib.sha256(name.encode()).hexdigest()[:24].upper(): name
            for name in names
        },
    )
    objects = graph["objects"]
    for name in ["Alpha", "Beta"]:
        target, product, source, build, sources, frameworks, configs = [
            name + "_" + suffix
            for suffix in [
                "TARGET",
                "PRODUCT",
                "SOURCE",
                "BUILD",
                "SOURCES",
                "FRAMEWORKS",
                "CONFIGS",
            ]
        ]
        objects[product] = {
            "isa": "PBXFileReference",
            "path": "lib" + name + ".a",
            "sourceTree": "BUILT_PRODUCTS_DIR",
            "explicitFileType": "archive.ar",
        }
        extension = ".m" if name == "Alpha" else ".mm"
        objects[source] = {
            "isa": "PBXFileReference",
            "path": "Sources/" + name + extension,
            "sourceTree": "<group>",
            "lastKnownFileType": "sourcecode.c.objc"
            if name == "Alpha"
            else "sourcecode.cpp.objcpp",
        }
        objects[build] = {"isa": "PBXBuildFile", "fileRef": source}
        objects[sources] = dict(objects["SOURCES"], files=[build])
        objects[frameworks] = dict(objects["FRAMEWORKS"], files=[])
        objects[target] = dict(
            objects["TARGET"],
            name=name,
            productName=name,
            productReference=product,
            productType="com.apple.product-type.library.static",
            buildConfigurationList=configs,
            buildPhases=[sources, frameworks],
            dependencies=[],
        )
        configuration_ids = []
        for configuration in ["Debug", "Release"]:
            identifier = name + "_" + configuration
            configuration_ids.append(identifier)
            objects[identifier] = copy.deepcopy(objects["TARGET_" + configuration])
            settings = objects[identifier]["buildSettings"]
            settings.update(
                PRODUCT_NAME=name,
                SKIP_INSTALL="YES",
                CLANG_ENABLE_MODULES="YES",
                OTHER_CFLAGS=["$(inherited)", "-DFIXTURE_COMPILER_FLAG=1"],
                HEADER_SEARCH_PATHS=["$(inherited)", '"$(SRCROOT)/User Headers"'],
            )
            if name == "Beta":
                settings["OTHER_CPLUSPLUSFLAGS"] = [
                    "-DFIXTURE_CPP_FLAG=1",
                    "-fmodules",
                    "-fcxx-modules",
                ]
            else:
                settings["OTHER_SWIFT_FLAGS"] = ["-DFIXTURE_SWIFT_FLAG"]
        objects[configs] = dict(
            objects["TARGET_CONFIGS"], buildConfigurations=configuration_ids
        )
        objects["PROJ"]["targets"].append(target)
        objects["PRODUCTS"]["children"].append(product)
        objects["GROUP"]["children"].append(source)
        dependency = name + "_DEPENDENCY"
        objects[dependency] = {"isa": "PBXTargetDependency", "target": target}
        objects["TARGET"]["dependencies"].append(dependency)
        link = name + "_LINK"
        objects[link] = {"isa": "PBXBuildFile", "fileRef": product}
        objects["FRAMEWORKS"]["files"].append(link)
        (work / "Sources" / (name + extension)).write_text(
            '#include "User.h"\n#include <TargetConditionals.h>\n#include <Interface.h>\n#include <Transitive.h>\n'
            "#if TARGET_OS_OSX\n#include <RemoteAPI.h>\n@import RemoteCore;\n#endif\n"
            "@import Interface;\n@import Transitive;\n@import SwiftBridge;\n"
            "#if FIXTURE_USER_HEADER != 9\n#error User_header_lost\n#endif\n"
            '#ifdef __cplusplus\n#if FIXTURE_CPP_FLAG != 1\n#error User_CPP_flags_lost\n#endif\nextern "C" {\n'
            "#elif FIXTURE_COMPILER_FLAG != 1\n#error User_C_flags_lost\n#endif\n"
            + "int *"
            + name.lower()
            + "_pointer(void) { return sdk_pointer(); }\n"
            + "int "
            + name.lower()
            + "_value(void) { return sdk_value() + transitive_value() + (int)[BridgeValue number]; }\n"
            + "#ifdef __cplusplus\n}\n#endif\n"
        )
    objects["ALPHA_SWIFT"] = {
        "isa": "PBXFileReference",
        "path": "Sources/AlphaSwift.swift",
        "sourceTree": "<group>",
        "lastKnownFileType": "sourcecode.swift",
    }
    objects["ALPHA_SWIFT_BUILD"] = {
        "isa": "PBXBuildFile",
        "fileRef": "ALPHA_SWIFT",
    }
    objects["Alpha_SOURCES"]["files"].append("ALPHA_SWIFT_BUILD")
    objects["GROUP"]["children"].append("ALPHA_SWIFT")
    (work / "Sources/AlphaSwift.swift").write_text(
        "import Interface\nimport Transitive\nimport SwiftBridge\n"
        '#if !FIXTURE_SWIFT_FLAG\n#error("User Swift flags lost")\n#endif\n'
        '@_cdecl("alpha_swift_value")\npublic func alpha_swift_value() -> Int32 {\n'
        "    sdk_value() + transitive_value() + Int32(BridgeValue.number())\n}\n"
    )
    (work / "User Headers").mkdir()
    (work / "User Headers/User.h").write_text("#define FIXTURE_USER_HEADER 9\n")
    for item in objects.values():
        if (
            item.get("isa") == "XCBuildConfiguration"
            and item["buildSettings"].get("PRODUCT_NAME") == "Demo"
        ):
            item["buildSettings"].update(OTHER_LDFLAGS=["$(inherited)", "-all_load"])
    (work / "Sources/main.mm").write_text(
        'extern "C" {\nint *alpha_pointer(void);\nint *beta_pointer(void);\n'
        "int alpha_value(void);\nint beta_value(void);\nint alpha_swift_value(void);\nint *sdk_pointer(void);\n}\n"
        "int main(void) { return alpha_pointer() == sdk_pointer() && beta_pointer() == sdk_pointer()"
        " && alpha_value() == 34 && beta_value() == 34 && alpha_swift_value() == 34 ? 0 : 1; }\n"
    )
    graph = identifiers(
        graph,
        {key: hashlib.sha256(key.encode()).hexdigest()[:24].upper() for key in objects},
    )
    write_project(selected, graph)
    scheme = selected / "xcshareddata/xcschemes/SDK Owner.xcscheme"
    scheme.parent.mkdir(parents=True)
    owner = next(
        key
        for key, value in graph["objects"].items()
        if value.get("isa") == "PBXNativeTarget" and value.get("name") == "Demo"
    )
    scheme.write_text(
        '<?xml version="1.0" encoding="UTF-8"?>\n<Scheme version="1.7"><BuildAction><BuildActionEntries>'
        '<BuildActionEntry buildForRunning="YES" buildForTesting="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">'
        '<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="'
        + owner
        + '" '
        'BuildableName="Demo.app" BlueprintName="Demo" ReferencedContainer="container:Demo.xcodeproj"/>'
        "</BuildActionEntry></BuildActionEntries></BuildAction></Scheme>\n"
    )
    (work / "Podfile").write_text(
        "platform :osx, '13.0'\nproject 'Demo.xcodeproj'\ntarget 'Demo' do\n"
        " spm 'SDK', :git => "
        + json.dumps(origin.as_uri())
        + ", :exact => '1.0.0', :products => ['SourceSDK']\n"
        " target 'Alpha' do\n  inherit! :search_paths\n end\n"
        " target 'Beta' do\n  inherit! :search_paths\n end\nend\n"
    )
    return work, selected, origin
