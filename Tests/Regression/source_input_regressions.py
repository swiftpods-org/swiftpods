"""Pinned VCS inputs and format-aware, checksum-bound HTTP source downloads."""

import functools
import hashlib
import http.server
import json
import shutil
import subprocess
import threading
import zipfile
from contextlib import contextmanager

from Tests.Integration.native_xcconfig_tests import create
from Tests.Regression.input_contract_regressions import commit, git


def mutable_checkout_case(parent, cli, env, vcs):
    work, _ = create(parent)
    repository = work / "Kit"
    selector = ("commit", "main") if vcs == "git" else ("revision", "tip")

    def revision(message):
        if vcs == "git":
            return commit(repository, message)
        subprocess.run(
            ["hg", "--cwd", str(repository), "addremove"],
            check=True,
            capture_output=True,
        )
        subprocess.run(
            ["hg", "--cwd", str(repository), "commit", "-u", "Fixture", "-m", message],
            check=True,
            capture_output=True,
        )
        return subprocess.check_output(
            ["hg", "--cwd", str(repository), "log", "-r", ".", "--template", "{node}"],
            text=True,
        )

    if vcs == "git":
        git(repository, "init", "-b", "main")
    else:
        subprocess.run(["hg", "init", str(repository)], check=True, capture_output=True)
    first = revision("first")
    text = (
        "platform :osx, '13.0'\ninstall! 'cocoapods', :integrate_targets => false\ntarget 'App' do\n pod 'Kit', :"
        + vcs
        + " => "
        + repr(str(repository))
        + ", :"
        + selector[0]
        + " => "
        + repr(selector[1])
        + "\nend\n"
    )
    (work / "Podfile").write_text(text)
    cli(work, "install")
    lock = (work / "Podfile.lock").read_bytes()
    before = (work / "Pods/Kit/Kit.c").read_bytes()
    (repository / "Kit.c").write_text("int kit_value(void) { return 9; }\n")
    second = revision("second")
    shutil.rmtree(work / "Pods")
    cache_keys = ["SWIFTPODS_CACHE_ROOT", "CP_CACHE_DIR"]
    previous = {key: env.get(key) for key in cache_keys}
    try:
        for key in cache_keys:
            env[key] = str(parent / ("fresh-" + key))
        cli(work, "install")
        preserved = (work / "Pods/Kit/Kit.c").read_bytes() == before
        unchanged_lock = (work / "Podfile.lock").read_bytes() == lock
        cli(work, "install", "--deployment")
        deployment_preserved = (work / "Pods/Kit/Kit.c").read_bytes() == before
        cli(work, "update", "Kit")
        updated = "return 9;" in (work / "Pods/Kit/Kit.c").read_text()
    finally:
        for key, value in previous.items():
            if value is None:
                env.pop(key, None)
            else:
                env[key] = value
    return {
        "vcs": vcs,
        "input_sha256": hashlib.sha256(
            text.replace(str(repository), "<repository>").encode()
        ).hexdigest(),
        "first": first,
        "second": second,
        "preserved": preserved,
        "deployment_preserved": deployment_preserved,
        "unchanged_lock": unchanged_lock,
        "immutable_lock": first.encode() in lock,
        "updated": updated,
    }


@contextmanager
def server_for(web):
    requests = []

    class Handler(http.server.SimpleHTTPRequestHandler):
        def do_GET(self):
            requests.append(self.path)
            super().do_GET()

        def log_message(self, *args):
            pass

    server = http.server.ThreadingHTTPServer(
        ("127.0.0.1", 0), functools.partial(Handler, directory=str(web))
    )
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield "http://127.0.0.1:" + str(server.server_port), requests
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


def http_inputs(fixture):
    web = fixture.root / "http-input-web"
    web.mkdir()
    with server_for(web) as (base, requests):
        for scenario in ["serial", "parallel", "without-checksum", "zip-layout"]:
            work, _ = create(fixture.root / ("http-input-" + scenario))
            specfile = work.parent / "remote.podspec.json"
            data = json.loads((work / "Kit/Kit.podspec.json").read_text())
            filename = scenario + ".zip"
            location = base + "/" + filename
            prefix = "Kit/" if scenario == "zip-layout" else ""
            if prefix:
                data["source_files"] = "Kit/*.{c,h}"

            def archive(value, version):
                with zipfile.ZipFile(web / filename, "w") as output:
                    output.writestr(prefix + "Kit.h", (work / "Kit/Kit.h").read_text())
                    output.writestr(
                        prefix + "Kit.c",
                        "int kit_value(void) { return " + str(value) + "; }\n",
                    )
                data["version"] = version
                data["source"] = {"http": location}
                if scenario != "without-checksum":
                    data["source"]["sha256"] = hashlib.sha256(
                        (web / filename).read_bytes()
                    ).hexdigest()
                specfile.write_text(json.dumps(data))
                return specfile.read_bytes()

            first = archive(7, "1.0")
            options = (
                "install! 'cocoapods', :parallel_pod_downloads => true\n"
                if scenario == "parallel"
                else ""
            )
            (work / "Podfile").write_text(
                "platform :osx, '13.0'\n"
                + options
                + "project '../Apps/External.xcodeproj'\ntarget 'Demo' do\n pod 'Kit', :podspec => "
                + repr(str(specfile))
                + "\nend\n"
            )
            fixture.cli(work, "install")
            source = work / ("Pods/Kit/Kit/Kit.c" if prefix else "Pods/Kit/Kit.c")
            assert "return 7;" in source.read_text()
            count = len(requests)
            fixture.cli(work, "install")
            fixture.cli(work, "install", "--deployment", "--offline")
            assert len(requests) == count, requests
            if prefix:
                fixture.build(work, "Demo", "zip-default-layout-build")
                fixture.verified.append(
                    "zip_default_layout_preserves_declared_sources_and_builds"
                )
                continue
            second = archive(9, "1.1" if scenario != "without-checksum" else "1.0")
            fixture.cli(work, "update", "Kit")
            assert "return 9;" in source.read_text() and len(requests) > count
            if scenario != "without-checksum":
                specfile.write_bytes(first)
                fixture.cli(work, "update", "Kit", "--offline")
                assert "return 7;" in source.read_text()
                specfile.write_bytes(second)
                fixture.cli(work, "update", "Kit", "--offline")
                assert "return 9;" in source.read_text()
            fixture.verified.append(
                "http_"
                + scenario
                + "_targeted_update_refreshes_and_preserves_checksum_cache"
            )


def run(fixture):
    for vcs in ["git", "hg"]:
        result = mutable_checkout_case(
            fixture.root / ("mutable-" + vcs), fixture.cli, fixture.env, vcs
        )
        assert (
            result["preserved"]
            and result["deployment_preserved"]
            and result["unchanged_lock"]
            and result["immutable_lock"]
            and result["updated"]
        ), result
        fixture.verified.append(
            vcs + "_symbolic_selector_preserves_checkout_until_update"
        )
    http_inputs(fixture)
