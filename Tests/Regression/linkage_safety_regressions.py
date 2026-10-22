"""Exercise mixed linkage rejection, archive names, compiler overrides and framework signing."""

import json
import platform
import shutil

from Tests.Fixtures.vendor_fixture import fixture_derived_data, run as command, sdk
from Tests.Integration.native_vendor_tests import fixture as vendor_consumer
from Tests.Integration.native_xcconfig_tests import create
from Tests.Regression.consumer_build_regressions import update_spec
from Tests.Regression.input_contract_regressions import diagnostic
from Tests.Regression.lifecycle_audit_regressions import write_project
from Tests.Regression.workspace_resource_regressions import read_project


def consumer(fixture, name):
    work, selected = create(fixture.root / name)
    (work / "Podfile").write_text(
        "platform :osx, '13.0'\nproject '../Apps/External.xcodeproj'\n"
        "target 'Demo' do\n pod 'Kit', :path => './Kit'\nend\n"
    )
    return work, selected


def application(fixture, label):
    return fixture_derived_data(fixture.root / label) / "Build/Products/Debug/Demo.app"


def execute(fixture, work, label):
    return command(
        [application(fixture, label) / "Contents/MacOS/Demo"], work,
        fixture.root / (label + "-run.log"), env=fixture.env,
    )


def static_source_dependencies(fixture):
    for transitive in (False, True):
        name = "mixed-source-" + ("transitive" if transitive else "direct")
        work, selected = consumer(fixture, name)
        state = work / "State"
        state.mkdir()
        (state / "State.m").write_text(
            "#import <Foundation/Foundation.h>\n@interface LinkageState : NSObject\n@end\n"
            "@implementation LinkageState\n@end\nstatic int value = 7;\n"
            "int *state_pointer(void) { return &value; }\n"
        )
        (state / "State.podspec.json").write_text(json.dumps({
            "name": "State", "version": "1.0", "source_files": "State.m", "static_framework": True,
            "frameworks": ["Foundation"], "platforms": {"osx": "13.0"},
        }))
        (work / "Kit/Kit.c").write_text(
            "extern int *state_pointer(void);\nint *kit_pointer(void) { return state_pointer(); }\n"
        )
        (work / "Kit/Kit.h").write_text(
            '#ifdef __cplusplus\nextern "C" {\n#endif\nint *kit_pointer(void);\n'
            "int *state_pointer(void);\n#ifdef __cplusplus\n}\n#endif\n"
        )
        dependency = "State"
        extra = " pod 'State', :path => './State'\n"
        if transitive:
            middle = work / "Middle"
            middle.mkdir()
            (middle / "Middle.c").write_text("int middle_value(void) { return 7; }\n")
            (middle / "Middle.podspec.json").write_text(json.dumps({
                "name": "Middle", "version": "1.0", "source_files": "Middle.c", "dependencies": {"State": []},
            }))
            dependency = "Middle"
            extra += " pod 'Middle', :path => './Middle'\n"
        update_spec(work, dependencies={dependency: []})
        body = (work / "Podfile").read_text().replace("end\n", extra + "end\n")
        (work / "Podfile").write_text("use_frameworks! :linkage => :dynamic\n" + body)
        (selected.parent / "Sources/main.mm").write_text(
            "#include <Kit/Kit.h>\nint main(void) { return kit_pointer() == state_pointer() ? 0 : 42; }\n"
        )
        before = (selected / "project.pbxproj").read_bytes()
        failed = fixture.cli(work, "install", succeeds=False)
        diagnostic(failed, "SP-XCODE-STATIC-DEPENDENCY")
        assert (selected / "project.pbxproj").read_bytes() == before
        assert not (work / "Podfile.lock").exists()
        if failed["project_state"] == "recovery_required":
            fixture.cli(work, "recover")
        else:
            assert failed["project_state"] == "failed_no_managed_changes", failed
        (work / "Podfile").write_text("use_frameworks! :linkage => :static\n" + body)
        fixture.cli(work, "install")
        fixture.cli(work, "install", "--deployment", "--offline")
        label = name + "-build"
        fixture.build(work, "Demo", label)
        output = execute(fixture, work, label)
        assert "implemented in both" not in output, output
        fixture.verified.append("mixed_static_source_rejected_and_static_consumer_executes_" + name)


def archive_product_names(fixture):
    for kind in ("raw", "xcframework"):
        name = "archive-shadow-" + kind
        work, selected = consumer(fixture, name)
        vendor = work / "Vendor"
        vendor.mkdir()
        if kind == "raw":
            archives = ["libVendor.a", "libVendor-SwiftPods.a"]
            for index, filename in enumerate(archives):
                source = vendor / (str(index) + ".c")
                source.write_text(f"int vendor_value_{index}(void) {{ return {index + 3}; }}\n")
                obj = source.with_suffix(".o")
                command(["xcrun", "clang", "-Wall", "-Wextra", "-Werror", "-mmacosx-version-min=13.0",
                         "-c", source, "-o", obj], work, fixture.root / (name + str(index) + "-compile.log"))
                command(["xcrun", "libtool", "-static", "-o", vendor / filename, obj], work,
                        fixture.root / (name + str(index) + "-archive.log"))
            body = ("extern int vendor_value_0(void);\nextern int vendor_value_1(void);\n"
                    "int kit_value(void) { return vendor_value_0() + vendor_value_1(); }\n")
            declaration = archives
        else:
            producer = fixture.root / (name + "-producer")
            producer.mkdir()
            product = sdk(producer, "Vendor", library=True, platforms=("macosx",))
            shutil.copytree(product, vendor / product.name, symlinks=True)
            declaration = [product.name]
            body = "extern int Vendor_value(void);\nint kit_value(void) { return Vendor_value() == 42 ? 7 : 1; }\n"
        (vendor / "Vendor.podspec.json").write_text(json.dumps({
            "name": "Vendor", "version": "1.0", "source_files": [], "vendored_libraries": declaration,
            "platforms": {"osx": "13.0"},
        }))
        (work / "Kit/Kit.c").write_text(body)
        update_spec(work, dependencies={"Vendor": []})
        body = (work / "Podfile").read_text().replace("end\n", " pod 'Vendor', :path => './Vendor'\nend\n")
        (work / "Podfile").write_text("use_frameworks! :linkage => :dynamic\n" + body)
        (selected.parent / "Sources/main.mm").write_text(
            "#include <Kit/Kit.h>\nint main(void) { return kit_value() == 7 ? 0 : 1; }\n"
        )
        fixture.cli(work, "install")
        fixture.cli(work, "install", "--deployment", "--offline")
        objects = read_project(work / "Pods/Pods.xcodeproj")["objects"]
        target = next(obj for obj in objects.values() if obj.get("isa") == "PBXNativeTarget" and obj.get("name") == "Vendor")
        product = objects[target["productReference"]]["path"]
        assert product == ("libVendor-SwiftPods-SwiftPods.a" if kind == "raw" else "libVendor-SwiftPods.a"), product
        label = name + "-build"
        fixture.build(work, "Demo", label)
        execute(fixture, work, label)
        fixture.verified.append("binary_placeholder_does_not_shadow_sdk_" + kind)


def forced_compiler_language(fixture):
    for declared in ("target", "xcconfig", "conditional"):
        name = "forced-language-" + declared
        work, selected = consumer(fixture, name)
        (work / "Kit/Kit.c").unlink()
        (work / "Kit/Kit.cpp").write_text(
            '#include <string>\nextern "C" int kit_value(void) { '
            'std::string value("a non-small string from an archive"); return value.size() > 20 ? 7 : 1; }\n'
        )
        update_spec(work, source_files="*.{cpp,h}", libraries=["c++"])
        (selected.parent / "Sources/main.mm").write_text(
            "extern int kit_value(void);\nint main(void) { return kit_value() == 7 ? 0 : 1; }\n"
        )
        if declared == "target":
            graph = read_project(selected)
            for obj in graph["objects"].values():
                if obj.get("isa") == "XCBuildConfiguration" and obj["buildSettings"].get("PRODUCT_NAME"):
                    obj["buildSettings"]["GCC_INPUT_FILETYPE"] = "sourcecode.c.objc"
            write_project(selected, graph)
        else:
            base = selected.parent / "Configs/Base.xcconfig"
            value = ("GCC_INPUT_FILETYPE = sourcecode.c.objc\n" if declared == "xcconfig" else
                     "FORCED_INPUT = sourcecode.c.objc\nGCC_INPUT_FILETYPE[config=Debug][sdk=macosx*] = $(FORCED_INPUT)\n")
            base.write_text(base.read_text() + value)
        fixture.cli(work, "install")
        fixture.cli(work, "install", "--deployment", "--offline")
        support = work / "Pods/Target Support Files/Pods-Demo"
        assert "-lc++" in (support / "Pods-Demo.debug.xcconfig").read_text()
        assert ("-lc++" in (support / "Pods-Demo.release.xcconfig").read_text()) == (declared != "conditional")
        label = name + "-build"
        fixture.build(work, "Demo", label)
        execute(fixture, work, label)
        fixture.verified.append("forced_compiler_language_keeps_cxx_runtime_" + declared)


def dynamic_library_product_name(fixture):
    name = "dylib-shadow"
    work, selected = consumer(fixture, name)
    vendor = work / "Vendor"
    vendor.mkdir()
    (vendor / "Vendor.c").write_text("int vendor_value(void) { return 7; }\n")
    command(["xcrun", "clang", "-Wall", "-Wextra", "-Werror", "-mmacosx-version-min=13.0", "-dynamiclib",
             vendor / "Vendor.c", "-install_name", "@rpath/libvendor.dylib", "-o", vendor / "libvendor.dylib"],
            work, fixture.root / (name + "-compile.log"))
    (vendor / "Vendor.podspec.json").write_text(json.dumps({
        "name": "Vendor", "version": "1.0", "source_files": [], "vendored_libraries": "libvendor.dylib",
        "platforms": {"osx": "13.0"},
    }))
    (work / "Kit/Kit.c").write_text("extern int vendor_value(void);\nint kit_value(void) { return vendor_value(); }\n")
    update_spec(work, dependencies={"Vendor": []})
    body = (work / "Podfile").read_text().replace("end\n", " pod 'Vendor', :path => './Vendor'\nend\n")
    (work / "Podfile").write_text("use_frameworks! :linkage => :dynamic\n" + body)
    (selected.parent / "Sources/main.mm").write_text(
        "#include <Kit/Kit.h>\nint main(void) { return kit_value() == 7 ? 0 : 1; }\n"
    )
    fixture.cli(work, "install")
    fixture.cli(work, "install", "--deployment", "--offline")
    objects = read_project(work / "Pods/Pods.xcodeproj")["objects"]
    target = next(obj for obj in objects.values() if obj.get("isa") == "PBXNativeTarget" and obj.get("name") == "Vendor")
    assert objects[target["productReference"]]["path"] == "libVendor-SwiftPods.a"
    label = name + "-build"
    fixture.build(work, "Demo", label)
    execute(fixture, work, label)
    fixture.verified.append("binary_placeholder_does_not_shadow_dylib_with_case_variant_name")


def versioned_framework_signing(fixture):
    base = fixture.root / "versioned-frameworks"
    base.mkdir()
    product = sdk(base, "VendorDynamic", dynamic=True, platforms=("macosx",))
    for raw in (False, True):
        name = "versioned-framework-" + ("raw" if raw else "xcframework")
        parent = base / name
        parent.mkdir()
        work = vendor_consumer(parent, [("VendorDynamic", product, False)], "osx", raw=raw)
        fixture.cli(work, "install")
        label = name + "-build"
        fixture.build(work, "Demo", label)
        app = application(fixture, label)
        framework = app / "Contents/Frameworks/VendorDynamic.framework"
        script = next((work / "Pods/Target Support Files/Pods-Demo").glob("*-frameworks.sh"))
        env = {
            **fixture.env, "PODS_ROOT": str(work / "Pods"), "PODS_PODFILE_DIR_PATH": str(work),
            "TARGET_BUILD_DIR": str(app.parent), "BUILT_PRODUCTS_DIR": str(app.parent),
            "PODS_CONFIGURATION_BUILD_DIR": str(app.parent),
            "FRAMEWORKS_FOLDER_PATH": "Demo.app/Contents/Frameworks", "CONFIGURATION": "Debug",
            "DERIVED_FILE_DIR": str(parent / "script-outputs"), "ARCHS": platform.machine(),
            "CODE_SIGNING_ALLOWED": "YES", "EXPANDED_CODE_SIGN_IDENTITY": "-",
        }
        command(["/bin/sh", script], work, parent / "embed-sign.log", env=env)
        assert (framework / "VendorDynamic").is_symlink()
        assert (framework / "Versions/Current").is_symlink()
        architectures = command(["xcrun", "lipo", "-archs", framework / "Versions/A/VendorDynamic"],
                                work, parent / "archs.log").split()
        assert architectures == [platform.machine()], architectures
        command(["codesign", "--verify", "--strict", framework], work, parent / "verify-sign.log")
        execute(fixture, work, label)
        fixture.verified.append("versioned_framework_thinning_preserves_symlinks_and_signs_" + name)


def run(fixture):
    static_source_dependencies(fixture)
    archive_product_names(fixture)
    dynamic_library_product_name(fixture)
    forced_compiler_language(fixture)
    versioned_framework_signing(fixture)
