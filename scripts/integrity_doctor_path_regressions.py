"""Integrity scopes and SDK diagnostic paths at filesystem boundaries."""

import json
import platform
import plistlib
import shutil

from bootstrap import project_state_directory
from input_contract_regressions import commit, git
from name_boundary_regressions import diagnostic
from native_xcconfig_tests import create
from vendor_fixture import run


def integrity_paths(fixture):
    work, _ = create(fixture.root / "integrity-unicode-root")
    origin = work / "Kit"
    old = origin / "Kit.podspec.json"
    attributes = json.loads(old.read_text())
    attributes.update(name="\u0301Kit", header_dir="Kit", module_name="Kit")
    old.unlink()
    spec = origin / "\u0301Kit.podspec.json"
    spec.write_text(json.dumps(attributes))
    original_spec = spec.read_bytes()
    git(origin, "init", "-b", "main")
    revision = commit(origin, "Unicode integrity root")
    (work / "Podfile").write_text(
        "platform :osx, '13.0'\ntarget('Demo') { pod '\u0301Kit', :git => "
        + repr(str(origin))
        + ", :commit => "
        + repr(revision)
        + " }\n"
    )
    fixture.cli(work, "install", "--no-integrate")
    lock = (work / "Podfile.lock").read_bytes()
    fixture.cli(work, "integrity", "record")
    assert fixture.cli(work, "integrity", "verify")["status"] == "passed"
    receipt = project_state_directory(work) / "Integrity.lock"
    original = receipt.read_bytes()
    metadata = json.loads(original)
    outside = work / "\u0301Outside"
    shutil.copytree(work / "Pods/\u0301Kit", outside, symlinks=True)
    metadata["artifacts"][0]["path"] = "Pods/../\u0301Outside"
    receipt.write_text(json.dumps(metadata))
    rejected = fixture.cli(work, "integrity", "verify", succeeds=False)
    assert diagnostic(rejected, "SP-INTEGRITY-PATH"), rejected
    receipt.write_bytes(original)
    pod = work / "Pods/\u0301Kit"
    actual = work / "Pods/Actual"
    pod.rename(actual)
    pod.symlink_to(outside, target_is_directory=True)
    rejected = fixture.cli(work, "integrity", "record", succeeds=False)
    assert diagnostic(rejected, "SP-INTEGRITY-PATH"), rejected
    assert receipt.read_bytes() == original
    assert diagnostic(
        fixture.cli(work, "integrity", "verify", succeeds=False), "SP-INTEGRITY-PATH"
    )
    pod.unlink()
    pod.symlink_to(actual, target_is_directory=True)
    fixture.cli(work, "integrity", "record")
    assert fixture.cli(work, "integrity", "verify")["status"] == "passed"
    source = actual / "Kit.c"
    original_source = source.read_bytes()
    mode = source.stat().st_mode & 0o7777

    def write_source(data):
        source.chmod(mode | 0o200)
        try:
            source.write_bytes(data)
        finally:
            source.chmod(mode)

    write_source(original_source + b"// external edit\n")
    rejected = fixture.cli(work, "integrity", "verify", succeeds=False)
    assert diagnostic(rejected, "SP-INTEGRITY-CONTENT"), rejected
    write_source(original_source)
    assert fixture.cli(work, "integrity", "verify")["status"] == "passed"
    assert (
        work / "Podfile.lock"
    ).read_bytes() == lock and spec.read_bytes() == original_spec
    fixture.verified.extend(
        [
            "unicode_nonlocal_pod_integrity_records_and_verifies",
            "integrity_rejects_traversal_before_combining_marks",
            "integrity_rejects_escaping_root_alias_without_replacing_receipt",
            "integrity_contained_root_alias_seals_and_detects_changed_source_contents",
        ]
    )


def doctor_paths(fixture):
    producer = fixture.root / "doctor-path-producer"
    producer.mkdir()
    (producer / "Payload.c").write_text("int payload_value(void) { return 42; }\n")
    run(
        [
            "xcrun",
            "--sdk",
            "macosx",
            "clang",
            "-target",
            platform.machine() + "-apple-macos13",
            "-Wall",
            "-Wextra",
            "-Werror",
            "-c",
            producer / "Payload.c",
            "-o",
            producer / "Payload.o",
        ],
        producer,
        fixture.root / "doctor-path-producer-compile.log",
    )
    run(
        ["ar", "rcs", producer / "Payload.a", producer / "Payload.o"],
        producer,
        fixture.root / "doctor-path-producer-archive.log",
    )

    def sdk(label, identifier="Slice", library="Payload.a"):
        work = fixture.root / ("doctor-path-" + label)
        root = work / "Fixture.xcframework"
        root.mkdir(parents=True)
        (work / "Podfile").write_text(
            "File.write('project-code-ran', 'yes'); raise 'Must_not_execute'\n"
        )
        entry = {
            "LibraryIdentifier": identifier,
            "LibraryPath": library,
            "SupportedPlatform": "macos",
            "SupportedArchitectures": [platform.machine()],
        }
        (root / "Info.plist").write_bytes(
            plistlib.dumps({"AvailableLibraries": [entry]})
        )
        return work, root

    def payload(path):
        path.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(producer / "Payload.a", path)

    def inspect(work, passed, label):
        report = fixture.cli(
            work,
            "doctor",
            "--static",
            "--platform",
            "osx",
            "--arch",
            platform.machine(),
            succeeds=passed,
        )
        failed = [
            c
            for c in report["checks"]
            if c["name"] == "xcframework_layout" and c["status"] == "failed"
        ]
        assert bool(failed) == (not passed), (label, report)
        declared = [b for b in report["binaries"] if "declared_platform" in b]
        assert len(declared) == (1 if passed else 0), (label, report)
        if passed:
            assert any(
                c["name"] == "xcframework_metadata" and c["status"] == "passed"
                for c in report["checks"]
            )
        assert (
            not (work / "project-code-ran").exists()
            and not project_state_directory(work).exists()
        )
        fixture.verified.append("doctor_path_" + label)

    for field in ["identifier", "library"]:
        for mode, prefix in [("absolute", "/"), ("traversal", "../")]:
            for mark in ["", "\u0301"]:
                label = field + "-" + mode + ("-unicode" if mark else "-ascii")
                value = (
                    prefix + mark + ("Slice" if field == "identifier" else "Payload.a")
                )
                work, root = sdk(
                    label,
                    identifier=value if field == "identifier" else "Slice",
                    library=value if field == "library" else "Payload.a",
                )
                if field == "identifier":
                    payload(
                        (work if mode == "traversal" else root)
                        / (mark + "Slice")
                        / "Payload.a"
                    )
                else:
                    (root / "Slice").mkdir()
                    payload(
                        (root if mode == "traversal" else root / "Slice")
                        / (mark + "Payload.a")
                    )
                inspect(work, False, label)
    work, root = sdk(
        "relative-unicode", identifier="\u0301Slice", library="\u0301Payload.a"
    )
    payload(root / "\u0301Slice/\u0301Payload.a")
    inspect(work, True, "relative-unicode")
    work, root = sdk("contained-product-alias")
    payload(root / "Slice/Actual.a")
    (root / "Slice/Payload.a").symlink_to("Actual.a")
    inspect(work, True, "contained-product-alias")
    work, root = sdk("escaping-product-alias")
    payload(work / "Outside.bin")
    (root / "Slice").mkdir()
    (root / "Slice/Payload.a").symlink_to(work / "Outside.bin")
    inspect(work, False, "escaping-product-alias")
    work, root = sdk("escaping-slice-alias")
    payload(work / "Outside/Payload.a")
    (root / "Slice").symlink_to(work / "Outside", target_is_directory=True)
    inspect(work, False, "escaping-slice-alias")
    for mode, prefix in [("absolute", "/"), ("traversal", "../")]:
        label = "framework-executable-" + mode
        work, root = sdk(label, library="Payload.framework")
        framework = root / "Slice/Payload.framework"
        framework.mkdir(parents=True)
        (framework / "Info.plist").write_bytes(
            plistlib.dumps({"CFBundleExecutable": prefix + "\u0301Escape"})
        )
        payload(
            (framework.parent if mode == "traversal" else framework) / "\u0301Escape"
        )
        inspect(work, False, label)
    work, root = sdk("versioned-framework", library="Payload.framework")
    framework = root / "Slice/Payload.framework"
    payload(framework / "Versions/A/Payload")
    resources = framework / "Versions/A/Resources"
    resources.mkdir()
    (resources / "Info.plist").write_bytes(
        plistlib.dumps({"CFBundleExecutable": "Payload"})
    )
    (framework / "Versions/Current").symlink_to("A", target_is_directory=True)
    (framework / "Payload").symlink_to("Versions/Current/Payload")
    (framework / "Resources").symlink_to(
        "Versions/Current/Resources", target_is_directory=True
    )
    inspect(work, True, "versioned-framework")

    (producer / "Main.c").write_text("int main(void) { return 0; }\n")
    for label, source, options in [
        ("Executable", "Main.c", []),
        ("Dynamic", "Payload.c", ["-dynamiclib"]),
    ]:
        run(
            [
                "xcrun",
                "--sdk",
                "macosx",
                "clang",
                "-target",
                platform.machine() + "-apple-macos13",
                "-Wall",
                "-Wextra",
                "-Werror",
                "-Wl,-fatal_warnings",
                *options,
                producer / source,
                "-o",
                producer / label,
            ],
            producer,
            fixture.root / ("doctor-path-producer-" + label + ".log"),
        )
    for mac in [False, True]:
        for escaping in [False, True]:
            label = ("mac" if mac else "flat") + (
                "-escaped-executable" if escaping else "-contained-executable"
            )
            work = fixture.root / ("doctor-app-" + label)
            app = work / "Example.app"
            executable = (
                (("../../../" if mac else "../") + "\u0301Outside")
                if escaping
                else "\u0301Payload"
            )
            info = app / ("Contents/Info.plist" if mac else "Info.plist")
            info.parent.mkdir(parents=True)
            (work / "Podfile").write_text(
                "File.write('project-code-ran', 'yes'); raise 'Must_not_execute'\n"
            )
            info.write_bytes(
                plistlib.dumps(
                    {
                        "CFBundleExecutable": executable,
                        "CFBundlePackageType": "APPL",
                        "CFBundleIdentifier": "org.swiftpods.pathfixture",
                    }
                )
            )
            directory = app / "Contents/MacOS" if mac else app
            directory.mkdir(parents=True, exist_ok=True)
            shutil.copy2(
                producer / "Executable",
                (work / "\u0301Outside") if escaping else directory / executable,
            )
            report = fixture.cli(
                work,
                "doctor",
                "--static",
                "--platform",
                "osx",
                "--app",
                str(app),
                succeeds=not escaping,
            )
            failures = [
                c
                for c in report["checks"]
                if c["name"] == "application" and c["status"] == "failed"
            ]
            assert bool(failures) == escaping, (label, report)
            assert not project_state_directory(work).exists()
            assert not (work / "project-code-ran").exists()
            fixture.verified.append("doctor_application_" + label)
    work = fixture.root / "doctor-app-external-framework"
    app = work / "Example.app"
    main = app / "Contents/MacOS/Example"
    main.parent.mkdir(parents=True)
    (work / "Podfile").write_text(
        "File.write('project-code-ran', 'yes'); raise 'Must_not_execute'\n"
    )
    shutil.copy2(producer / "Executable", main)
    (app / "Contents/Info.plist").write_bytes(
        plistlib.dumps({"CFBundleExecutable": "Example"})
    )
    outside = work / "Outside.framework"
    outside.mkdir()
    shutil.copy2(producer / "Dynamic", outside / "Outside")
    (outside / "Info.plist").write_bytes(
        plistlib.dumps({"CFBundleExecutable": "Outside"})
    )
    embedded = app / "Contents/Frameworks"
    embedded.mkdir()
    (embedded / "Outside.framework").symlink_to(outside, target_is_directory=True)
    report = fixture.cli(
        work,
        "doctor",
        "--static",
        "--platform",
        "osx",
        "--app",
        str(app),
        succeeds=False,
    )
    assert any(
        c["name"] == "application" and c["status"] == "failed" for c in report["checks"]
    ), report
    assert not project_state_directory(work).exists()
    assert not (work / "project-code-ran").exists()
    fixture.verified.append(
        "doctor_application_rejects_external_embedded_framework_alias"
    )


def run_regressions(fixture):
    integrity_paths(fixture)
    doctor_paths(fixture)
