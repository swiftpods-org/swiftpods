"""Global options preserve dispatch; invalid recovery requests never restore files."""

import hashlib
import json
import stat
import subprocess
import tempfile
from pathlib import Path

from native_integration import project as xcode_project

EXTRAS = ["--dry-run", "--unknown", "unexpected", "--", "-\u0301unknown", ""]


def snapshot(root):
    rows = {}
    for path in root.rglob("*"):
        mode = path.lstat().st_mode
        value = (
            ("link", str(path.readlink()))
            if stat.S_ISLNK(mode)
            else ("directory", "")
            if stat.S_ISDIR(mode)
            else ("file", hashlib.sha256(path.read_bytes()).hexdigest())
        )
        rows[str(path.relative_to(root))] = (stat.S_IMODE(mode), value)
    return rows


def rejected(fixture, parent, cwd, arguments, label, code="SP-CLI-ARGUMENT"):
    before = snapshot(parent)
    report = fixture.cli(cwd, *arguments, succeeds=False)
    assert report.get("diagnostic", {}).get("code") == code, report
    assert snapshot(parent) == before, label
    fixture.verified.append("cli_invocation_" + label + "_preserves_tree")


def interrupted(fixture, work, current=False):
    backup = work / ".swiftpods/backup"
    backup.mkdir(parents=True)
    (backup / "0").write_bytes(b"original lock")
    lock = work / "Podfile.lock"
    lock.write_bytes(b"failed lock")
    entry = {"path": "Podfile.lock", "backup": "0", "existed": True}
    for key, path in [("before_digest", backup / "0"), ("after_digest", lock)]:
        entry[key] = (
            fixture.cli(work, "__treecheck", str(path))["sha256"]
            if current
            else hashlib.sha256(path.read_bytes()).hexdigest()
        )
    state = {"status": "recovery_required", "journal": [entry]}
    if current:
        state["fingerprint_version"] = 2
    (work / ".swiftpods/state.json").write_text(json.dumps(state))


def imported(fixture, cwd, work):
    (work / "Gemfile").write_text("source 'https://rubygems.org'\n")
    result = subprocess.run(
        [fixture.env["SWIFTPODS_RUBY"], "-S", "bundle", "lock", "--local"],
        cwd=work,
        env=fixture.env,
        capture_output=True,
        text=True,
        timeout=30,
    )
    (fixture.root / "cli-invocation-lock.log").write_text(result.stdout + result.stderr)
    assert result.returncode == 0
    report = fixture.cli(
        cwd,
        "env",
        "import",
        "--project-directory",
        str(work),
        "--gemfile",
        "Gemfile",
        "--name",
        "fixture",
        "--local",
    )
    assert report["status"] == "imported"
    fixture.verified.append("cli_invocation_import_uses_selected_project")


def check_init(fixture, cwd, work, arguments, label):
    xcode_project(work / "Demo.xcodeproj")
    project_bytes = (work / "Demo.xcodeproj/project.pbxproj").read_bytes()
    (work / "local.txt").write_text("user source")
    report = fixture.cli(cwd, *arguments)
    assert report["exit_status"] == 0 and (work / "Podfile").is_file()
    state_file = work / ".swiftpods/state.json"
    state = json.loads(state_file.read_text())
    entry = next(row for row in state["journal"] if row["path"] == "Podfile")
    assert entry["existed"] is False and entry["before_digest"] == "absent"
    assert state["command"] == arguments
    fixture.verified.append("cli_invocation_" + label + "_journals_init_podfile")
    # Reproduce interruption after the final file fingerprints were recorded.
    state["status"] = "recovery_required"
    state_file.write_text(json.dumps(state))
    report = fixture.cli(cwd, "--project-directory", str(work), "recover")
    assert report["status"] == "recovered" and not (work / "Podfile").exists()
    assert (work / "Demo.xcodeproj/project.pbxproj").read_bytes() == project_bytes
    assert (work / "local.txt").read_text() == "user source"
    fixture.verified.append("cli_invocation_" + label + "_recovers_init_podfile")


def run_regressions(fixture):
    original_cache = fixture.env["SWIFTPODS_CACHE_ROOT"]
    try:
        with tempfile.TemporaryDirectory(
            prefix="cli-invocation-", dir=fixture.root
        ) as temporary:
            parent = Path(temporary)
            fixture.env["SWIFTPODS_CACHE_ROOT"] = str(parent / "cache")
            cwd = parent / "cwd"
            cwd.mkdir()
            marker = "File.write(File.join(__dir__, 'executed'), 'unexpected')\n"
            (cwd / "Podfile").write_text(marker + "raise 'must not execute'\n")
            for current in [False, True]:
                for number, argument in enumerate(EXTRAS):
                    label = f"recover-{current}-{number}"
                    work = parent / label
                    work.mkdir()
                    interrupted(fixture, work, current)
                    rejected(
                        fixture,
                        parent,
                        cwd,
                        ["recover", argument, "--project-directory", str(work)],
                        label,
                    )
            empty = parent / "empty"
            empty.mkdir()
            rejected(
                fixture,
                parent,
                cwd,
                ["recover", "--project-directory", str(empty)],
                "recover-no-journal",
                "SP-RECOVER-NOT-NEEDED",
            )
            rejected(
                fixture,
                parent,
                cwd,
                ["recover", "--unknown", "--project-directory", str(empty)],
                "recover-empty",
            )
            for command in [
                ["cache", "verify"],
                ["runtime", "verify"],
                ["version"],
                ["--version"],
            ]:
                for number, argument in enumerate(EXTRAS):
                    rejected(
                        fixture,
                        parent,
                        cwd,
                        [*command, argument, "--project-directory", str(empty)],
                        "-".join(command) + "-" + str(number),
                    )
            for command in [["runtime"], ["runtime", "unknown"]]:
                rejected(fixture, parent, cwd, command, "-".join(command))
            for command in [
                ["repo", "list"],
                ["cache", "list"],
                ["cache", "verify"],
                ["runtime", "verify"],
                ["version"],
                ["--version"],
                ["env", "list"],
                ["env"],
            ]:
                for inline in [False, True]:
                    for position in range(len(command) + 1):
                        arguments = command.copy()
                        directory = (
                            ["--project-directory=" + str(empty)]
                            if inline
                            else ["--project-directory", str(empty)]
                        )
                        arguments[position:position] = directory
                        before = snapshot(cwd), snapshot(empty)
                        report = fixture.cli(cwd, *arguments)
                        assert before == (snapshot(cwd), snapshot(empty))
                        if command[0] in ["version", "--version"]:
                            assert report["swiftpods_version"]
                        elif command[0] == "repo":
                            assert report["repositories"] == []
                        elif command == ["cache", "list"]:
                            assert report["entries"] == []
                        elif command[0] == "env":
                            assert report["profiles"] == []
                        else:
                            assert report["status"] == "passed"
                        fixture.verified.append(
                            f"cli_invocation_{'-'.join(command)}_{inline}_{position}_selects_project"
                        )
            for name in ["-\u0301project", "--json", "--environment", "-"]:
                work = cwd / name
                work.mkdir()
                for leading in [False, True]:
                    arguments = ["version"]
                    arguments.insert(0 if leading else 1, "--project-directory=" + name)
                    assert fixture.cli(cwd, *arguments)["swiftpods_version"]
                    fixture.verified.append(
                        f"cli_invocation_literal_directory_{name}_{leading}"
                    )
            selected = parent / "profile"
            selected.mkdir()
            imported(fixture, cwd, selected)
            for inline in [False, True]:
                for position in range(3):
                    arguments = ["version", "--project-directory=" + str(selected)]
                    option = (
                        ["--environment=fixture"]
                        if inline
                        else ["--environment", "fixture"]
                    )
                    arguments[position:position] = option
                    before = snapshot(parent)
                    report = fixture.cli(cwd, *arguments)
                    assert report["environment_profile"]["name"] == "fixture"
                    assert snapshot(parent) == before
                    fixture.verified.append(
                        f"cli_invocation_selected_profile_{inline}_{position}"
                    )
            for number, arguments in enumerate(
                [
                    ["--project-directory", "--environment", "fixture", "version"],
                    ["--environment", "--project-directory", str(selected), "version"],
                    [
                        "--project-directory",
                        str(selected),
                        "env",
                        "shim",
                        "--directory",
                        "--json",
                        "out",
                    ],
                    [
                        "--project-directory",
                        str(selected),
                        "version",
                        "--project-directory=" + str(selected),
                    ],
                ]
            ):
                rejected(fixture, parent, cwd, arguments, f"global-values-{number}")
            for leading in [False, True]:
                work = parent / ("init-" + str(leading))
                work.mkdir()
                arguments = ["init"]
                position = 0 if leading else 1
                arguments[position:position] = ["--project-directory", str(work)]
                check_init(fixture, cwd, work, arguments, "init-" + str(leading))
            (parent / "Podfile").write_text(marker + "raise 'must not execute'\n")
            check_init(
                fixture,
                selected,
                selected,
                ["--environment=fixture", "init"],
                "init-leading-environment",
            )
            assert (
                not (cwd / "executed").exists() and not (parent / "executed").exists()
            )
    finally:
        fixture.env["SWIFTPODS_CACHE_ROOT"] = original_cache
