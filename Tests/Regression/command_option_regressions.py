"""Reject missing option values before writes and keep explicit hyphen paths usable."""

import hashlib
import shlex
import subprocess
import tempfile
from pathlib import Path

MISSING_VALUES = [
    ("shim-directory", ["env", "shim"], "--directory"),
    ("project-directory", ["install"], "--project-directory"),
    ("environment", ["env", "list"], "--environment"),
    ("gemfile", ["env", "import"], "--gemfile"),
    ("profile-name", ["env", "import", "--gemfile", "Gemfile"], "--name"),
    ("platform", ["doctor", "--static"], "--platform"),
    ("variant", ["doctor", "--static"], "--variant"),
    ("architecture", ["doctor", "--static"], "--arch"),
    ("application", ["doctor", "--static"], "--app"),
    ("deployment-target", ["doctor", "--static"], "--deployment-target"),
    ("spec-version", ["spec", "which", "Kit"], "--version"),
    ("spec-sources", ["spec", "which", "Kit"], "--sources"),
    ("lint-sources", ["spec", "lint"], "--sources"),
    ("lint-platforms", ["spec", "lint"], "--platforms"),
    ("lint-swift-version", ["lib", "lint"], "--swift-version"),
]


def snapshot(work):
    return {
        str(path.relative_to(work)): (
            ("link", str(path.readlink()))
            if path.is_symlink()
            else ("directory", "")
            if path.is_dir()
            else ("file", hashlib.sha256(path.read_bytes()).hexdigest())
        )
        for path in work.rglob("*")
    }


def reject(fixture, parent, label, arguments, option, kind="Missing"):
    work = parent / label
    work.mkdir()
    (work / "Gemfile").write_text("source 'https://rubygems.org'\n")
    (work / "Podfile").write_text(
        "pre_install { |_| File.write('hook-ran', 'unexpected') }\n"
    )
    before = snapshot(work)
    report = fixture.cli(work, *arguments, succeeds=False)
    diagnostics = [
        event for event in report.get("events", []) if event.get("kind") == "diagnostic"
    ] + [report.get("diagnostic", {})]
    assert any(
        event.get("code") == "SP-CLI-ARGUMENT"
        and event.get("message") == kind + " value for " + option
        for event in diagnostics
    ), report
    assert snapshot(work) == before, label
    fixture.verified.append("cli_" + label + "_rejected_before_project_writes")


def run_regressions(fixture):
    with tempfile.TemporaryDirectory(
        prefix="command-options-", dir=fixture.root
    ) as temporary:
        parent = Path(temporary)
        for label, command, option in MISSING_VALUES:
            reject(fixture, parent, label, [*command, option, "--bogus"], option)
            reject(
                fixture,
                parent,
                label + "-before-json",
                [*command, option, "--json", "out"],
                option,
            )
        for label, arguments, option in [
            (
                "directory-before-environment",
                ["env", "shim", "--directory", "--environment", "unused", "out"],
                "--directory",
            ),
            (
                "environment-before-project-directory",
                ["env", "list", "--environment", "--project-directory", ".", "unused"],
                "--environment",
            ),
            (
                "project-directory-before-environment",
                ["env", "list", "--project-directory", "--environment", "unused", "."],
                "--project-directory",
            ),
            (
                "gemfile-before-local",
                ["env", "import", "--gemfile", "--local", "Gemfile"],
                "--gemfile",
            ),
            (
                "name-before-local",
                [
                    "env",
                    "import",
                    "--gemfile",
                    "Gemfile",
                    "--name",
                    "--local",
                    "profile",
                ],
                "--name",
            ),
            (
                "global-before-action",
                [
                    "env",
                    "--environment",
                    "unused",
                    "shim",
                    "--directory",
                    "--json",
                    "out",
                ],
                "--directory",
            ),
        ]:
            reject(fixture, parent, label, arguments, option)
        for label, value in [
            ("short-option", "-h"),
            ("terminator", "--"),
            ("combining-option", "-\u0301bogus"),
        ]:
            reject(
                fixture,
                parent,
                label,
                ["env", "shim", "--directory", value],
                "--directory",
            )
        reject(
            fixture,
            parent,
            "trailing-option",
            ["env", "shim", "--directory"],
            "--directory",
        )
        for label, arguments in [
            ("split-empty", ["--directory", ""]),
            ("inline-empty", ["--directory="]),
        ]:
            reject(
                fixture,
                parent,
                label,
                ["env", "shim", *arguments],
                "--directory",
                kind="Empty",
            )
        for label, value, inline in [
            ("inline-long", "--literal", True),
            ("inline-short", "-short", True),
            ("inline-terminator", "--", True),
            ("inline-combining", "-\u0301directory", True),
            ("relative-hyphen", "./--relative", False),
            ("single-hyphen", "-", False),
            ("leading-mark", "\u0301directory", False),
            ("spaces", "a directory", False),
        ]:
            work = parent / label
            work.mkdir()
            arguments = ["--directory=" + value] if inline else ["--directory", value]
            report = fixture.cli(work, "env", "shim", *arguments)
            directory = work / value
            target = directory / "pod"
            assert report["status"] == "created" and report["path_modified"] is False
            assert Path(report["path"]) == target
            assert target.is_symlink() and target.resolve() == fixture.binary.resolve()
            assert set(snapshot(work)) == {
                str(directory.relative_to(work)),
                str(target.relative_to(work)),
            }
            fixture.verified.append("cli_shim_" + label + "_creates_requested_link")
        help_result = subprocess.run(
            [str(fixture.binary), "help"],
            cwd=parent,
            env=fixture.env,
            capture_output=True,
            text=True,
            timeout=10,
        )
        (fixture.root / "command-options-help.log").write_text(
            help_result.stdout + help_result.stderr
        )
        assert help_result.returncode == 0
        commands = [
            shlex.split(line.strip())
            for line in help_result.stdout.splitlines()
            if "shim --directory PATH" in line
        ]
        assert commands == [["swiftpods", "env", "shim", "--directory", "PATH"]]
        work = parent / "documented-command"
        work.mkdir()
        arguments = [
            "documented-shim" if value == "PATH" else value for value in commands[0][1:]
        ]
        report = fixture.cli(work, *arguments)
        assert report["status"] == "created"
        assert (work / "documented-shim/pod").resolve() == fixture.binary.resolve()
        fixture.verified.append("cli_help_shim_command_executes_as_documented")
