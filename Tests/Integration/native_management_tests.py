#!/usr/bin/env python3
"""Exercise Git pins, repository/cache commands, inspection and plugin callbacks."""

import json
import shutil
import subprocess
from pathlib import Path

from scripts.support.bootstrap import environment
from scripts.support.local_build import (
    debug_binary,
    fixture_directory,
    results_directory,
)
from scripts.support.reporting import execute


def main():
    parent = fixture_directory("native-management-")
    print("Management fixtures:", parent, flush=True)
    env = environment()
    env.update(
        SWIFTPODS_CACHE_ROOT=str(parent / "cache"),
        GEM_HOME=str(parent / "empty-gems"),
        GEM_PATH=str(parent / "empty-gems"),
    )
    work = parent / "project"
    work.mkdir()
    binary = debug_binary()

    def cli(*arguments, success=True):
        result = subprocess.run(
            [str(binary), *map(str, arguments), "--json"],
            cwd=work,
            env=env,
            capture_output=True,
            text=True,
            timeout=90,
        )
        assert (result.returncode == 0) == success, (
            arguments,
            result.stdout,
            result.stderr,
        )
        return json.loads(result.stdout)

    def git(directory, *arguments):
        return subprocess.check_output(
            ["git", "-C", str(directory), *arguments], text=True, stderr=subprocess.PIPE
        ).strip()

    def commit(directory, text):
        git(directory, "add", ".")
        git(
            directory,
            "-c",
            "user.name=Fixture",
            "-c",
            "user.email=fixture@swiftpods.org",
            "commit",
            "-m",
            text,
        )
        return git(directory, "rev-parse", "HEAD")

    origin = parent / "origin"
    origin.mkdir()
    git(origin, "init", "-b", "main")
    origin.joinpath("Pinned.c").write_text("int pinned_value(void) { return 1; }\n")
    origin.joinpath("Pinned.podspec.json").write_text(
        json.dumps(
            {
                "name": "Pinned",
                "version": "1.0",
                "source": {"git": str(origin), "branch": "main"},
                "source_files": "*.c",
            }
        )
    )
    first = commit(origin, "first")
    work.joinpath("Podfile").write_text(
        f"platform :osx, '13.0'\ntarget 'App' do\n  pod 'Pinned', :git => '{origin}', :branch => 'main'\nend\n"
    )
    cli("install", "--no-integrate")
    assert first in work.joinpath("Podfile.lock").read_text()
    origin.joinpath("Pinned.c").write_text("int pinned_value(void) { return 2; }\n")
    second = commit(origin, "second")
    # A branch advances upstream, but install in an entirely fresh cache honors the lock revision.
    env["SWIFTPODS_CACHE_ROOT"] = str(parent / "fresh-cache")
    cli("install", "--no-integrate", "--deployment")
    assert "return 1" in work.joinpath("Pods/Pinned/Pinned.c").read_text()
    cli("update", "Pinned", "--no-integrate")
    assert second in work.joinpath("Podfile.lock").read_text()
    assert "return 2" in work.joinpath("Pods/Pinned/Pinned.c").read_text()
    lock = work.joinpath("Podfile.lock").read_bytes()
    cli("install", "--deployment", "--offline", "--no-integrate")
    assert lock == work.joinpath("Podfile.lock").read_bytes()
    entries = cli("cache", "list", "Pinned")["entries"]
    assert entries and all("Pinned" in entry["pods"] for entry in entries)
    cli("cache", "clean", success=False)
    sentinel = Path(env["SWIFTPODS_CACHE_ROOT"]) / "git/keep-user-files"
    sentinel.mkdir(parents=True)
    sentinel.joinpath("user.txt").write_text("keep")
    assert cli("cache", "clean", "Pinned")["removed"] > 0
    assert sentinel.joinpath("user.txt").read_text() == "keep"
    # Register a real local specs repository, update its snapshot and inspect metadata.
    specs = parent / "specs"
    specs.mkdir()
    git(specs, "init", "-b", "main")

    def catalog(version):
        path = specs / "CatalogKit" / version / "CatalogKit.podspec.json"
        path.parent.mkdir(parents=True)
        path.write_text(
            json.dumps(
                {
                    "name": "CatalogKit",
                    "version": version,
                    "source": {"git": str(origin), "branch": "main"},
                    "source_files": "*.c",
                }
            )
        )

    catalog("1.0")
    commit(specs, "catalog first")
    cli("repo", "add", "catalog", specs, "main")
    assert cli("repo", "list")["repositories"][0]["name"] == "catalog"

    def data(report):
        return next(
            event["data"] for event in report["events"] if event["kind"] == "inspection"
        )

    assert (
        data(cli("spec", "cat", "CatalogKit", "--sources", str(specs)))["version"]
        == "1.0"
    )
    paths = data(cli("spec", "which", "CatalogKit", "--sources", str(specs)))
    assert json.loads(Path(paths[0]).read_text())["name"] == "CatalogKit"
    catalog("2.0")
    commit(specs, "catalog second")
    cli("repo", "update", "catalog")
    assert (
        data(
            cli(
                "spec", "cat", "CatalogKit", "--version", "2.0", "--sources", str(specs)
            )
        )["version"]
        == "2.0"
    )
    checkout = Path(env["SWIFTPODS_CACHE_ROOT"]) / "repositories/catalog"
    checkout.joinpath("user.txt").write_text("dirty")
    cli("repo", "update", "catalog", success=False)
    cli("repo", "remove", "catalog", success=False)
    checkout.joinpath("user.txt").unlink()
    cli("repo", "remove", "catalog")
    assert cli("repo", "list")["repositories"] == []
    cli("repo", "add", "../outside", specs, success=False)
    assert data(cli("ipc", "spec", origin / "Pinned.podspec.json"))["name"] == "Pinned"
    assert (
        data(cli("ipc", "podfile", "Podfile"))["targets"][0]["dependencies"][0]["name"]
        == "Pinned"
    )
    inheritance = work / "Nested.Podfile"
    inheritance.write_text(
        "target 'Outer' do\n pod 'OuterKit'\n target 'Search' do\n  inherit! :search_paths\n  target 'CompleteChild' do\n  end\n  target 'NoneChild' do\n   inherit! :none\n   pod 'OwnKit'\n  end\n end\nend\n"
    )
    targets = {
        target["name"]: target
        for target in data(cli("ipc", "podfile", inheritance))["targets"]
    }
    assert targets["CompleteChild"]["search_dependencies"][0]["name"] == "OuterKit"
    assert (
        targets["NoneChild"]["search_dependencies"][0]["name"] == "OuterKit"
        and targets["NoneChild"]["dependencies"][0]["name"] == "OwnKit"
    )
    assert (
        targets["NoneChild"]["dependencies"][0]["options"].get("configurations") is None
    )
    # Actual plugin registration, source-provider callback, options, whitelist and lifecycle.
    work.joinpath("batchplugin.rb").write_text(f"""require 'cocoapods/hooks_manager'
require 'cocoapods/installer/pre_install_hooks_context'
require 'cocoapods/installer/post_install_hooks_context'
require 'cocoapods/installer/source_provider_hooks_context'
def batch_trace(value); File.open('plugin-trace', 'a') {{ |file| file.puts(value) }}; end
Pod::HooksManager.register('undeclared-plugin', :pre_install) {{ raise 'Undeclared plugin ran' }}
Pod::HooksManager.register('batchplugin', :pre_install) do |context, options|
  raise 'Wrong context' unless context.is_a?(Pod::Installer::PreInstallHooksContext) && context.sandbox.root.to_s.end_with?('/Pods')
  raise 'Wrong options' unless options[:flag] == 'ok'
  batch_trace('plugin-pre')
end
Pod::HooksManager.register('batchplugin', :source_provider) do |context|
  context.add_source(Pod::Source.new('{specs}')); batch_trace('plugin-source')
end
Pod::HooksManager.register('batchplugin', :post_install) do |context|
  raise 'Lock is missing at plugin post_install' unless File.file?('Podfile.lock')
  raise 'Wrong context' unless context.is_a?(Pod::Installer::PostInstallHooksContext)
  context.pods_project.build_configurations.each {{ |config| config.build_settings['PLUGIN_RESULT'] = 'ok' }} if context.pods_project
  batch_trace('plugin-post')
end
""")
    work.joinpath("Podfile").write_text(
        "$LOAD_PATH.unshift(Dir.pwd)\nplugin 'batchplugin', :flag => 'ok'\nplatform :osx, '13.0'\ntarget 'App' do\n  pod 'CatalogKit', '= 1.0'\nend\npre_install { |installer| batch_trace('pod-pre') }\npre_integrate { raise 'No integration requested' }\npost_install { |installer| batch_trace('pod-post') }\npost_integrate { raise 'No integration requested' }\n"
    )
    work.joinpath("Podfile.lock").unlink()
    cli("install", "--no-integrate")
    assert work.joinpath("plugin-trace").read_text().splitlines() == [
        "plugin-pre",
        "plugin-source",
        "pod-pre",
        "pod-post",
        "plugin-post",
    ]
    assert (
        "PLUGIN_RESULT"
        in work.joinpath("Pods/Pods.xcodeproj/project.pbxproj").read_text()
    )
    # Generation disabled has nil projects but continues manifest hooks and writes lock.
    work.joinpath("Podfile").write_text(
        work.joinpath("Podfile")
        .read_text()
        .replace(
            "platform :osx",
            "install! 'cocoapods', :skip_pods_project_generation => true\nplatform :osx",
        )
        .replace(
            "post_install { |installer| batch_trace('pod-post') }",
            "post_install { |installer| raise 'Expected nil project' if installer.pods_project; batch_trace('pod-post') }",
        )
    )
    shutil.rmtree(work / "Pods/Pods.xcodeproj")
    cli("install", "--no-integrate")
    assert not work.joinpath("Pods/Pods.xcodeproj").exists()
    report = {
        "status": "passed",
        "engine": "swift",
        "fixture": str(parent),
        "verified": [
            "Git CHECKOUT OPTIONS pin across fresh cache and upstream branch advance",
            "selected pod update and offline deployment",
            "Git cache list/clean and unowned file preservation",
            "repo add/list/update/remove with dirty-checkout rejection",
            "spec cat/which and ipc spec/podfile",
            "typed plugin contexts and option lookup",
            "plugin source-provider resolution and undeclared-plugin filtering",
            "lockfile and hook lifecycle ordering",
            "skip_pods_project_generation",
        ],
        "unverified": [
            "full private plugin APIs",
            "repository publication",
            "all command aliases",
            "remote SSH authentication",
        ],
    }
    results_directory().joinpath("native-management.json").write_text(
        json.dumps(report, indent=2) + "\n"
    )
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    execute(main, "native-management.json")
