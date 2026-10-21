#!/usr/bin/env python3
"""Generate the Fastlane release pin and Homebrew tap from a verified release manifest."""

import argparse
import hashlib
import json
from pathlib import Path

from scripts.release import homebrew_formula

ROOT = Path(__file__).resolve().parents[1]


def prepare(manifest_path, root=ROOT):
    data = manifest_path.read_bytes()
    manifest = json.loads(data)
    if (
        manifest.get("schema_version") != 1
        or manifest.get("publishable") is not True
        or manifest.get("development") is not False
        or manifest.get("runtime_mode") != "external"
        or {asset["architecture"] for asset in manifest["assets"]}
        != {"arm64", "x86_64"}
        or any(
            asset.get("notarization", {}).get("status") != "Accepted"
            for asset in manifest["assets"]
        )
    ):
        raise RuntimeError(
            "Integrations require a published, notarized release for both architectures"
        )
    if (
        json.loads((root / "Profiles/baseline.json").read_text())["swiftpods_version"]
        != manifest["version"]
    ):
        raise RuntimeError("Integration version must match the current profile")
    pin = root / "lib/fastlane/plugin/swiftpods/release.json"
    pin.parent.mkdir(parents=True, exist_ok=True)
    pin.write_text(
        json.dumps(
            {
                "version": manifest["version"],
                "manifest_sha256": hashlib.sha256(data).hexdigest(),
            },
            indent=2,
        )
        + "\n"
    )
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
