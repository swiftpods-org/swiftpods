#!/usr/bin/env python3
"""Verify cancellation, child cleanup, concurrent mutation and source options."""

import functools
import hashlib
import http.server
import json
import os
import signal
import stat
import subprocess
import tempfile
import threading
import time
import zipfile
from pathlib import Path

from bootstrap import ROOT, environment
from reporting import execute


def main():
    parent = Path(tempfile.mkdtemp(prefix="native-runtime-", dir=ROOT / ".build"))
    print("Runtime fixtures:", parent, flush=True)
    work = parent / "project"
    work.mkdir()
    env = environment()
    env["SWIFTPODS_CACHE_ROOT"] = str(parent / "cache")
    binary = ROOT / ".build/debug/swiftpods"

    def cli(*args, success=True):
        result = subprocess.run(
            [str(binary), *args, "--json"],
            cwd=work,
            env=env,
            capture_output=True,
            text=True,
            timeout=60,
        )
        assert (result.returncode == 0) == success, (args, result.stdout, result.stderr)
        return json.loads(result.stdout)

    module = work / "WaitKit"
    module.mkdir()
    module.joinpath("WaitKit.c").write_text("int wait_value(void) { return 1; }\n")
    module.joinpath("WaitKit.podspec.json").write_text(
        json.dumps({"name": "WaitKit", "version": "1.0", "source_files": "*.c"})
    )
    manifest = "platform :osx, '13.0'\ntarget 'App' do\n pod 'WaitKit', :path => './WaitKit'\nend\n"
    work.joinpath("Podfile").write_text(
        manifest
        + """pre_install do |installer|
  trap('INT') {}; trap('TERM') {}
  child = spawn(RbConfig.ruby, '-e', "trap('INT') {}; trap('TERM') {}; loop { sleep 1 }")
  File.write('ready.json', JSON.generate({ruby: Process.pid, child: child}))
  loop { sleep 1 }
end
"""
    )
    process = subprocess.Popen(
        [str(binary), "install", "--no-integrate", "--json"],
        cwd=work,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        start_new_session=True,
    )
    try:
        deadline = time.monotonic() + 20
        while not work.joinpath("ready.json").exists() and time.monotonic() < deadline:
            assert process.poll() is None, process.communicate()
            time.sleep(0.05)
        assert work.joinpath("ready.json").exists(), "Hook did not start"
        pids = json.loads(work.joinpath("ready.json").read_text())
        busy = cli("install", "--no-integrate", success=False)
        assert busy["diagnostic"]["code"] == "SP-STATE-BUSY", busy
        started = time.monotonic()
        process.send_signal(signal.SIGINT)
        stdout, stderr = process.communicate(timeout=8)
        report = json.loads(stdout)
        assert (
            process.returncode == 130
            and report["exit_status"] == 130
            and time.monotonic() - started < 6
        ), (stdout, stderr)
        assert any(event.get("code") == "SP-CANCELLED" for event in report["events"])
        for pid in pids.values():
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline:
                try:
                    os.kill(pid, 0)
                except ProcessLookupError:
                    break
                time.sleep(0.05)
            else:
                raise AssertionError("Cancelled child survived: " + str(pid))
        state = json.loads(work.joinpath(".swiftpods/state.json").read_text())
        assert state["status"] == "recovery_required" and state["exit_status"] == 130
        cli("recover")
        assert not work.joinpath("Pods").exists()
    finally:
        if process.poll() is None:
            process.kill()
            process.communicate()
    # Real concurrent HTTP requests; a content-store lock must not span the network.
    web = parent / "web"
    web.mkdir()
    for name in ("First", "Second"):
        with zipfile.ZipFile(web / (name + ".zip"), "w") as archive:
            archive.writestr(
                name + "/Sources/" + name + ".c",
                "int " + name.lower() + "(void) { return 1; }\n",
            )
            archive.writestr(name + "/unused.txt", "remove during clean")
            archive.writestr(name + "/keep.txt", "preserve")
    active = 0
    maximum = 0
    lock = threading.Lock()

    class Handler(http.server.SimpleHTTPRequestHandler):
        def do_GET(self):
            nonlocal active, maximum
            with lock:
                active += 1
                maximum = max(maximum, active)
            try:
                time.sleep(0.2)
                super().do_GET()
            finally:
                with lock:
                    active -= 1

        def log_message(self, *args):
            pass

    server = http.server.ThreadingHTTPServer(
        ("127.0.0.1", 0), functools.partial(Handler, directory=web)
    )
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    catalog = parent / "catalog"
    for name in ("First", "Second"):
        path = catalog / name / "1.0" / (name + ".podspec.json")
        path.parent.mkdir(parents=True)
        path.write_text(
            json.dumps(
                {
                    "name": name,
                    "version": "1.0",
                    "source": {
                        "http": f"http://127.0.0.1:{server.server_port}/{name}.zip",
                        "sha256": hashlib.sha256(
                            web.joinpath(name + ".zip").read_bytes()
                        ).hexdigest(),
                    },
                    "source_files": "Sources/*.c",
                    "preserve_paths": "keep.txt",
                    "prepare_command": "printf prepared >> '"
                    + str(parent / (name + "-prepare"))
                    + "'",
                }
            )
        )
    manifest = f"platform :osx, '13.0'\nsource '{catalog}'\ninstall! 'swiftpods', :parallel_pod_downloads => true, :parallel_pod_download_thread_pool_size => 2, :incremental_installation => true, :preserve_pod_file_structure => true\ntarget 'App' do\n pod 'First'\n pod 'Second'\nend\n"
    work.joinpath("Podfile").write_text(manifest)
    try:
        cli("install", "--no-integrate")
        assert maximum == 2, maximum
        for name in ("First", "Second"):
            root = work / "Pods" / name
            assert (
                not root.joinpath("unused.txt").exists()
                and root.joinpath("keep.txt").exists()
            )
            assert (
                root.joinpath("Sources/" + name + ".c").stat().st_mode & stat.S_IWUSR
                == 0
            )
        generated = subprocess.check_output(
            [
                "plutil",
                "-convert",
                "json",
                "-o",
                "-",
                str(work / "Pods/Pods.xcodeproj/project.pbxproj"),
            ],
            text=True,
        )
        objects = json.loads(generated)["objects"]
        assert any(
            obj["isa"] == "PBXGroup" and obj.get("name") == "Sources"
            for obj in objects.values()
        )
        cli("install", "--no-integrate", "--offline")
        cli("install", "--no-integrate", "--offline", "--deployment")
        assert all(
            parent.joinpath(name + "-prepare").read_text() == "prepared"
            for name in ("First", "Second")
        )
        # clean_install bypasses prepared/incremental sources; user options control cleaning and permissions.
        work.joinpath("Podfile").write_text(
            manifest.replace(
                ":preserve_pod_file_structure => true",
                ":clean => false, :lock_pod_sources => false",
            )
        )
        cli("install", "--no-integrate", "--clean-install")
        for name in ("First", "Second"):
            root = work / "Pods" / name
            assert (
                root.joinpath("unused.txt").exists()
                and root.joinpath("Sources/" + name + ".c").stat().st_mode
                & stat.S_IWUSR
            )
            assert parent.joinpath(name + "-prepare").read_text() == "preparedprepared"
    finally:
        server.shutdown()
        server.server_close()
        thread.join()
    report = {
        "status": "passed",
        "engine": "swift",
        "fixture": str(parent),
        "verified": [
            "SIGINT cancellation with Ruby and descendant SIGINT/SIGTERM traps",
            "bounded child group cleanup and exit status 130",
            "concurrent install rejection and rollback after cancellation",
            "overlapping HTTP downloads with bounded pool",
            "clean and preserve_paths source effects",
            "lock_pod_sources permissions",
            "preserve_pod_file_structure PBX hierarchy",
            "incremental/offline/deployment installs avoid repeated prepare",
            "clean-install bypass and explicit clean/lock opt-outs",
        ],
        "unverified": ["cancellation during remote authenticated operations"],
    }
    ROOT.joinpath("test-results/native-runtime.json").write_text(
        json.dumps(report, indent=2) + "\n"
    )
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    execute(main, "native-runtime.json")
