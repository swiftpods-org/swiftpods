"""Environment imports validate before writes and remove only their own failed state."""

import hashlib
import os
import stat
import subprocess
import tempfile
from pathlib import Path

from command_option_regressions import snapshot


def rejected(fixture, root, work, label, arguments, code):
    before = snapshot(root)
    report = fixture.cli(work, *arguments, succeeds=False)
    diagnostics = report.get("events", []) + [report.get("diagnostic", {})]
    assert any(value.get("code") == code for value in diagnostics), report
    assert snapshot(root) == before, label
    fixture.verified.append("environment_import_" + label + "_preserves_tree")


def inputs(work, lock):
    (work / "Gemfile").write_text("source 'https://rubygems.org'\n")
    (work / "Gemfile.lock").write_bytes(lock)


def run_regressions(fixture):
    with tempfile.TemporaryDirectory(
        prefix="environment-import-", dir=fixture.root
    ) as temporary:
        parent = Path(temporary)
        seed = parent / "seed"
        seed.mkdir()
        (seed / "Gemfile").write_text("source 'https://rubygems.org'\n")
        result = subprocess.run(
            [fixture.env["SWIFTPODS_RUBY"], "-S", "bundle", "lock", "--local"],
            cwd=seed,
            env=fixture.env,
            capture_output=True,
            text=True,
            timeout=30,
        )
        (fixture.root / "environment-import-lock.log").write_text(
            result.stdout + result.stderr
        )
        assert result.returncode == 0
        lock = (seed / "Gemfile.lock").read_bytes()
        for kind in [
            "missing-gemfile",
            "missing-lock",
            "directory-gemfile",
            "directory-lock",
            "fifo-gemfile",
            "fifo-lock",
        ]:
            for named in [False, True]:
                label = kind + ("-named" if named else "-default")
                work = parent / label
                work.mkdir()
                if kind != "missing-gemfile":
                    inputs(work, lock)
                if kind == "missing-lock":
                    (work / "Gemfile.lock").unlink()
                if kind.startswith(("directory-", "fifo-")):
                    path = work / (
                        "Gemfile.lock" if kind.endswith("-lock") else "Gemfile"
                    )
                    path.unlink()
                    if kind.startswith("directory-"):
                        path.mkdir()
                    else:
                        os.mkfifo(path, 0o600)
                # Snapshot uses byte hashes, so represent FIFOs separately.
                if kind.startswith("fifo-"):
                    path.unlink()
                    before = snapshot(work)
                    os.mkfifo(path, 0o600)
                    arguments = ["env", "import", "--gemfile", "Gemfile", "--local"]
                    if named:
                        arguments += ["--name", "fixture"]
                    report = fixture.cli(work, *arguments, succeeds=False)
                    assert report["diagnostic"]["code"] == "SP-ENV-INPUT", report
                    assert stat.S_ISFIFO(path.lstat().st_mode)
                    path.unlink()
                    assert snapshot(work) == before
                    fixture.verified.append(
                        "environment_import_" + label + "_preserves_tree"
                    )
                    continue
                arguments = ["env", "import", "--gemfile", "Gemfile", "--local"]
                if named:
                    arguments += ["--name", "fixture"]
                rejected(fixture, work, work, label, arguments, "SP-ENV-INPUT")
        for component in [
            ".swiftpods",
            ".swiftpods/environments",
            ".swiftpods/environments/fixture",
        ]:
            for dangling in [False, True]:
                label = component.replace("/", "-") + (
                    "-dangling" if dangling else "-link"
                )
                root = parent / label
                root.mkdir()
                work = root / "work"
                work.mkdir()
                inputs(work, lock)
                outside = root / "outside"
                if not dangling:
                    outside.mkdir()
                link = work / component
                link.parent.mkdir(parents=True, exist_ok=True)
                link.symlink_to(outside, target_is_directory=True)
                rejected(
                    fixture,
                    root,
                    work,
                    label,
                    [
                        "env",
                        "import",
                        "--gemfile",
                        "Gemfile",
                        "--name",
                        "fixture",
                        "--local",
                    ],
                    "SP-ENV-PATH",
                )
                rejected(
                    fixture,
                    root,
                    work,
                    label + "-load",
                    ["version", "--environment", "fixture"],
                    "SP-ENV-PATH",
                )
        for component in [
            ".swiftpods",
            ".swiftpods/environments",
            ".swiftpods/environments/fixture",
        ]:
            label = "file-" + component.replace("/", "-")
            work = parent / label
            work.mkdir()
            inputs(work, lock)
            path = work / component
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("preserve this file")
            rejected(
                fixture,
                work,
                work,
                label,
                [
                    "env",
                    "import",
                    "--gemfile",
                    "Gemfile",
                    "--name",
                    "fixture",
                    "--local",
                ],
                "SP-ENV-PATH",
            )
        work = parent / "missing-ruby"
        work.mkdir()
        inputs(work, lock)
        ruby = fixture.env["SWIFTPODS_RUBY"]
        try:
            fixture.env["SWIFTPODS_RUBY"] = str(work / "absent-ruby")
            rejected(
                fixture,
                work,
                work,
                "missing-ruby",
                [
                    "env",
                    "import",
                    "--gemfile",
                    "Gemfile",
                    "--name",
                    "fixture",
                    "--local",
                ],
                "SP-RUBY-MISSING",
            )
        finally:
            fixture.env["SWIFTPODS_RUBY"] = ruby
        for layout in ["new-state", "existing-state", "existing-profiles"]:
            work = parent / ("failed-bundler-" + layout)
            work.mkdir()
            inputs(work, lock)
            (work / "Gemfile").write_text("raise 'expected fixture import failure'\n")
            if layout != "new-state":
                (work / ".swiftpods").mkdir()
                (work / ".swiftpods/keep").write_text("unrelated state")
            if layout == "existing-profiles":
                sibling = work / ".swiftpods/environments/sibling"
                sibling.mkdir(parents=True)
                (sibling / "keep").write_text("unrelated profile")
            rejected(
                fixture,
                work,
                work,
                "failed-bundler-" + layout,
                [
                    "env",
                    "import",
                    "--gemfile",
                    "Gemfile",
                    "--name",
                    "fixture",
                    "--local",
                ],
                "SP-ENV-IMPORT",
            )
        work = parent / "invalid-lock"
        work.mkdir()
        inputs(work, b"GEM\n  specs:\n    !\n")
        rejected(
            fixture,
            work,
            work,
            "invalid-lock",
            ["env", "import", "--gemfile", "Gemfile", "--name", "fixture", "--local"],
            "SP-ENV-IMPORT",
        )
        for named in [False, True]:
            work = parent / ("success-named" if named else "success-default")
            work.mkdir()
            inputs(work, lock)
            original = (work / "Gemfile").read_bytes()
            name = (
                "fixture"
                if named
                else "import-" + hashlib.sha256(original).hexdigest()[:12]
            )
            arguments = ["env", "import", "--gemfile", "Gemfile", "--local"]
            if named:
                arguments += ["--name", name]
            report = fixture.cli(work, *arguments)
            assert report["status"] == "imported" and report["profile"] == name
            assert (work / "Gemfile").read_bytes() == original and (
                work / "Gemfile.lock"
            ).read_bytes() == lock
            for path in [
                work / ".swiftpods",
                work / ".swiftpods/environments",
                work / ".swiftpods/environments" / name,
            ]:
                assert stat.S_IMODE(path.stat().st_mode) == 0o700
            fixture.verified.append(
                "environment_import_" + name + "_succeeds_with_private_modes"
            )
            rejected(
                fixture, work, work, name + "-duplicate", arguments, "SP-ENV-EXISTS"
            )
            report = fixture.cli(work, "version", "--environment", name)
            assert report["environment_profile"]["name"] == name
            fixture.verified.append(
                "environment_import_" + name + "_loads_verified_profile"
            )
            (work / "Gemfile").write_bytes(original + b"# edited\n")
            rejected(
                fixture,
                work,
                work,
                name + "-modified-input",
                ["version", "--environment", name],
                "SP-ENV-INTEGRITY",
            )
            (work / "Gemfile").write_bytes(original)
            (work / "Gemfile").unlink()
            before = snapshot(work)
            os.mkfifo(work / "Gemfile", 0o600)
            report = fixture.cli(work, "version", "--environment", name, succeeds=False)
            assert report["diagnostic"]["code"] == "SP-ENV-INTEGRITY", report
            assert stat.S_ISFIFO((work / "Gemfile").lstat().st_mode)
            (work / "Gemfile").unlink()
            assert snapshot(work) == before
            (work / "Gemfile").write_bytes(original)
            fixture.verified.append(
                "environment_import_" + name + "_load_rejects_fifo_input"
            )
        work = parent / "symlinked-gemfile"
        work.mkdir()
        source = parent / "external-input"
        source.mkdir()
        inputs(source, lock)
        (work / "Gemfile").symlink_to(source / "Gemfile")
        before = snapshot(source)
        report = fixture.cli(
            work, "env", "import", "--gemfile", "Gemfile", "--name", "linked", "--local"
        )
        assert report["status"] == "imported" and snapshot(source) == before
        assert (
            fixture.cli(work, "version", "--environment", "linked")[
                "environment_profile"
            ]["name"]
            == "linked"
        )
        fixture.verified.append(
            "environment_import_symlinked_external_input_remains_usable"
        )
        work = parent / "physical-project"
        work.mkdir()
        inputs(work, lock)
        alias = parent / "project-alias"
        alias.symlink_to(work, target_is_directory=True)
        report = fixture.cli(
            work,
            "env",
            "import",
            "--gemfile",
            "Gemfile",
            "--name",
            "alias",
            "--local",
            "--project-directory",
            str(alias),
        )
        assert report["status"] == "imported"
        report = fixture.cli(
            work, "version", "--environment", "alias", "--project-directory", str(alias)
        )
        assert report["environment_profile"]["name"] == "alias"
        fixture.verified.append(
            "environment_import_project_directory_alias_remains_usable"
        )
