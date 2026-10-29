#!/usr/bin/env python3
"""Generate the Homebrew formula from a verified release manifest."""

import argparse
import json
from pathlib import Path

from scripts.support.version import ROOT, source_version


def homebrew_formula(version, assets):
    # Select the oldest available build for each architecture. An actual OS
    # guard stays in install; a newer build is never presented as an older one.
    selected = {}
    for asset in assets:
        architecture = asset["architecture"]
        if architecture not in selected or tuple(
            map(int, asset["minimum_macos"].split("."))
        ) < tuple(map(int, selected[architecture]["minimum_macos"].split("."))):
            selected[architecture] = asset
    lines = [
        "class Swiftpods < Formula",
        '  desc "Dependency manager for Apple platform projects"',
        '  homepage "https://swiftpods.org"',
    ]
    if len(selected) == 1:
        asset = next(iter(selected.values()))
        lines += [
            "  url " + json.dumps(asset["url"]),
            "  sha256 " + json.dumps(asset["sha256"]),
        ]
    else:
        lines += [
            "  if Hardware::CPU.arm?",
            "    url " + json.dumps(selected["arm64"]["url"]),
            "    sha256 " + json.dumps(selected["arm64"]["sha256"]),
            "  else",
            "    url " + json.dumps(selected["x86_64"]["url"]),
            "    sha256 " + json.dumps(selected["x86_64"]["sha256"]),
            "  end",
        ]
    lines += [
        "  version " + json.dumps(version),
        '  license "MIT"',
        "",
        "  depends_on :macos",
    ]
    if len(selected) == 1:
        lines += [
            "  depends_on arch: :" + ("arm64" if "arm64" in selected else "x86_64")
        ]
    floors = {
        architecture: asset["minimum_macos"] for architecture, asset in selected.items()
    }
    lines += [
        "",
        "  def install",
        "    minimum = { "
        + ", ".join(
            json.dumps(key) + " => " + json.dumps(value)
            for key, value in floors.items()
        )
        + " }",
        '    architecture = Hardware::CPU.arm? ? "arm64" : "x86_64"',
        '    odie "No release for this architecture" unless minimum.key?(architecture)',
        '    odie "Requires macOS #{minimum.fetch(architecture)} or newer" if MacOS.version < minimum.fetch(architecture)',
        '    bin.install "bin/swiftpods"',
        '    prefix.install "LICENSE", "README.md"',
        "  end",
        "",
        "  test do",
        '    assert_equal version.to_s, shell_output("#{bin}/swiftpods version").strip',
        "  end",
        "end",
        "",
    ]
    return "\n".join(lines)


def prepare(manifest_path, root=ROOT):
    manifest = json.loads(manifest_path.read_bytes())
    if (
        manifest.get("schema_version") != 2
        or manifest.get("publishable") is not True
        or manifest.get("development") is not False
        or {asset["architecture"] for asset in manifest["assets"]}
        != {"arm64", "x86_64"}
        or any(
            (asset.get("notarization") or {}).get("status") != "Accepted"
            for asset in manifest["assets"]
        )
    ):
        raise RuntimeError(
            "The formula requires a published, notarized release for both architectures"
        )
    if source_version(root) != manifest["version"]:
        raise RuntimeError("Formula version must match the current source version")
    formula = root / "Formula/swiftpods.rb"
    formula.parent.mkdir(parents=True, exist_ok=True)
    formula.write_text(homebrew_formula(manifest["version"], manifest["assets"]))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path)
    args = parser.parse_args()
    prepare(args.manifest)


if __name__ == "__main__":
    main()
