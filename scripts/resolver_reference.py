#!/usr/bin/env python3
"""Compare deterministic generated dependency graphs against the isolated solver."""

import argparse
import json
import random
import subprocess
import tempfile
from pathlib import Path

from bootstrap import ROOT, environment
from reference_compare import reference_environment
from reporting import execute

RUBY = r"""
require 'bundler/setup'; require 'cocoapods'; require 'json'
Pod::Config.instance.silent = true
cases = JSON.parse(File.read(ARGV.fetch(0)))
results = cases.map do |item|
  podfile = Pod::Podfile.new do
    platform :osx, '13.0'
    target 'App' do
      item.fetch('roots').each { |name, requirement| pod name, requirement }
    end
  end
  begin
    source = Pod::Source.new(Pathname(item.fetch('catalog')))
    resolver = Pod::Resolver.new(Pod::Sandbox.new(item.fetch('sandbox')), podfile, Molinillo::DependencyGraph.new, [source], false)
    graph = resolver.resolve.values.flatten.to_h { |value| [value.spec.root.name, value.spec.version.to_s] }
    {'status' => 'passed', 'versions' => graph}
  rescue Pod::Informative => error
    raise unless error.message.match?(/could not find compatible|circular dependency|Unable to satisfy/i)
    {'status' => 'conflict'}
  rescue ArgumentError => error
    # The reference graph's cycle diagnostic itself fails for the multi-root
    # cycle. Preserve the actual exception in the log; compare rejection only.
    raise unless error.message.match?(/\AThere is no path from \S+ to \S+\z/) && error.backtrace.first.include?('/molinillo/dependency_graph.rb:')
    warn('Reference cycle rejection: ' + error.class.to_s + ': ' + error.message)
    {'status' => 'conflict'}
  end
end
puts JSON.generate(results)
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--gem-home", type=Path, required=True)
    args = parser.parse_args()
    parent = Path(tempfile.mkdtemp(prefix="resolver-reference-", dir=ROOT / ".build"))
    print("Resolver differential fixtures:", parent, flush=True)
    generator = random.Random(1431)
    cases = []
    names = ["A", "B", "C", "D"]
    for index in range(32):
        catalog = parent / str(index) / "catalog"
        catalog.mkdir(parents=True)
        for offset, name in enumerate(names):
            for version in ["1.0", "2.0"]:
                dependencies = {
                    dependency: [generator.choice([">= 1", "< 2", ">= 2"])]
                    for dependency in names[offset + 1 :]
                    if generator.random() < 0.4
                }
                data = {
                    "name": name,
                    "version": version,
                    "platforms": {"osx": "13.0"},
                    "dependencies": dependencies,
                }
                path = catalog / name / version / (name + ".podspec.json")
                path.parent.mkdir(parents=True)
                path.write_text(json.dumps(data))
        roots = [
            [name, generator.choice([">= 0", "< 2", ">= 2"])]
            for name in generator.sample(names, generator.choice([1, 2, 3]))
        ]
        cases.append(
            {
                "catalog": str(catalog),
                "sandbox": str(parent / str(index) / "Pods"),
                "roots": roots,
            }
        )
    regression_cases = [
        (
            [
                {"name": "A", "version": "1.0", "dependencies": {"B": [">= 0"]}},
                {"name": "B", "version": "1.0", "dependencies": {"A": [">= 0"]}},
            ],
            [["A", ">= 0"]],
        ),
        (
            [
                {"name": "A", "version": "1.0", "dependencies": {"B": [">= 0"]}},
                {"name": "B", "version": "1.0", "dependencies": {"C": [">= 0"]}},
                {"name": "C", "version": "1.0", "dependencies": {"A": [">= 0"]}},
            ],
            [["A", ">= 0"], ["C", ">= 0"]],
        ),
        (
            [
                {"name": "A", "version": "2.0", "dependencies": {"B": [">= 0"]}},
                {"name": "A", "version": "1.0"},
                {"name": "B", "version": "1.0", "dependencies": {"A": [">= 0"]}},
            ],
            [["A", ">= 0"]],
        ),
        (
            [
                {
                    "name": "Kit",
                    "version": "1.0",
                    "default_subspecs": ["Core"],
                    "subspecs": [
                        {"name": "Core", "dependencies": {"Helper": [">= 0"]}}
                    ],
                },
                {
                    "name": "Helper",
                    "version": "1.0",
                    "dependencies": {"Kit/Core": [">= 0"]},
                },
            ],
            [["Kit", ">= 0"]],
        ),
    ]
    regression_cases += [
        (
            [
                {"name": "Kit", "version": version}
                for version in ["1.2.3+build.7", "1.2.3+build.8"]
            ],
            [["Kit", ">= 0"]],
        ),
        (
            [{"name": "Kit", "version": "1.2.3-alpha-beta"}],
            [["Kit", "= 1.2.3-alpha-beta"]],
        ),
        ([{"name": "Kit", "version": "1.2.3+build.7"}], [["Kit", "= 1.2.3+build.7"]]),
        ([{"name": "Kit", "version": "1.0.0-alpha"}], [["Kit", "= 1.0.0-alpha.0"]]),
        (
            [
                {"name": "Kit", "version": version}
                for version in ["1.0.0-alpha.2", "1.0.0-alpha.beta"]
            ],
            [["Kit", ">= 1.0.0-alpha.0"]],
        ),
        (
            [
                {"name": "Kit", "version": version}
                for version in ["1.0.0-alpha", "1.0.0-alpha.0"]
            ],
            [["Kit", "= 1.0.0-alpha.0"]],
        ),
        ([{"name": "Kit", "version": "1.2.3-alpha"}], [["Kit", "= 1.2.3.alpha"]]),
    ]
    regression_cases += [
        (
            [{"name": "Kit", "version": version} for version in versions],
            [["Kit", requirement]],
        )
        for versions, requirement in [
            (["1.0", "1.0.0-1"], ">= 1.0.0-0"),
            (["1.0"], "= 1.0.0-0"),
            (["1.0"], "= 1.0-"),
            (["1.0"], "= 1.0--"),
            (["1.0.0.5", "1.0.5"], "~> 1.0.0-0"),
            (["1.0.1.alpha"], "= 1.0-1.alpha"),
            (["1.0.1beta"], "= 1.0--1beta"),
            (["1.0.0-0"], "= 1.0.0-0"),
            (["1.0.0-alpha", "1.0.0-1"], ">= 1.0.0-alpha"),
        ]
    ]
    for specifications, roots in regression_cases:
        index = len(cases)
        catalog = parent / str(index) / "catalog"
        catalog.mkdir(parents=True)
        for data in specifications:
            data["platforms"] = {"osx": "13.0"}
            path = (
                catalog
                / data["name"]
                / data["version"]
                / (data["name"] + ".podspec.json")
            )
            path.parent.mkdir(parents=True)
            path.write_text(json.dumps(data))
        cases.append(
            {
                "catalog": str(catalog),
                "sandbox": str(parent / str(index) / "Pods"),
                "roots": roots,
            }
        )
    payload = parent / "cases.json"
    payload.write_text(json.dumps(cases))
    ruby, reference_env = reference_environment(args.gem_home, parent)
    process = subprocess.run(
        [ruby, "-e", RUBY, str(payload)],
        cwd=parent,
        env=reference_env,
        text=True,
        capture_output=True,
        timeout=120,
    )
    (parent / "reference.log").write_text(process.stdout + process.stderr)
    assert process.returncode == 0, process.stderr[-4000:]
    expected = json.loads(process.stdout)
    native_env = environment()
    native_env["SWIFTPODS_CACHE_ROOT"] = str(parent / "native-cache")
    actual = []
    for index, item in enumerate(cases):
        work = parent / str(index)
        (work / "Podfile").write_text(
            "platform :osx, '13.0'\nsource "
            + repr(item["catalog"])
            + "\ntarget 'App' do\n"
            + "".join(
                " pod " + repr(name) + ", " + repr(requirement) + "\n"
                for name, requirement in item["roots"]
            )
            + "end\n"
        )
        result = subprocess.run(
            [
                str(ROOT / ".build/debug/swiftpods"),
                "outdated",
                "--no-integrate",
                "--json",
            ],
            cwd=work,
            env=native_env,
            capture_output=True,
            text=True,
            timeout=30,
        )
        (work / "native.log").write_text(result.stdout + result.stderr)
        report = json.loads(result.stdout)
        if result.returncode:
            assert any(
                event.get("code") == "SP-RESOLVE-CONFLICT" for event in report["events"]
            ), report
            actual.append({"status": "conflict"})
        else:
            pods = next(
                event["pods"]
                for event in report["events"]
                if event["kind"] == "outdated"
            )
            actual.append(
                {
                    "status": "passed",
                    "versions": {pod["name"]: pod["available"] for pod in pods},
                }
            )
    differences = [
        {"case": index, "expected": wanted, "actual": own}
        for index, (wanted, own) in enumerate(zip(expected, actual))
        if wanted != own
    ]
    (parent / "observations.json").write_text(
        json.dumps(
            {"reference": expected, "native": actual, "differences": differences},
            indent=2,
        )
    )
    assert not differences, differences
    report = {
        "status": "passed",
        "engine": "swift",
        "reference": "1.17.0",
        "seed": 1431,
        "case_count": len(cases),
        "fixture": str(parent),
        "verified": [
            "32 deterministic generated graphs and four cycle/backtracking graphs resolved independently in both engines",
            "same chosen root versions and dependency closure",
            "same conflict outcomes",
            "root requirement ordering and transitive version constraints",
            "cycles across roots and default subspecs rejected; acyclic version fallback retained",
            "numeric hyphen version precedence, exact aliases and pessimistic bounds match CocoaPods",
        ],
        "unverified": [
            "exhaustive graph space",
            "remote repository transport",
            "exact cycle diagnostic text: reference internal ArgumentError on the merged cycle is retained in reference.log",
        ],
    }
    (ROOT / "test-results/native-resolver-reference.json").write_text(
        json.dumps(report, indent=2) + "\n"
    )
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    execute(main, "native-resolver-reference.json")
