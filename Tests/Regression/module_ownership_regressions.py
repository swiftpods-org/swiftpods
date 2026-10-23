"""Consumer module ownership follows custom maps and selected binary interfaces."""

import json
import shutil

from Tests.Fixtures.vendor_fixture import sdk
from Tests.Regression.header_namespace_regressions import module_fixture
from Tests.Regression.project_path_regressions import builds


def custom_map_fixture(parent, *, collision=False, shared_alias=False, nested=False):
    work, selected = module_fixture(parent, collision=shared_alias)
    names = ["Shared", "Shared"] if collision else ["FirstModule", "SecondModule"]
    if nested:
        names[1] = "Shared"
    for pod, module in zip(["Kit", "Other"], names):
        spec = work / pod / (pod + ".podspec.json")
        attributes = json.loads(spec.read_text())
        attributes["module_map"] = "Author.modulemap"
        spec.write_text(json.dumps(attributes))
        contents = "module " + module + ' { header "' + pod + '.h" export *'
        if nested and pod == "Kit":
            contents = (
                "// module Shared {}\n"
                + contents
                + " explicit module Shared { export * }"
            )
        (work / pod / "Author.modulemap").write_text(contents + " }\n")
    imports = "".join("@import " + name + ";\n" for name in dict.fromkeys(names))
    (selected.parent / "Sources/main.m").write_text(
        imports
        + "#if KIT_A != 11 || KIT_B != 31\n#error Module API was lost\n#endif\n"
        + "int main(void) { return 0; }\n"
    )
    return work, selected


def source_vendor_fixture(parent, *, collision=False):
    work, selected = module_fixture(parent, collision=False)
    binary = sdk(parent, "NativeSDK", platforms=("macosx",))
    shutil.copytree(binary, work / "Other/NativeSDK.xcframework", symlinks=True)
    spec = work / "Other/Other.podspec.json"
    attributes = json.loads(spec.read_text())
    attributes.update(source_files=[], vendored_frameworks="NativeSDK.xcframework")
    spec.write_text(json.dumps(attributes))
    spec = work / "Kit/Kit.podspec.json"
    attributes = json.loads(spec.read_text())
    attributes["module_name"] = "NativeSDK" if collision else "SourceModule"
    spec.write_text(json.dumps(attributes))
    (selected.parent / "Sources/main.m").write_text(
        ("@import NativeSDK;\n" if collision else "@import SourceModule;\n@import NativeSDK;\n")
        + "#if KIT_A != 11 || NativeSDK_EXPECTED != 42\n#error Module API was lost\n#endif\n"
        + "int main(void) { return 0; }\n"
    )
    return work, selected


def reject_conflict(fixture, create, label):
    work, selected = create(fixture.root / label, collision=True)
    before = (selected / "project.pbxproj").read_bytes()
    rejected = fixture.cli(work, "install", succeeds=False)
    assert any(
        e.get("code") == "SP-XCODE-MODULE-CONFLICT" for e in rejected["events"]
    ), rejected
    assert (selected / "project.pbxproj").read_bytes() == before
    assert not (work / "Podfile.lock").exists()
    fixture.verified.append(label + "_rejected_before_consumer_write")


def supported(fixture, create, label, **options):
    work, selected = create(fixture.root / label, **options)
    paths = list(work.glob("*/*.podspec.json")) + list(work.glob("*/Author.modulemap"))
    authored = {path: path.read_bytes() for path in paths}
    fixture.cli(work, "install")
    before = (selected / "project.pbxproj").read_bytes()
    lock = (work / "Podfile.lock").read_bytes()
    fixture.cli(work, "install", "--offline", "--deployment")
    assert (selected / "project.pbxproj").read_bytes() == before
    assert (work / "Podfile.lock").read_bytes() == lock
    assert all(path.read_bytes() == contents for path, contents in authored.items())
    builds(fixture, work, label)
    fixture.verified.append(label + "_builds_runs_debug_release_and_reinstalls")


def run_regressions(fixture):
    cases = [
        ("custom-map-conflict", custom_map_fixture, True, {}),
        ("custom-map-unused-alias", custom_map_fixture, False, {"shared_alias": True}),
        ("custom-map-distinct", custom_map_fixture, False, {}),
        ("custom-map-nested", custom_map_fixture, False, {"nested": True}),
        ("source-vendor-conflict", source_vendor_fixture, True, {}),
        ("source-vendor-distinct", source_vendor_fixture, False, {}),
    ]
    results = []
    for name, create, reject, options in cases:
        print("Module ownership:", name, flush=True)
        try:
            if reject:
                reject_conflict(fixture, create, name)
            else:
                supported(fixture, create, name, **options)
            results.append({"case": name, "status": "passed"})
        except (AssertionError, RuntimeError) as error:
            results.append({"case": name, "status": "failed", "error": str(error)})
    (fixture.root / "module-ownership.json").write_text(json.dumps(results, indent=2) + "\n")
    failed = [row["case"] for row in results if row["status"] == "failed"]
    assert not failed, "Module ownership failures: " + ", ".join(failed)


def main():
    from scripts.support.local_build import results_directory
    from Tests.Integration.native_lifecycle_tests import LifecycleFixture

    fixture = LifecycleFixture()
    print("Module ownership fixtures:", fixture.root, flush=True)
    run_regressions(fixture)
    (results_directory() / "native-module-ownership.json").write_text(
        json.dumps(
            {"status": "passed", "fixture": str(fixture.root), "verified": fixture.verified},
            indent=2,
        ) + "\n"
    )


if __name__ == "__main__":
    from scripts.support.reporting import execute

    execute(main, "native-module-ownership.json")
