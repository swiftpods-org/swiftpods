"""Reinstall and clean downloaded SDKs without losing selected symbolic links."""

import hashlib
import json
import shutil
import subprocess

from Tests.Integration.native_xcconfig_tests import create


def reinstall(fixture, work, selected):
    project = selected / "project.pbxproj"
    before = project.read_bytes(), (work / "Podfile.lock").read_bytes()
    fixture.cli(work, "install", "--offline", "--deployment")
    assert (project.read_bytes(), (work / "Podfile.lock").read_bytes()) == before


def build_and_run(fixture, work, label):
    fixture.build(work, "Demo", label)
    app = fixture.root / label / "DerivedData/Build/Products/Debug/Demo.app"
    output = subprocess.check_output([str(app / "Contents/MacOS/Demo")], text=True)
    assert "value=7" in output, output


def removed_headers(fixture):
    for layout in ["root", "nested"]:
        label = "removed-source-header-" + layout
        work, selected = create(fixture.root / label)
        library = work / "Kit"
        if layout == "root":
            for path in library.iterdir():
                shutil.move(path, work / path.name)
            library.rmdir()
            library = work
            podfile = work / "Podfile"
            podfile.write_text(podfile.read_text().replace("'./Kit'", "'.'"))
        header = library / "Gone.h"
        header.write_text("#pragma once\n")
        original = (library / "Kit.h").read_bytes()
        fixture.cli(work, "install")
        header.unlink()
        fixture.cli(work, "install")
        reinstall(fixture, work, selected)
        build_and_run(fixture, work, label + "-build")
        assert (library / "Kit.h").read_bytes() == original
        fixture.verified.append("removed_header_reinstall_build_run_" + layout)


def downloaded_links(fixture):
    for mode in ["file", "preserved-directory"]:
        label = "downloaded-source-links-" + mode
        work, selected = create(fixture.root / label)
        library = work / "Kit"
        (library / "Real").mkdir()
        header = library / "Real/Kit.h"
        original = hashlib.sha256((library / "Kit.h").read_bytes()).hexdigest()
        if mode == "file":
            (library / "Kit.h").rename(header)
            (library / "Links").mkdir()
            (library / "Links/Actual.h").symlink_to("../Real/Kit.h")
            (library / "Kit.h").symlink_to("Links/Actual.h")
            (library / "Real/unused.txt").write_text("Unused payload\n")
        else:
            shutil.copy2(library / "Kit.h", header)
            (library / "Headers").symlink_to("Real")
            spec = library / "Kit.podspec.json"
            data = json.loads(spec.read_text())
            data["preserve_paths"] = "Headers"
            spec.write_text(json.dumps(data))
        (library / "unused.txt").write_text("Unused payload\n")
        for arguments in [
            ["init", "-b", "main"],
            ["add", "."],
            [
                "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                "-c", "commit.gpgsign=false", "commit", "-m", "SDK fixture",
            ],
            ["tag", "1.0"],
        ]:
            subprocess.run(
                ["git", "-C", str(library), *arguments], check=True, capture_output=True
            )
        podfile = work / "Podfile"
        podfile.write_text(
            podfile.read_text().replace(
                ":path => './Kit'", ":git => " + repr(library.as_uri()) + ", :tag => '1.0'"
            )
        )
        for _ in range(2):
            fixture.cli(work, "install")
            installed = work / "Pods/Kit"
            effective = installed / ("Kit.h" if mode == "file" else "Headers/Kit.h")
            assert hashlib.sha256(effective.read_bytes()).hexdigest() == original
            assert not (installed / "unused.txt").exists()
            if mode == "file":
                assert not (installed / "Real/unused.txt").exists()
                assert (installed / "Links/Actual.h").is_symlink()
            else:
                assert (installed / "Headers").is_symlink()
            assert hashlib.sha256(header.read_bytes()).hexdigest() == original
            assert subprocess.check_output(
                ["git", "-C", str(library), "status", "--porcelain"], text=True
            ) == ""
        reinstall(fixture, work, selected)
        fixture.cli(work, "cache", "list", "Kit")
        assert fixture.cli(work, "cache", "verify")["status"] == "passed"
        build_and_run(fixture, work, label + "-build")
        fixture.verified.append("downloaded_link_cleanup_reinstall_build_run_" + mode)


def run_regressions(fixture):
    removed_headers(fixture)
    downloaded_links(fixture)
