"""Own manifests and project fixture shared by native/reference phase tests."""

import json
import subprocess

from Tests.Integration.native_integration import project, serialize


def ruby(value):
    if value is None:
        return "nil"
    if isinstance(value, dict):
        return (
            "{"
            + ", ".join(ruby(key) + " => " + ruby(item) for key, item in value.items())
            + "}"
        )
    if isinstance(value, list):
        return "[" + ", ".join(map(ruby, value)) + "]"
    return json.dumps(value)


def ruby_phase(value):
    return (
        "{"
        + ", ".join(
            ":"
            + key
            + " => "
            + (":" + item if key == "execution_position" else ruby(item))
            for key, item in value.items()
        )
        + "}"
    )


def stamp(name, position, inputs=None, always=False):
    result = {
        "name": name,
        "execution_position": position,
        "show_env_vars_in_log": "0",
        "script": 'set -eu\nprintf "' + name + '\\n" >> "${SCRIPT_OUTPUT_FILE_0}"\n',
        "input_files": inputs or [],
        "output_files": [
            "$(BUILD_DIR)/$(CONFIGURATION)$(EFFECTIVE_PLATFORM_NAME)/phase-"
            + name
            + ".txt"
        ],
    }
    if always:
        result["always_out_of_date"] = "1"
    return result


def specification():
    generator = {
        "name": "generate",
        "execution_position": "before_compile",
        "shell_path": "/bin/bash",
        "show_env_vars_in_log": "0",
        "input_file_lists": ["$(PODS_TARGET_SRCROOT)/inputs.xcfilelist"],
        "output_file_lists": ["$(PODS_TARGET_SRCROOT)/outputs.xcfilelist"],
        "output_files": [
            "$(BUILD_DIR)/$(CONFIGURATION)$(EFFECTIVE_PLATFORM_NAME)/phase-generate.txt"
        ],
        "dependency_file": "$(DERIVED_FILE_DIR)/generate.d",
        "script": """set -eu
value=$(cat "${PODS_TARGET_SRCROOT}/input value.txt")
printf '#define SCRIPT_VALUE %s\\n' "$value" > "${DERIVED_FILE_DIR}/Generated.h"
printf '%s:\\n' "${DERIVED_FILE_DIR}/Generated.h" > "${DERIVED_FILE_DIR}/generate.d"
printf 'generate\\n' >> "${SCRIPT_OUTPUT_FILE_0}"
""",
    }
    after = stamp(
        "after-compile",
        "after_compile",
        [
            "$(DERIVED_FILE_DIR)/Generated.h",
            "$(BUILD_DIR)/$(CONFIGURATION)$(EFFECTIVE_PLATFORM_NAME)/phase-after-headers.txt",
            "$(OBJECT_FILE_DIR_normal)",
        ],
    )
    after["script"] = (
        'set -eu\ntest -n "$(/usr/bin/find "${OBJECT_FILE_DIR_normal}" -name ScriptKit.o -print)"\n'
        + after["script"]
    )
    return {
        "name": "ScriptKit",
        "version": "1.0.0",
        "summary": "Native script phase fixture",
        "homepage": "https://swiftpods.org",
        "license": "MIT",
        "author": "SwiftPods Tests",
        "source": {"git": "https://example.invalid/script.git", "tag": "1.0.0"},
        "script_phase": generator,
        "default_subspecs": ["Core"],
        "osx": {
            "deployment_target": "13.0",
            "script_phases": [
                stamp("before-headers", "before_headers"),
                stamp(
                    "after-headers",
                    "after_headers",
                    ["$(DERIVED_FILE_DIR)/Generated.h"],
                ),
            ],
        },
        "pod_target_xcconfig": {
            "HEADER_SEARCH_PATHS": ["$(inherited)", "$(DERIVED_FILE_DIR)"],
            "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
        },
        "subspecs": [
            {
                "name": "Core",
                "source_files": "*.{h,m}",
                "public_header_files": "ScriptKit.h",
                "script_phases": [
                    after,
                    stamp(
                        "any",
                        "any",
                        [
                            "$(BUILD_DIR)/$(CONFIGURATION)$(EFFECTIVE_PLATFORM_NAME)/phase-after-compile.txt"
                        ],
                        always=True,
                    ),
                ],
            }
        ],
    }


def write_spec(module, data):
    lines = ["Pod::Spec.new do |s|"]
    for key, value in data.items():
        if key == "osx":
            for attribute, item in value.items():
                lines.append("  s.osx." + attribute + " = " + ruby(item))
        elif key == "subspecs":
            for child in value:
                lines.append("  s.subspec " + ruby(child["name"]) + " do |sub|")
                lines += [
                    "    sub." + attribute + " = " + ruby(item)
                    for attribute, item in child.items()
                    if attribute != "name"
                ]
                lines.append("  end")
        else:
            lines.append("  s." + key + " = " + ruby(value))
    lines.append("end")
    module.joinpath("ScriptKit.podspec").write_text("\n".join(lines) + "\n")


def podfile(work, linkage, scripts=True):
    text = "platform :osx, '13.0'\nproject 'Demo.xcodeproj'\n"
    if linkage:
        text += "use_frameworks! :linkage => :" + linkage + "\n"
    text += "target 'Demo' do\n  pod 'ScriptKit', :path => './Modules/ScriptKit'\n"
    if scripts:
        text += (
            "  script_phase("
            + ruby_phase(
                {
                    "name": "app",
                    "execution_position": "before_compile",
                    "input_files": [
                        "$(BUILD_DIR)/$(CONFIGURATION)$(EFFECTIVE_PLATFORM_NAME)/phase-any.txt"
                    ],
                    "output_files": [
                        "$(BUILD_DIR)/$(CONFIGURATION)$(EFFECTIVE_PLATFORM_NAME)/app-check.txt"
                    ],
                    "show_env_vars_in_log": "0",
                    "script": """set -eu
grep -q '^any$' "${SCRIPT_INPUT_FILE_0}"
printf 'app\\n' >> "${SCRIPT_OUTPUT_FILE_0}"
""",
                }
            )
            + ")\n"
        )
    text += "end\n"
    work.joinpath("Podfile").write_text(text)


def create(work, linkage="static"):
    work.mkdir()
    module = work / "Modules/ScriptKit"
    module.mkdir(parents=True)
    work.joinpath("Sources").mkdir()
    work.joinpath("Sources/main.mm").write_text(
        '#include <stdio.h>\n#include <ScriptKit/ScriptKit.h>\nint main(void) { printf("script-value=%d\\n", scriptkit_value()); return 0; }\n'
    )
    module.joinpath("ScriptKit.h").write_text(
        '#ifdef __cplusplus\nextern "C" {\n#endif\nint scriptkit_value(void);\n#ifdef __cplusplus\n}\n#endif\n'
    )
    module.joinpath("ScriptKit.m").write_text(
        '#import "ScriptKit.h"\n#import "Generated.h"\nint scriptkit_value(void) { return SCRIPT_VALUE; }\n'
    )
    module.joinpath("input value.txt").write_text("41\n")
    module.joinpath("inputs.xcfilelist").write_text(
        "$(PODS_TARGET_SRCROOT)/input value.txt\n$(BUILD_DIR)/$(CONFIGURATION)$(EFFECTIVE_PLATFORM_NAME)/phase-before-headers.txt\n"
    )
    module.joinpath("outputs.xcfilelist").write_text(
        "$(DERIVED_FILE_DIR)/Generated.h\n"
    )
    write_spec(module, specification())
    podfile(work, linkage)
    project(work / "Demo.xcodeproj")
    path = work / "Demo.xcodeproj/project.pbxproj"
    graph = json.loads(
        subprocess.check_output(["plutil", "-convert", "json", "-o", "-", str(path)])
    )
    target = next(
        item for item in graph["objects"].values() if item["isa"] == "PBXNativeTarget"
    )
    original = "111111111111111111111111"
    graph["objects"][original] = {
        "isa": "PBXShellScriptBuildPhase",
        "name": "Original User Script",
        "files": [],
        "shellPath": "/bin/sh",
        "shellScript": 'set -eu\nprintf "original\\n" >> "${SCRIPT_OUTPUT_FILE_0}"\n',
        "inputPaths": ["$(SRCROOT)/Sources/main.mm"],
        "outputPaths": [
            "$(BUILD_DIR)/$(CONFIGURATION)$(EFFECTIVE_PLATFORM_NAME)/original.txt"
        ],
        "showEnvVarsInLog": "0",
        "buildActionMask": "2147483647",
        "runOnlyForDeploymentPostprocessing": "0",
    }
    target["buildPhases"].append(original)
    for item in graph["objects"].values():
        if item["isa"] == "XCBuildConfiguration":
            item["buildSettings"]["ENABLE_USER_SCRIPT_SANDBOXING"] = "YES"
            item["buildSettings"]["ALWAYS_SEARCH_USER_PATHS"] = "NO"
    path.write_text("// !$*UTF8*$!\n" + serialize(graph))
    return module


def phase_graph(path, target):
    graph = json.loads(
        subprocess.check_output(["plutil", "-convert", "json", "-o", "-", str(path)])
    )
    item = next(
        item
        for item in graph["objects"].values()
        if item["isa"] == "PBXNativeTarget" and item["name"] == target
    )
    return [graph["objects"][identifier] for identifier in item["buildPhases"]]


def canonical(path, target):
    result = []
    fields = [
        "shellScript",
        "shellPath",
        "inputPaths",
        "outputPaths",
        "inputFileListPaths",
        "outputFileListPaths",
        "dependencyFile",
        "alwaysOutOfDate",
        "showEnvVarsInLog",
    ]
    for phase in phase_graph(path, target):
        if phase["isa"] in ["PBXSourcesBuildPhase", "PBXHeadersBuildPhase"]:
            result.append(phase["isa"])
        elif phase.get("name", "").startswith("[CP-User] "):
            result.append(
                {
                    "name": phase["name"],
                    **{
                        field: phase.get(
                            field,
                            []
                            if field.endswith("Paths")
                            else ("1" if field == "showEnvVarsInLog" else None),
                        )
                        for field in fields
                    },
                }
            )
    return result
