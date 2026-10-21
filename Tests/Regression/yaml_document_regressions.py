"""Lock data keeps its YAML meaning, spelling, and filesystem identities."""

import json
import shutil
import subprocess

from scripts.support.bootstrap import ROOT
from Tests.Integration.native_xcconfig_tests import create
from Tests.Regression.name_boundary_regressions import diagnostic
from Tests.Regression.project_path_regressions import builds, reinstall

RUBY_READ = (
    "require 'yaml';require 'json';"
    "puts JSON.generate(YAML.safe_load(File.read(ARGV[0]), permitted_classes: [Symbol]) || {})"
)


def same(left, right):
    return json.dumps(left, sort_keys=True, ensure_ascii=True) == json.dumps(
        right, sort_keys=True, ensure_ascii=True
    )


def reference(fixture, path, label, succeeds=True):
    result = subprocess.run(
        [fixture.env["SWIFTPODS_RUBY"], "-e", RUBY_READ, str(path)],
        cwd=path.parent,
        env=fixture.env,
        capture_output=True,
        text=True,
        timeout=30,
    )
    log = fixture.root / (label + "-reference.log")
    log.write_text(result.stdout + result.stderr)
    assert (result.returncode == 0) == succeeds, log
    return json.loads(result.stdout) if succeeds else None


def hardened_manifest(work):
    (work / "Podfile.json").write_text(
        json.dumps(
            {
                "schema_version": 1,
                "platform": {"name": "osx", "deployment_target": "13.0"},
                "project": "../Apps/External.xcodeproj",
                "targets": [
                    {"name": "Demo", "pods": [{"name": "Kit", "path": "./Kit"}]}
                ],
            }
        )
    )


def managed_inputs(work, selected):
    return {
        file: file.read_bytes()
        for file in [
            selected / "project.pbxproj",
            work / "Podfile.lock",
            work / "Pods/Manifest.lock",
            work / "Pods/Pods.xcodeproj/project.pbxproj",
            work / "Kit/Kit.podspec.json",
            work / "Podfile",
            work / "Podfile.json",
        ]
        if file.is_file()
    }


def lock_data(fixture):
    corpus = json.loads((ROOT / "Tests/Fixtures/YAMLLockData.json").read_text())
    assert corpus["schema_version"] == 1
    names = [row["name"] for row in corpus["cases"]]
    assert len(names) == len(set(names))
    for hardened in [False, True]:
        mode = "hardened" if hardened else "dsl"
        flags = ["--hardened"] if hardened else []
        work, selected = create(fixture.root / ("yaml-document-" + mode))
        if hardened:
            hardened_manifest(work)
        else:
            podfile = work / "Podfile"
            podfile.write_text(
                podfile.read_text()
                + "pre_install { |_| File.write('yaml-pre-hook', 'yes') }\n"
            )
        fixture.cli(work, "install", *flags)
        lock = work / "Podfile.lock"
        base = lock.read_bytes()
        base_data = reference(fixture, lock, "yaml-" + mode + "-base")
        source = work / "Kit/Kit.podspec.json"
        original_spec = source.read_bytes()
        marker = work / "yaml-pre-hook"
        for row in corpus["cases"]:
            label = "yaml-" + mode + "-" + row["name"]
            source.write_bytes(original_spec)
            lock.write_bytes(base + b"\n" + row["yaml"].encode())
            (fixture.root / (label + ".input.lock")).write_bytes(lock.read_bytes())
            before = managed_inputs(work, selected)
            marker.unlink(missing_ok=True)
            value = reference(
                fixture, lock, label + "-input", succeeds=row["reference_valid"]
            )
            if row["reference_valid"]:
                custom = {key: value[key] for key in value if key not in base_data}
                assert same(custom, row["expected"]), (label, custom, row["expected"])
            if not row["valid"]:
                result = fixture.cli(work, "install", *flags, succeeds=False)
                code = (
                    "SP-LOCK-YAML"
                    if hardened or row["reference_valid"]
                    else "SP-DSL-ERROR"
                )
                assert diagnostic(result, code), result
                assert result["project_state"] == "failed_no_managed_changes", result
                assert all(path.read_bytes() == data for path, data in before.items())
                assert not marker.exists()
            else:
                fixture.cli(work, "install", *flags, "--offline", "--deployment")
                assert lock.read_bytes() == before[lock]
                fixture.cli(work, "install", *flags, "--offline")
                assert lock.read_bytes() == before[lock]
                # Force a real lock update so formatting preservation cannot
                # conceal an incorrect scalar type or collection shape.
                spec = json.loads(original_spec)
                spec["summary"] = "YAML regression " + row["name"]
                source.write_text(json.dumps(spec))
                fixture.cli(work, "install", *flags, "--offline")
                assert lock.read_bytes() != before[lock]
                after = reference(fixture, lock, label + "-rewritten")
                custom = {key: after[key] for key in after if key not in base_data}
                assert same(custom, row["expected"]), (label, custom, row["expected"])
                assert (
                    after["SPEC CHECKSUMS"]["Kit"] != base_data["SPEC CHECKSUMS"]["Kit"]
                )
                written = lock.read_bytes()
                (fixture.root / (label + ".output.lock")).write_bytes(written)
                fixture.cli(work, "install", *flags, "--offline", "--deployment")
                assert lock.read_bytes() == written
                if not hardened:
                    assert marker.read_text() == "yes"
            fixture.verified.append("yaml_lock_" + mode + "_" + row["name"])


def literal_paths(fixture):
    for label, name in [
        ("apostrophe", "Kit's"),
        ("combining", "Kit'\u0301s"),
        ("nel", "Kit\u0085Tail"),
        ("ls", "Kit\u2028Tail"),
        ("ps", "Kit\u2029Tail"),
    ]:
        work, selected = create(fixture.root / ("yaml-path-" + label))
        (work / "Kit").rename(work / name)
        podfile = work / "Podfile"
        podfile.write_text(
            podfile.read_text().replace(
                "'./Kit'", json.dumps("./" + name, ensure_ascii=False)
            )
        )
        fixture.cli(work, "install")
        (fixture.root / ("yaml-path-" + label + ".lock")).write_bytes(
            (work / "Podfile.lock").read_bytes()
        )
        value = reference(fixture, work / "Podfile.lock", "yaml-path-" + label)
        options = value["EXTERNAL SOURCES"]["Kit"]
        assert options.get(":path", options.get("path")) == "./" + name
        reinstall(fixture, work, selected)
        fixture.verified.append("yaml_path_" + label + "_ruby_and_offline_roundtrip")
        inspect = work / "InspectPodfile"
        inspect.write_text(
            "require 'xcodeproj'\n"
            "project = Xcodeproj::Project.open('Pods/Pods.xcodeproj')\n"
            "target = project.targets.find { |target| target.name == 'Kit' }\n"
            "File.write('yaml-headers.json', JSON.generate(target.resolved_build_setting('HEADER_SEARCH_PATHS', true)))\n"
            + podfile.read_text()
        )
        fixture.cli(work, "ipc", "podfile", str(inspect))
        headers = json.loads((work / "yaml-headers.json").read_text())
        (fixture.root / ("yaml-path-" + label + "-headers.json")).write_bytes(
            (work / "yaml-headers.json").read_bytes()
        )
        assert name in json.dumps(headers, ensure_ascii=False), headers
        fixture.verified.append("yaml_path_" + label + "_native_build_setting_read")
        builds(fixture, work, "yaml-path-" + label)
        fixture.verified.append("yaml_path_" + label + "_debug_release_consumers")


def rejected_path_controls(fixture):
    for label, name in [("lf", "Kit\nTail"), ("cr", "Kit\rTail")]:
        work, selected = create(fixture.root / ("yaml-path-" + label))
        original = (selected / "project.pbxproj").read_bytes()
        (work / "Kit").rename(work / name)
        podfile = work / "Podfile"
        podfile.write_text(
            podfile.read_text().replace("'./Kit'", json.dumps("./" + name))
        )
        result = fixture.cli(work, "install", "--no-integrate", succeeds=False)
        assert diagnostic(result, "SP-XCCONFIG-VALUE"), result
        assert result["project_state"] == "recovery_required", result
        fixture.cli(work, "recover")
        assert (selected / "project.pbxproj").read_bytes() == original
        assert not (work / "Podfile.lock").exists()
        fixture.verified.append(
            "yaml_path_" + label + "_existing_rejection_is_recoverable"
        )


def run_regressions(fixture):
    retained = set(fixture.root.iterdir())
    try:
        lock_data(fixture)
        literal_paths(fixture)
        rejected_path_controls(fixture)
    finally:
        for path in fixture.root.iterdir():
            if (
                path not in retained
                and path.is_dir()
                and path.name.startswith(("yaml-document-", "yaml-path-"))
            ):
                shutil.rmtree(path)
    fixture.cli(fixture.root, "cache", "verify")
    fixture.verified.append("yaml_fixture_cleanup_preserves_cache_integrity")
