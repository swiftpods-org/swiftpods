"""Validate package declarations and build a consumer of a real local Swift package."""

import subprocess

from consumer_build_regressions import podfile
from header_ownership_regressions import resources_in_app
from input_contract_regressions import commit, git
from native_xcconfig_tests import create
from script_phase_fixture import ruby
from workspace_resource_regressions import read_project


def manifest(work, options, url="https://example.invalid/Net.git", base=None):
    text = (podfile(work) if base is None else base).replace(
        "target 'Demo' do\n",
        "target 'Demo' do\n spm 'Net', " + ruby(dict(git=url, **options)) + "\n",
    )
    (work / "Podfile").write_text(text)
    return text


def package_objects(project):
    objects = read_project(project)["objects"]
    return (
        [
            value
            for value in objects.values()
            if value.get("isa") == "XCRemoteSwiftPackageReference"
        ],
        [
            value
            for value in objects.values()
            if value.get("isa") == "XCSwiftPackageProductDependency"
        ],
    )


def invalid_inputs(fixture):
    cases = [
        {"exact": "1.0.0", "products": [42]},
        {"exact": "1.0.0", "products": ["Net", 42]},
        {"exact": True, "products": ["Net"]},
        {"from": 1.0, "products": ["Net"]},
        {"branch": True, "products": ["Net"]},
        {"revision": 42, "products": ["Net"]},
        {"exact": "1.0.0", "products": ["Net"], "unknown": True},
        {"range": ["2.0.0", "1.0.0"], "products": ["Net"]},
        {"range": ["1.0.0+a", "1.0.0+b"], "products": ["Net"]},
        {"exact": "1.0", "products": ["Net"]},
        {"exact": "1.0.0", "products": [""]},
    ]
    for index, options in enumerate(cases):
        work, project = create(fixture.root / ("package-invalid-" + str(index)))
        text = manifest(work, options)
        (work / "Podfile").write_text(
            text + "pre_install { |_| File.write('hook-ran', 'yes') }\n"
        )
        before = (project / "project.pbxproj").read_bytes()
        report = fixture.cli(work, "install", succeeds=False)
        assert any(
            event.get("code", "").startswith("SP-SPM-") for event in report["events"]
        ), report
        assert report["project_state"] == "failed_no_managed_changes", report
        assert not (work / "hook-ran").exists()
        assert not (work / "Podfile.lock").exists()
        assert not (work / "Pods/Pods.xcodeproj").exists()
        assert (project / "project.pbxproj").read_bytes() == before
    fixture.verified.append(
        "swift_package_invalid_types_options_and_ranges_fail_before_hooks_and_managed_writes"
    )


def package_only_lifecycle(fixture):
    work, project = create(fixture.root / "package-only")
    original = podfile(work)
    resolved = work / "External.xcworkspace/xcshareddata/swiftpm/Package.resolved"
    resolved.parent.mkdir(parents=True)
    contents = b'{"pins": [], "version": 3}\n'
    resolved.write_bytes(contents)
    for options, count in [
        ({"exact": "1.0.0"}, 0),
        ({"exact": "2.0.0", "products": None}, 0),
        ({"exact": None, "branch": "main", "products": []}, 0),
        ({"exact": "1.0.0", "products": "Net"}, 1),
        ({"exact": "1.0.0", "products": []}, 0),
    ]:
        manifest(work, options, base=original)
        fixture.cli(work, "install")
        packages, products = package_objects(project)
        assert len(packages) == 1 and len(products) == count, (packages, products)
        locked = (work / "Podfile.lock").read_bytes()
        fixture.cli(work, "install", "--deployment")
        assert (work / "Podfile.lock").read_bytes() == locked
        assert package_objects(project) == (packages, products)
        assert resolved.read_bytes() == contents
    (work / "Podfile").write_text(original)
    fixture.cli(work, "install")
    assert package_objects(project) == ([], [])
    assert resolved.read_bytes() == contents
    fixture.verified.append(
        "package_only_references_survive_reinstall_updates_and_product_changes_then_remove_cleanly"
    )


def real_package_consumer(fixture):
    root = fixture.root / "local-swift-package"
    root.mkdir()
    origin = root / "Net"
    (origin / "Sources/Net").mkdir(parents=True)
    (origin / "Package.swift").write_text("""// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "Net", platforms: [.macOS(.v13)], products: [.library(name: "Net", targets: ["Net"])], targets: [.target(name: "Net")])
""")
    (origin / "Sources/Net/Net.swift").write_text(
        '@_cdecl("spm_value") public func spm_value() -> Int32 { 83 }\n'
    )
    git(origin, "init", "-b", "main")
    commit(origin, "Swift package fixture")
    git(origin, "tag", "1.0.0")
    work, project = create(root / "consumer")
    manifest(work, {"exact": "1.0.0", "products": ["Net"]}, origin.as_uri())
    (project.parent / "Sources/main.mm").write_text(
        '#include <Kit/Kit.h>\nextern "C" int spm_value(void);\n'
        "int main(void) { return kit_value() == 7 && spm_value() == 83 ? 0 : 1; }\n"
    )
    fixture.cli(work, "install")
    label = "swift-package-consumer-build"
    fixture.build(work, "Demo", label)
    subprocess.run(
        [str(resources_in_app(fixture, label) / "Contents/MacOS/Demo")], check=True
    )
    resolved = list(work.rglob("Package.resolved"))
    assert resolved, "Xcode did not record the resolved Swift package"
    before = {path: path.read_bytes() for path in resolved}
    packages = package_objects(project)
    locked = (work / "Podfile.lock").read_bytes()
    fixture.cli(work, "install", "--deployment", "--offline")
    assert (work / "Podfile.lock").read_bytes() == locked
    assert package_objects(project) == packages
    assert all(path.read_bytes() == data for path, data in before.items())
    fixture.verified.append(
        "local_swift_package_resolves_links_and_runs_with_pods_and_preserves_package_resolved"
    )


def run(fixture):
    invalid_inputs(fixture)
    package_only_lifecycle(fixture)
    real_package_consumer(fixture)
