"""ASCII option boundaries reject malformed arguments before evaluating project code."""

import json
import tempfile
from pathlib import Path

from bootstrap import project_state_directory
from command_option_regressions import snapshot
from input_contract_regressions import commit, git

PREFIXES = ["-\u0301", "-\ufe0f"]


def diagnostic(report, code):
    assert any(
        value.get("code") == code
        for value in report.get("events", []) + [report.get("diagnostic", {})]
    ), report


def podspec(work, name):
    path = work / name
    path.write_text(
        "File.write(File.join(__dir__, 'executed'), 'marker')\n"
        "Pod::Spec.new do |s|\n"
        " s.name = 'PrefixKit'\n s.version = '1.0'\n"
        " s.summary = 'Option boundary fixture'\n"
        " s.homepage = 'https://example.invalid/PrefixKit'\n"
        " s.author = { 'Fixture' => 'fixture@example.invalid' }\n"
        " s.license = { :type => 'MIT' }\n"
        " s.source = { :git => 'https://example.invalid/PrefixKit.git', :tag => '1.0' }\n"
        " s.source_files = 'Kit.c'\nend\n"
    )
    (work / "Kit.c").write_text("int prefix_value(void) { return 7; }\n")
    return path


def run_regressions(fixture):
    original_cache = fixture.env["SWIFTPODS_CACHE_ROOT"]
    try:
        with tempfile.TemporaryDirectory(
            prefix="option-prefix-", dir=fixture.root
        ) as temporary:
            parent = Path(temporary)
            cache = parent / "cache"
            fixture.env["SWIFTPODS_CACHE_ROOT"] = str(cache)
            for action in ["spec", "lib"]:
                for number, prefix in enumerate(["-", *PREFIXES]):
                    label = action + "-flag-" + str(number)
                    work = parent / label
                    work.mkdir()
                    path = podspec(work, prefix + "PrefixKit.podspec")
                    before = snapshot(work)
                    diagnostic(
                        fixture.cli(
                            work, action, "lint", path.name, "--quick", succeeds=False
                        ),
                        "SP-CLI-ARGUMENT",
                    )
                    assert snapshot(work) == before
                    fixture.verified.append(
                        "option_prefix_" + label + "_does_not_evaluate_podspec"
                    )
                for number, name in enumerate(
                    [
                        "-\u0301PrefixKit.podspec",
                        "-\ufe0fPrefixKit.podspec",
                        "\u0301PrefixKit.podspec",
                        "−PrefixKit.podspec",
                    ]
                ):
                    label = action + "-path-" + str(number)
                    work = parent / label
                    work.mkdir()
                    path = podspec(work, name)
                    original = path.read_bytes()
                    argument = "./" + name if name.startswith("-") else name
                    report = fixture.cli(work, action, "lint", argument, "--quick")
                    assert any(
                        value.get("kind") == "validation" for value in report["events"]
                    )
                    assert (
                        work / "executed"
                    ).read_text() == "marker" and path.read_bytes() == original
                    fixture.verified.append(
                        "option_prefix_" + label + "_remains_a_valid_path"
                    )
            for number, prefix in enumerate(PREFIXES):
                token = prefix + "unknown"
                for action in ["list", "clean"]:
                    work = parent / ("cache-" + action + "-" + str(number))
                    work.mkdir()
                    diagnostic(
                        fixture.cli(work, "cache", action, token, succeeds=False),
                        "SP-CLI-ARGUMENT",
                    )
                    fixture.verified.append(
                        "option_prefix_cache_"
                        + action
                        + "_"
                        + str(number)
                        + "_rejects_unknown_flag"
                    )
                work = parent / ("update-" + str(number))
                work.mkdir()
                body = "File.write(File.join(__dir__, 'executed'), 'marker')\nraise 'must not execute'\n"
                (work / "Podfile").write_text(body)
                diagnostic(
                    fixture.cli(work, "update", token, "--offline", succeeds=False),
                    "SP-CLI-ARGUMENT",
                )
                assert (
                    not (work / "executed").exists()
                    and (work / "Podfile").read_text() == body
                )
                fixture.verified.append(
                    "option_prefix_update_" + str(number) + "_does_not_evaluate_podfile"
                )
                for refresh in [False, True]:
                    work = parent / ("why-" + str(number) + "-" + str(refresh))
                    work.mkdir()
                    (work / "Podfile").write_text(body)
                    project_state_directory(work).mkdir(parents=True)
                    (project_state_directory(work) / "installation.json").write_text(
                        json.dumps({"specs": [], "targets": []})
                    )
                    before = snapshot(work)
                    arguments = ["why", token] + (["--refresh"] if refresh else [])
                    diagnostic(
                        fixture.cli(work, *arguments, succeeds=False), "SP-CLI-ARGUMENT"
                    )
                    assert snapshot(work) == before
                    fixture.verified.append(
                        "option_prefix_why_"
                        + str(number)
                        + "_"
                        + str(refresh)
                        + "_rejects_flag"
                    )
                work = parent / ("repository-" + str(number))
                work.mkdir()
                diagnostic(
                    fixture.cli(
                        work, "repo", "add", "invalid-url", token, succeeds=False
                    ),
                    "SP-REPO-URL",
                )
                diagnostic(
                    fixture.cli(
                        work,
                        "repo",
                        "add-cdn",
                        "invalid-branch",
                        "https://example.invalid/",
                        token,
                        succeeds=False,
                    ),
                    "SP-REPO-URL",
                )
                assert not (cache / "repositories").exists()
                fixture.verified.append(
                    "option_prefix_repository_"
                    + str(number)
                    + "_rejects_url_and_branch"
                )
                registry = cache / "repositories"
                registry.mkdir(parents=True)
                record = registry / "malformed.json"
                record.write_text(
                    json.dumps({"name": "malformed", "url": token, "kind": "cdn"})
                )
                try:
                    before = snapshot(registry)
                    diagnostic(
                        fixture.cli(work, "repo", "list", succeeds=False),
                        "SP-REPO-RECORD",
                    )
                    assert snapshot(registry) == before
                finally:
                    record.unlink()
                    registry.rmdir()
                fixture.verified.append(
                    "option_prefix_repository_record_"
                    + str(number)
                    + "_rejects_flag_url"
                )
            work = parent / "publication"
            work.mkdir()
            origin = work / "-\u0301origin"
            origin.mkdir()
            git(origin, "init", "-b", "main")
            (origin / "README").write_text("fixture\n")
            commit(origin, "fixture")
            fixture.cli(work, "repo", "add", "prefix-fixture", "./" + origin.name)
            path = podspec(work, "-\u0301PrefixKit.podspec")
            checkout = cache / "repositories/prefix-fixture"
            revision = git(checkout, "rev-parse", "HEAD")
            before = snapshot(checkout)
            record = cache / "repositories/prefix-fixture.json"
            record_bytes = record.read_bytes()
            fixture.verified.append(
                "option_prefix_relative_git_repository_path_remains_valid"
            )
            for label, arguments in [
                ("ascii", ["--unknown"]),
                ("combining", [path.name]),
                ("variation", ["-\ufe0funknown"]),
                ("json", ["--platforms", "--json", "osx"]),
                ("local", ["--platforms", "--local-only", "osx"]),
                ("sources", ["--sources", "--json", "https://example.invalid/"]),
                ("swift-version", ["--swift-version", "--json", "5.0"]),
            ]:
                diagnostic(
                    fixture.cli(
                        work,
                        "repo",
                        "push",
                        "prefix-fixture",
                        *arguments,
                        "--local-only",
                        "--quick",
                        succeeds=False,
                    ),
                    "SP-CLI-ARGUMENT",
                )
                assert not (work / "executed").exists()
                assert git(checkout, "rev-parse", "HEAD") == revision
                assert (
                    snapshot(checkout) == before and record.read_bytes() == record_bytes
                )
                fixture.verified.append(
                    "option_prefix_publication_"
                    + label
                    + "_rejects_before_ruby_or_repository_writes"
                )
            report = fixture.cli(
                work,
                "repo",
                "push",
                "prefix-fixture",
                "./" + path.name,
                "--local-only",
                "--quick",
            )
            publication = next(
                value["data"]
                for value in report["events"]
                if value.get("kind") == "publication"
            )
            assert publication["pushed"] is False and publication["name"] == "PrefixKit"
            assert (work / "executed").read_text() == "marker"
            assert git(checkout, "rev-parse", "HEAD") != revision
            assert (checkout / "PrefixKit/1.0/PrefixKit.podspec.json").is_file()
            fixture.verified.append(
                "option_prefix_explicit_relative_publication_path_remains_valid"
            )
    finally:
        fixture.env["SWIFTPODS_CACHE_ROOT"] = original_cache
