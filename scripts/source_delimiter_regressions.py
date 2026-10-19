"""VCS source delimiters are ASCII scalars even beside combining characters."""

import json
import shlex
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

from native_xcconfig_tests import create
from project_path_regressions import builds, reinstall
from yaml_document_regressions import reference


def command(fixture, work, *arguments):
    result = subprocess.run(
        arguments, cwd=work, env=fixture.env, capture_output=True, text=True, timeout=30
    )
    assert result.returncode == 0, result.stdout + result.stderr
    return result.stdout.strip()


def commit(fixture, repository, kind, message):
    if kind == "git":
        command(fixture, repository, "/usr/bin/git", "add", ".")
        command(
            fixture,
            repository,
            "/usr/bin/git",
            "-c",
            "user.name=Fixture",
            "-c",
            "user.email=fixture@example.invalid",
            "commit",
            "-qm",
            message,
        )
        return command(fixture, repository, "/usr/bin/git", "rev-parse", "HEAD")
    command(fixture, repository, "hg", "add")
    command(
        fixture,
        repository,
        "hg",
        "commit",
        "-u",
        "Fixture <fixture@example.invalid>",
        "-m",
        message,
    )
    return command(fixture, repository, "hg", "log", "-r", ".", "--template", "{node}")


def manifest(work, kind, location, hardened):
    source = {kind: location}
    if kind == "git":
        source["branch"] = "main"
    if hardened:
        (work / "Podfile").unlink(missing_ok=True)
        (work / "Podfile.json").write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "platform": {"name": "osx", "deployment_target": "13.0"},
                    "project": "../Apps/External.xcodeproj",
                    "targets": [{"name": "Demo", "pods": [{"name": "Kit", **source}]}],
                }
            )
        )
    else:
        (work / "Podfile").write_text(
            "platform :osx, '13.0'\nproject '../Apps/External.xcodeproj'\n"
            "target 'Demo' do\n pod 'Kit', "
            + ", ".join(
                ":" + key + " => " + json.dumps(value, ensure_ascii=False)
                for key, value in source.items()
            )
            + "\nend\n"
        )
    return source


def checkout(fixture, work, source, revision, label):
    lock = reference(fixture, work / "Podfile.lock", label + "-lock")
    assert lock["EXTERNAL SOURCES"]["Kit"] == {
        ":" + key: value for key, value in source.items()
    }
    pin = lock["CHECKOUT OPTIONS"]["Kit"]
    assert all(pin[":" + key] == value for key, value in source.items())
    assert pin[":commit" if "git" in source else ":revision"] == revision
    (fixture.root / (label + ".lock")).write_bytes((work / "Podfile.lock").read_bytes())


def consumer(fixture, work, label, value):
    builds(fixture, work, label)
    for configuration in ["Debug", "Release"]:
        log = fixture.root / (label + "-" + configuration + "-run.log")
        assert (
            log.read_text().strip() == "value=" + str(value) + " user=1 conditional=1"
        ), log


def local_sources(fixture, parent, kind, hardened):
    mode = "hardened" if hardened else "dsl"
    flags = ["--hardened"] if hardened else []
    prefix = "source-delimiter-" + kind + "-" + mode
    location = "./\u0301Repo:tag"
    projects = []
    for index, value in enumerate([7, 19]):
        label = prefix + "-" + str(index)
        work, selected = create(parent / label)
        repository = work / location[2:]
        (work / "Kit").rename(repository)
        source = manifest(work, kind, location, hardened)
        spec = repository / "Kit.podspec.json"
        data = json.loads(spec.read_text())
        data["source"] = source
        spec.write_text(json.dumps(data))
        (repository / "Kit.c").write_text(
            "int kit_value(void) { return " + str(value) + "; }\n"
        )
        command(
            fixture,
            repository,
            *(
                ["/usr/bin/git", "init", "-q", "-b", "main"]
                if kind == "git"
                else ["hg", "init"]
            ),
        )
        revision = commit(fixture, repository, kind, "Fixture")
        child = work / "Child"
        child.mkdir()
        fixture.cli(child, "install", *flags)
        assert (work / "Pods/Kit/Kit.c").read_bytes() == (
            repository / "Kit.c"
        ).read_bytes()
        checkout(fixture, work, source, revision, label)
        # Force restoration from the shared cache, not the installed sandbox.
        shutil.rmtree(work / "Pods/Kit")
        fixture.cli(child, "install", *flags, "--offline", "--deployment")
        assert (work / "Pods/Kit/Kit.c").read_bytes() == (
            repository / "Kit.c"
        ).read_bytes()
        reinstall(fixture, work, selected, *flags)
        consumer(fixture, work, label, value)
        projects.append((work, selected, repository, source, revision))
        fixture.verified.append(
            label
            + "_distinct_cache_revision_offline_and_Debug_Release_value_"
            + str(value)
        )
    assert projects[0][4] != projects[1][4]
    # A symlink alias to the same physical repository must reuse its cache.
    work, selected, repository, _, revision = projects[1]
    alias = work / "\u0301Alias:tag"
    alias.symlink_to(repository, target_is_directory=True)
    before = set(Path(fixture.env["SWIFTPODS_CACHE_ROOT"]).rglob("*.origin.json"))
    source = manifest(work, kind, "./" + alias.name, hardened)
    fixture.cli(work, "install", *flags, "--offline")
    checkout(fixture, work, source, revision, prefix + "-alias")
    assert (
        set(Path(fixture.env["SWIFTPODS_CACHE_ROOT"]).rglob("*.origin.json")) == before
    )
    fixture.verified.append(prefix + "_physical_symlink_identity_and_raw_lock_spelling")
    if not hardened:
        first, _, origin, first_source, _ = projects[0]
        (origin / "Kit.c").write_text("int kit_value(void) { return 23; }\n")
        updated = commit(fixture, origin, kind, "Update")
        fixture.cli(first, "update", "Kit", "--no-repo-update")
        checkout(fixture, first, first_source, updated, prefix + "-updated")
        consumer(fixture, first, prefix + "-updated", 23)
        fixture.cli(work, "install", "--offline", "--deployment")
        assert "return 19;" in (work / "Pods/Kit/Kit.c").read_text()
        checkout(fixture, work, source, revision, prefix + "-other-pin")
        fixture.verified.append(prefix + "_explicit_update_keeps_other_project_pin")
    fixture.cli(work, "cache", "verify")


def scp_sources(fixture, parent):
    previous = {
        key: fixture.env.get(key) for key in ["GIT_SSH_COMMAND", "GIT_SSH_VARIANT"]
    }
    try:
        for suffix, path in [("plain", "Repo"), ("marked", "\u0301Repo")]:
            label = "source-delimiter-scp-" + suffix
            work, selected = create(parent / label)
            repository = work / "Kit"
            source = manifest(work, "git", "fixture@source.invalid:" + path, False)
            command(fixture, repository, "/usr/bin/git", "init", "-q", "-b", "main")
            revision = commit(fixture, repository, "git", "Fixture")
            calls = parent / (label + "-ssh.jsonl")
            helper = parent / (label + "-ssh.py")
            helper.write_text(
                "import json,os,shlex,sys\nfrom pathlib import Path\n"
                + "Path("
                + repr(str(calls))
                + ").open('a').write(json.dumps(sys.argv[1:])+'\\n')\n"
                + "assert shlex.split(sys.argv[-1]) == ['git-upload-pack', "
                + repr(path)
                + "]\n"
                + "os.execv('/usr/bin/git-upload-pack', ['git-upload-pack', "
                + repr(str(repository))
                + "])\n"
            )
            fixture.env["GIT_SSH_COMMAND"] = (
                shlex.quote(sys.executable) + " " + shlex.quote(str(helper))
            )
            fixture.env["GIT_SSH_VARIANT"] = "ssh"
            fixture.cli(work, "install")
            checkout(fixture, work, source, revision, label)
            transport = calls.read_bytes()
            assert transport and all(
                shlex.split(json.loads(line)[-1]) == ["git-upload-pack", path]
                for line in transport.decode().splitlines()
            )
            shutil.rmtree(work / "Pods/Kit")
            reinstall(fixture, work, selected)
            assert calls.read_bytes() == transport
            (fixture.root / (label + "-transport.json")).write_bytes(transport)
            consumer(fixture, work, label, 7)
            fixture.verified.append(
                label + "_transport_exact_path_offline_lock_and_Debug_Release"
            )
    finally:
        for key, value in previous.items():
            if value is None:
                fixture.env.pop(key, None)
            else:
                fixture.env[key] = value


def run_regressions(fixture):
    previous_hg = fixture.env.get("HGRCPATH")
    fixture.env["HGRCPATH"] = ""
    try:
        with tempfile.TemporaryDirectory(
            prefix="source-delimiters-", dir=fixture.root
        ) as temporary:
            parent = Path(temporary)
            for kind, hardened in [("git", False), ("git", True), ("hg", False)]:
                local_sources(fixture, parent, kind, hardened)
            # The hardened schema deliberately excludes direct Hg dependencies.
            work, selected = create(parent / "source-delimiter-hg-hardened-policy")
            manifest(work, "hg", "./\u0301Repo:tag", True)
            project = selected / "project.pbxproj"
            before = project.read_bytes()
            result = fixture.cli(work, "install", "--hardened", succeeds=False)
            assert result["diagnostic"]["code"] == "SP-HARDENED-FIELD"
            assert project.read_bytes() == before
            assert not (work / "Pods").exists() and not (work / "Podfile.lock").exists()
            fixture.verified.append(
                "source_delimiter_hg_hardened_preserves_schema_rejection_without_managed_writes"
            )
            scp_sources(fixture, parent)
    finally:
        if previous_hg is None:
            fixture.env.pop("HGRCPATH", None)
        else:
            fixture.env["HGRCPATH"] = previous_hg
