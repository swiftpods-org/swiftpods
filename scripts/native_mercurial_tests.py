#!/usr/bin/env python3
"""Verify Mercurial pins, updates and offline installs with an actual repository."""

import json
import shutil
import subprocess

from bootstrap import environment
from local_build import debug_binary, fixture_directory, results_directory
from reporting import execute


def main():
    hg = shutil.which("hg")
    if not hg:
        raise RuntimeError("Mercurial is required: install hg before the full corpus")
    parent = fixture_directory("native-hg-")
    repo = parent / "repository"
    repo.mkdir()

    def command(*args):
        return subprocess.check_output(
            [hg, *args], cwd=repo, stderr=subprocess.STDOUT, text=True
        ).strip()

    command("init")

    def commit(version, value):
        (repo / "HGKit.podspec.json").write_text(
            json.dumps({"name": "HGKit", "version": version, "source_files": "*.c"})
        )
        (repo / "HGKit.c").write_text(
            "int hg_value(void) { return " + str(value) + "; }\n"
        )
        command("addremove")
        command(
            "commit", "-u", "SwiftPods Tests <tests@example.invalid>", "-m", version
        )
        return command("log", "-r", ".", "--template", "{node}")

    first = commit("1.0", 1)
    work = parent / "project"
    work.mkdir()
    (work / "Podfile").write_text(
        "platform :osx, '13.0'\ntarget 'App' do\n pod 'HGKit', :hg => "
        + repr(str(repo))
        + "\nend\n"
    )
    env = environment()
    env["SWIFTPODS_CACHE_ROOT"] = str(parent / "cache")

    def cli(*args, project=work):
        result = subprocess.run(
            [str(debug_binary()), *args, "--json"],
            cwd=project,
            env=env,
            capture_output=True,
            text=True,
            timeout=90,
        )
        assert result.returncode == 0, (args, result.stdout, result.stderr)
        return json.loads(result.stdout)

    cli("install", "--no-integrate")
    assert first in (work / "Podfile.lock").read_text()
    second = commit("1.1", 2)
    env["SWIFTPODS_CACHE_ROOT"] = str(parent / "fresh-cache")
    for selector in ["0", "'0'"]:
        project = parent / (
            "numeric-revision" if selector == "0" else "string-revision"
        )
        project.mkdir()
        (project / "Podfile").write_text(
            "platform :osx, '13.0'\ntarget 'App' do\n pod 'HGKit', :hg => "
            + repr(str(repo))
            + ", :revision => "
            + selector
            + "\nend\n"
        )
        cli("install", "--no-integrate", project=project)
        assert "return 1" in (project / "Pods/HGKit/HGKit.c").read_text()
        assert first in (project / "Podfile.lock").read_text()
        pinned = (project / "Podfile.lock").read_bytes()
        cli("install", "--no-integrate", "--offline", "--deployment", project=project)
        assert (project / "Podfile.lock").read_bytes() == pinned
    cli("install", "--no-integrate")
    assert "return 1" in (work / "Pods/HGKit/HGKit.c").read_text()
    assert first in (work / "Podfile.lock").read_text()
    cli("update", "HGKit", "--no-integrate")
    assert "return 2" in (work / "Pods/HGKit/HGKit.c").read_text()
    assert second in (work / "Podfile.lock").read_text()
    lock = (work / "Podfile.lock").read_bytes()
    cli("install", "--no-integrate", "--offline", "--deployment")
    assert (work / "Podfile.lock").read_bytes() == lock
    cli("cache", "verify")
    report = {
        "status": "passed",
        "engine": "swift",
        "fixture": str(parent),
        "mercurial": subprocess.check_output([hg, "--version"], text=True).splitlines()[
            0
        ],
        "verified": [
            "actual Mercurial repository and full revision pin",
            "integer and string Mercurial revision zero select the first commit",
            "advanced upstream head remains pinned across a fresh cache",
            "selected update installs the new revision and version",
            "offline deployment preserves lock bytes",
            "source snapshot cache integrity",
        ],
        "unverified": ["authenticated remote Mercurial transport"],
    }
    (results_directory() / "native-mercurial.json").write_text(
        json.dumps(report, indent=2) + "\n"
    )
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    execute(main, "native-mercurial.json")
