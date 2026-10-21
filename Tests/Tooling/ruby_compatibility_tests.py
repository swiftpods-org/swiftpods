#!/usr/bin/env python3
"""Exercise real Ruby interpreters through native installation and live hooks."""

import argparse
import json
import os
import subprocess
import tempfile
from pathlib import Path

from scripts.support.bootstrap import PROFILE, project_state_directory, runtime_prefix
from scripts.support.local_build import debug_binary, results_directory
from scripts.support.reporting import execute
from scripts.support.ruby_runtime import clean_environment, select_ruby


def verify(ruby, parent):
    _, metadata = select_ruby(PROFILE, {**os.environ, "SWIFTPODS_RUBY": str(ruby)})
    version = metadata["version"]
    work = parent / version
    work.mkdir()
    module = work / "LocalKit"
    module.mkdir()
    module.joinpath("LocalKit.c").write_text(
        "int swiftpods_ruby_compatibility(void) { return 1; }\n"
    )
    spec = module / "LocalKit.podspec"
    spec.write_text("""Pod::Spec.new do |spec|
  spec.name = 'LocalKit'
  spec.version = '1.0.0'
  spec.platform = :ios, '15.4'
  spec.source_files = '*.c'
end
""")
    work.joinpath("Podfile").write_text("""platform :ios, '15.4'
use_frameworks! :linkage => :static
target 'App' do
  pod 'LocalKit', :path => './LocalKit'
  spm 'SwiftKit', :git => 'https://example.invalid/SwiftKit.git', :exact => '1.0.0', :products => ['SwiftKit']
end
pre_install do |installer|
  File.write('pre-ruby.txt', RUBY_VERSION)
end
post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      config.build_settings['SWIFTPODS_RUBY_COMPATIBILITY'] = RUBY_VERSION
    end
  end
  File.write('post-ruby.txt', RUBY_VERSION)
end
""")
    env = clean_environment(os.environ)
    env.update(
        SWIFTPODS_RUBY=str(ruby),
        SWIFTPODS_BUNDLE=str(runtime_prefix()),
        SWIFTPODS_CACHE_ROOT=str(work / "cache"),
        BUNDLER_SETUP="/unavailable/bundler/setup.rb",
        RUBYOPT="-runavailable_swiftpods_library",
    )
    binary = debug_binary()

    def cli(*arguments):
        result = subprocess.run(
            [str(binary), *arguments, "--json"],
            cwd=work,
            env=env,
            text=True,
            capture_output=True,
            timeout=90,
        )
        if result.returncode:
            raise RuntimeError(
                f"Ruby {version}: {arguments}\n{result.stdout}\n{result.stderr}"
            )
        return json.loads(result.stdout)

    runtime = cli("runtime", "verify")
    assert runtime["ruby"]["version"] == version, runtime

    def inspection(*arguments):
        report = cli("ipc", *arguments)
        return next(
            event["data"] for event in report["events"] if event["kind"] == "inspection"
        )

    podfile = inspection("podfile", str(work / "Podfile"))
    assert podfile["targets"][0]["packages"][0]["name"] == "SwiftKit", podfile
    specification = inspection("spec", str(spec))
    assert specification["name"] == "LocalKit", specification
    cli("install", "--no-integrate", "--clean-install")
    cli("install", "--no-integrate", "--offline", "--deployment")
    assert work.joinpath("pre-ruby.txt").read_text() == version
    assert work.joinpath("post-ruby.txt").read_text() == version
    project = json.loads(
        subprocess.check_output(
            [
                "plutil",
                "-convert",
                "json",
                "-o",
                "-",
                str(work / "Pods/Pods.xcodeproj/project.pbxproj"),
            ]
        )
    )
    markers = [
        entry["buildSettings"]["SWIFTPODS_RUBY_COMPATIBILITY"]
        for entry in project["objects"].values()
        if "SWIFTPODS_RUBY_COMPATIBILITY" in entry.get("buildSettings", {})
    ]
    assert markers and set(markers) == {version}, markers
    state = json.loads(project_state_directory(work).joinpath("state.json").read_text())
    assert state["status"] == "complete" and state["exit_status"] == 0, state
    print(
        f"Ruby {version}: Podfile, podspec, SPM declarations, installation, hooks, offline deployment passed",
        flush=True,
    )
    return {"ruby": metadata, "status": "passed", "hook_build_settings": len(markers)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--ruby",
        type=Path,
        action="append",
        help="Absolute interpreter path; repeat for a local matrix",
    )
    args = parser.parse_args()
    rubies = args.ruby or [select_ruby(PROFILE)[0]]
    with tempfile.TemporaryDirectory(prefix="ruby-compatibility-") as temporary:
        results = [verify(ruby.resolve(), Path(temporary)) for ruby in rubies]
    report = {"status": "passed", "engine": "swift", "interpreters": results}
    results_directory().joinpath("ruby-compatibility.json").write_text(
        json.dumps(report, indent=2) + "\n"
    )


if __name__ == "__main__":
    execute(main, "ruby-compatibility.json")
