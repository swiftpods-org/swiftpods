"""Concurrent source refreshes must preserve the revision already selected by a consumer."""

import json
import subprocess
import time
from pathlib import Path


def concurrent_source_refresh(fixture):
    for vcs in ["git", "hg", "svn"]:
        root = fixture.root / ("concurrent-source-" + vcs)
        source = root / "source"
        source.mkdir(parents=True)
        ready, release = root / "ready", root / "release"

        def command(*args):
            return subprocess.check_output(args, stderr=subprocess.STDOUT, text=True).strip()

        if vcs == "git":
            command("git", "-C", str(source), "init", "-b", "main")
            location = str(source)
        elif vcs == "hg":
            command("hg", "init", str(source))
            location = str(source)
        else:
            repository = root / "origin"
            command("svnadmin", "create", str(repository))
            location = repository.as_uri()
            command("svn", "checkout", location, str(source))

        def commit(version, value):
            (source / "Kit.c").write_text("int value(void) { return " + str(value) + "; }\n")
            (source / "Kit.podspec").write_text(
                "Pod::Spec.new do |s|\n s.name = 'Kit'\n s.version = " + repr(version)
                + "\n s.osx.deployment_target = '13.0'\n s.source_files = '*.c'\n"
                + " if ENV['AUDIT_PAUSE'] == '1' && !File.exist?(" + repr(str(release)) + ")\n"
                + "  File.write(" + repr(str(ready)) + ", 'ready')\n"
                + "  sleep 0.05 until File.exist?(" + repr(str(release)) + ")\n end\nend\n")
            if vcs == "git":
                command("git", "-C", str(source), "add", ".")
                command("git", "-C", str(source), "-c", "user.name=Fixture", "-c",
                        "user.email=fixture@example.invalid", "commit", "-m", version)
                return command("git", "-C", str(source), "rev-parse", "HEAD")
            if vcs == "hg":
                command("hg", "--cwd", str(source), "addremove")
                command("hg", "--cwd", str(source), "commit", "-u", "Fixture", "-m", version)
                return command("hg", "--cwd", str(source), "log", "-r", ".", "--template", "{node}")
            command("svn", "add", "--force", str(source))
            command("svn", "commit", str(source), "-m", version)
            return command("svn", "info", "--show-item", "revision", location)

        first = commit("1.0", 1)
        for name in ["A", "B"]:
            work = root / name
            work.mkdir()
            requirement = "'= 1.0', " if name == "A" else ""
            (work / "Podfile").write_text(
                "install! 'cocoapods', :integrate_targets => false\nplatform :osx, '13.0'\n"
                "target 'App' do\n pod 'Kit', " + requirement + ":" + vcs + " => " + repr(location) + "\nend\n")
        environment = dict(fixture.env, AUDIT_PAUSE="1")
        output, errors = root / "paused-install.json", root / "paused-install.log"
        with output.open("w") as stdout, errors.open("w") as stderr:
            process = subprocess.Popen([str(fixture.binary), "install", "--json"], cwd=root / "A",
                                       env=environment, stdout=stdout, stderr=stderr)
            try:
                deadline = time.monotonic() + 30
                while not ready.exists():
                    assert process.poll() is None and time.monotonic() < deadline, (output, errors)
                    time.sleep(0.05)
                second = commit("2.0", 2)
                fixture.cli(root / "B", "update", "Kit", "--no-repo-update")
                release.write_text("go")
                assert process.wait(timeout=45) == 0, (output, errors)
            finally:
                release.write_text("go")
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=10)
        assert json.loads(output.read_text())["exit_status"] == 0
        work = root / "A"
        lock = (work / "Podfile.lock").read_bytes()
        revision = "commit" if vcs == "git" else "revision"
        assert ("    ':" + revision + "': '" + first + "'\n").encode() in lock, lock
        assert ("    ':" + revision + "': '" + second + "'\n").encode() not in lock, lock
        assert "Kit (1.0)" in lock.decode()
        assert "return 1;" in (work / "Pods/Kit/Kit.c").read_text()
        assert json.loads((work / "Pods/Local Podspecs/Kit.podspec.json").read_text())["version"] == "1.0"
        fixture.cli(work, "install", "--offline", "--deployment")
        assert (work / "Podfile.lock").read_bytes() == lock
        assert "return 1;" in (work / "Pods/Kit/Kit.c").read_text()
        kind = "git" if vcs == "git" else "snapshots"
        cache = Path(fixture.env["SWIFTPODS_CACHE_ROOT"]) / kind
        copies = []
        for receipt in cache.glob("*.origin.json"):
            metadata = json.loads(receipt.read_text())
            cached = metadata.get("commit") if vcs == "git" else metadata.get("checkout", {}).get("revision")
            if cached == first:
                tree = receipt.with_name(receipt.name.removesuffix(".origin.json"))
                file = tree / "Kit.c"
                copies.append((file, file.stat().st_ino))
        assert copies
        (work / "Podfile").write_text(
            "install! 'cocoapods', :integrate_targets => false\nplatform :osx, '13.0'\n"
            "target 'App' do\n pod 'Kit', '= 1.0', :" + vcs + " => " + repr(location)
            + ", :" + revision + " => " + repr(first) + "\nend\n")
        fixture.cli(work, "update", "Kit", "--no-repo-update")
        assert all(file.stat().st_ino == inode for file, inode in copies)
        fixture.verified.append("concurrent_" + vcs + "_refresh_keeps_selected_revision_and_offline_lock")
