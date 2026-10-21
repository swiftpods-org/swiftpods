"""Exercise bundle containment and external-Ruby policy through the actual CLI."""

import hashlib
import json
import shlex
import shutil
import subprocess
import tempfile
from pathlib import Path

from bootstrap import project_state_directory


def runtime_boundaries(parent, binary, env, bundle):
    observations = {}
    ruby = subprocess.check_output(
        [
            env["SWIFTPODS_RUBY"],
            "-rjson",
            "-rrbconfig",
            "-e",
            "puts({engine: RUBY_ENGINE, version: RUBY_VERSION, abi: RbConfig::CONFIG.fetch('ruby_version'), architecture: RbConfig::CONFIG.fetch('host_cpu'), platform: RUBY_PLATFORM, library: File.join(RbConfig::CONFIG.fetch('libdir'), RbConfig::CONFIG.fetch('LIBRUBY_SO'))}.to_json)",
        ],
        env=env,
        text=True,
    ).strip()
    for case, filename, code in [
        ("ordinary-file", "\u0301payload.txt", None),
        ("contained-alias", "\u0301alias.rb", None),
        ("runtime-directory", "runtime/\u0301ruby", "SP-RUNTIME-PROFILE"),
        ("vendor-directory", "vendor/\u0301engine.rb", "SP-RUNTIME-ENGINE"),
        ("gems-directory", "gems/\u0301engine.rb", "SP-RUNTIME-ENGINE"),
        ("bundled-ruby", "\u0301ruby", "SP-RUBY-PATH"),
        ("escaping-alias", "host/\u0301escape.rb", "SP-RUNTIME-INTEGRITY"),
    ]:
        with tempfile.TemporaryDirectory(
            prefix="bundle-path-", dir=parent
        ) as temporary:
            scope = Path(temporary)
            root = scope / "bundle"
            shutil.copytree(bundle, root, symlinks=True)
            manifest = json.loads((root / "compatibility.json").read_text())
            manifest["status"] = "prototype"
            file = root / filename
            file.parent.mkdir(parents=True, exist_ok=True)
            selected_env = dict(env, SWIFTPODS_BUNDLE=str(root))
            marker = scope / "probe-ran"
            if case in ("contained-alias", "escaping-alias"):
                target = "host/dsl.rb"
                if case == "escaping-alias":
                    target = str(scope / "outside.rb")
                    Path(target).write_text("outside fixture\n")
                file.symlink_to(target)
                manifest["files"][filename] = {"symlink": target}
            else:
                content = "fixture\n"
                if case == "bundled-ruby":
                    content = (
                        "#!/bin/sh\nprintf ran > "
                        + shlex.quote(str(marker))
                        + "\nprintf '%s\\n' "
                        + shlex.quote(ruby)
                        + "\n"
                    )
                    selected_env["SWIFTPODS_RUBY"] = str(file)
                file.write_text(content)
                file.chmod(0o755 if case == "bundled-ruby" else 0o644)
                manifest["files"][filename] = {
                    "sha256": hashlib.sha256(file.read_bytes()).hexdigest()
                }
            manifest["bundle_digest"] = hashlib.sha256(
                json.dumps(manifest["files"], sort_keys=True).encode()
            ).hexdigest()
            (root / "compatibility.json").write_text(
                json.dumps(manifest, indent=2) + "\n"
            )
            project = scope / "project"
            project.mkdir()
            (project / "Podfile").write_text(
                "raise 'Runtime_checks_must_not_execute_project_code'\n"
            )
            result = subprocess.run(
                [str(binary), "runtime", "verify", "--json"],
                cwd=project,
                env=selected_env,
                capture_output=True,
                text=True,
                timeout=60,
            )
            log = parent / ("bundle-path-" + case + ".log")
            log.write_text(result.stdout + result.stderr)
            report = json.loads(result.stdout)
            actual = report.get("diagnostic", {}).get("code")
            assert (result.returncode == 0) == (code is None), log
            assert actual == code, (case, report, log)
            assert not marker.exists(), "A bundled Ruby probe executed before rejection"
            assert not project_state_directory(project).exists()
            observations[case] = {
                "exit_status": result.returncode,
                "diagnostic": actual,
            }
    return observations
