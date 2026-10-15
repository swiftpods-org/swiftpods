#!/usr/bin/env python3
"""Prepare release assets, checksums and a Homebrew tap; never publishes them."""

import argparse
import hashlib
import json
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

from evidence import validate as validate_evidence
from install import extract_archive

ROOT = Path(__file__).resolve().parents[1]


def inspect_archive(archive):
    with tempfile.TemporaryDirectory(
        prefix="swiftpods-release-inventory-"
    ) as temporary:
        root = extract_archive(Path(archive).read_bytes(), Path(temporary))
        manifest = (root / "compatibility.json").read_bytes()
        metadata = json.loads(manifest)
        if not (root / "bin/swiftpods").stat().st_mode & 0o111:
            raise RuntimeError("Release executable has no executable permissions")
        if (
            metadata.get("engine") != "swift"
            or metadata.get("gems")
            or metadata.get("native_ruby_libraries")
        ):
            raise RuntimeError(
                "Only a native distribution without installation gems may be released"
            )
        files = {}
        for path in sorted(root.rglob("*")):
            relative = path.relative_to(root).as_posix()
            if path.parent == root and path.name in (
                "compatibility.json",
                "compatibility.cms",
            ):
                continue
            if path.is_symlink():
                if not path.resolve().is_relative_to(root.resolve()):
                    raise RuntimeError("Bundle symlink escapes distribution")
                files[relative] = {"symlink": path.readlink().as_posix()}
            elif path.is_file():
                files[relative] = {
                    "sha256": hashlib.sha256(path.read_bytes()).hexdigest()
                }
        if (
            files != metadata["files"]
            or hashlib.sha256(json.dumps(files, sort_keys=True).encode()).hexdigest()
            != metadata["bundle_digest"]
        ):
            raise RuntimeError("Release archive inventory/checksum mismatch")
        if any(
            name.startswith(("runtime/", "gems/", "vendor/")) or name == "host/host.rb"
            for name in files
        ):
            raise RuntimeError(
                "Embedded interpreters and installation engines must not be released"
            )
        return metadata, hashlib.sha256(manifest).hexdigest()


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
        "  version " + json.dumps(version),
        "  depends_on :macos",
        '  depends_on "ruby@3.4"',
        '  skip_clean "libexec"',
    ]
    if len(selected) == 1:
        lines += [
            "  depends_on arch: :" + ("arm64" if "arm64" in selected else "x86_64")
        ]
    for architecture, condition in [("arm64", "on_arm"), ("x86_64", "on_intel")]:
        if architecture not in selected:
            continue
        asset = selected[architecture]
        lines += [
            "  " + condition + " do",
            "    url " + json.dumps(asset["url"]),
            "    sha256 " + json.dumps(asset["sha256"]),
            "  end",
        ]
    floors = {
        architecture: asset["minimum_macos"] for architecture, asset in selected.items()
    }
    lines += [
        "",
        "  def install",
        "    minimum = " + repr(floors).replace("'", '"').replace(": ", " => "),
        '    architecture = Hardware::CPU.arm? ? "arm64" : "x86_64"',
        '    odie "No release for this architecture" unless minimum.key?(architecture)',
        '    odie "Requires macOS #{minimum.fetch(architecture)} or newer" if MacOS.version < minimum.fetch(architecture)',
        '    libexec.install Dir["*"]',
        "    # Prevent Homebrew from moving verified metafiles out of libexec.",
        '    (prefix/"README.md").write (libexec/"README.md").read',
        '    (bin/"swiftpods").write_env_script libexec/"bin/swiftpods",',
        '      SWIFTPODS_RUBY: Formula["ruby@3.4"].opt_bin/"ruby", SWIFTPODS_BUNDLE: libexec',
        '    system bin/"swiftpods", "runtime", "verify", "--json"',
        "  end",
        "",
        "  test do",
        '    assert_match "SwiftPods", shell_output("#{bin}/swiftpods --version")',
        '    system bin/"swiftpods", "runtime", "verify", "--json"',
        "  end",
        "end",
        "",
    ]
    return "\n".join(lines)


def prepare(args, destination):
    archives = list(args.archive)
    for index, bundle in enumerate(args.bundle):
        temporary = destination / ("input-" + str(index) + ".zip")
        subprocess.run(
            [
                "/usr/bin/ditto",
                "-c",
                "-k",
                "--norsrc",
                "--noextattr",
                "--noqtn",
                "--keepParent",
                str(bundle.resolve()),
                str(temporary),
            ],
            check=True,
        )
        archives.append(temporary)
    evidence = [(path, validate_evidence(path)) for path in args.evidence]
    assets, acceptances, seen, used_evidence, source = [], [], set(), set(), None
    for archive in archives:
        metadata, manifest_sha256 = inspect_archive(archive)
        if (
            metadata["swiftpods_version"] != args.version
            or metadata["runtime"]["mode"] != "external"
        ):
            raise RuntimeError("Release version/runtime mode differs from package")
        revision = metadata["swiftpods_source"]
        from reporting import source_digest

        if revision["files_digest"] != source_digest():
            raise RuntimeError(
                "Package source digest differs from the preparation checkout"
            )
        if not args.development and (
            revision["worktree_has_changes"]
            or subprocess.check_output(
                ["git", "status", "--porcelain"], cwd=ROOT
            ).strip()
        ):
            raise RuntimeError(
                "Release preparation requires a clean committed revision; use --development only for unpublished fixtures"
            )
        fingerprint = (revision["base_commit"], revision["files_digest"])
        if source is not None and fingerprint != source:
            raise RuntimeError(
                "Release architectures were built from different source snapshots"
            )
        source = fingerprint
        if (
            revision["base_commit"]
            != subprocess.check_output(
                ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True
            ).strip()
        ):
            raise RuntimeError(
                "Package source revision differs from release preparation checkout"
            )
        if any(name.startswith("runtime/") for name in metadata["files"]):
            raise RuntimeError("Embedded Ruby must not be released")
        architecture = metadata["build_host"]["architecture"]
        minimum = metadata["minimum_macos"]
        if architecture not in ("arm64", "x86_64") or not re.fullmatch(
            r"[0-9]+(?:\.[0-9]+){1,2}", minimum
        ):
            raise RuntimeError("Invalid release platform metadata")
        key = architecture, minimum
        if key in seen:
            raise RuntimeError("Duplicate release architecture/OS floor")
        seen.add(key)
        matching = [
            (path, index)
            for path, index in evidence
            if any(
                bundle["bundle_digest"] == metadata["bundle_digest"]
                for bundle in index["bundles"]
            )
        ]
        if len(matching) > 1 or (not args.development and not matching):
            raise RuntimeError(
                "Each release bundle requires exactly one matching full acceptance archive"
            )
        if matching:
            path, index = matching[0]
            validate_evidence(path, metadata, manifest_sha256)
            used_evidence.add(path)
            evidence_name = "evidence-macos-" + minimum + "-" + architecture + ".zip"
            shutil.copy2(path, destination / evidence_name)
            acceptances.append(
                {
                    "architecture": architecture,
                    "minimum_macos": minimum,
                    "filename": evidence_name,
                    "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                    "stable_acceptance": index["stable_acceptance"],
                }
            )
        filename = (
            "swiftpods-"
            + args.version
            + "-macos-"
            + minimum
            + "-"
            + architecture
            + ".zip"
        )
        target = destination / filename
        if archive.parent == destination:
            archive.rename(target)
        else:
            shutil.copy2(archive, target)
        sha256 = hashlib.sha256(target.read_bytes()).hexdigest()
        assets.append(
            {
                "os": "macos",
                "architecture": architecture,
                "minimum_macos": minimum,
                "filename": filename,
                "sha256": sha256,
                "url": "https://github.com/swiftpods-org/swiftpods-release/releases/download/v"
                + args.version
                + "/"
                + filename,
            }
        )
    assets.sort(key=lambda asset: (asset["architecture"], asset["minimum_macos"]))
    if used_evidence != {path for path, _ in evidence}:
        raise RuntimeError(
            "An evidence archive does not belong to a supplied release bundle"
        )
    shutil.copy2(ROOT / "scripts/install.py", destination / "install.py")
    release = {
        "schema_version": 1,
        "development": args.development,
        "publishable": not args.development
        and bool(acceptances)
        and all(item["stable_acceptance"] == "established" for item in acceptances),
        "source_revision": {"commit": source[0], "digest": source[1]},
        "version": args.version,
        "runtime_mode": "external",
        "assets": assets,
        "acceptance": acceptances,
        "installer_sha256": hashlib.sha256(
            (destination / "install.py").read_bytes()
        ).hexdigest(),
    }
    (destination / "release.json").write_text(json.dumps(release, indent=2) + "\n")
    checksums = []
    for path in sorted(destination.iterdir()):
        if path.is_file():
            checksums.append(
                hashlib.sha256(path.read_bytes()).hexdigest() + "  " + path.name
            )
    (destination / "SHA256SUMS").write_text("\n".join(checksums) + "\n")
    formula = destination / "homebrew-tap/Formula/swiftpods.rb"
    formula.parent.mkdir(parents=True)
    formula.write_text(homebrew_formula(args.version, assets))
    (formula.parents[1] / "README.md").write_text("""# SwiftPods

Install [SwiftPods](https://swiftpods.org) with Homebrew. Declare pods and Swift
Package Manager dependencies in one Podfile and build with Xcode.

## Installation

```sh
brew install swiftpods
```

Homebrew installs a compatible Ruby as a separate dependency.

## Upgrade

```sh
brew upgrade swiftpods
```

[Website](https://swiftpods.org) ·
[Project](https://github.com/swiftpods-org/swiftpods-code)
""")
    print(
        "Manifest SHA-256:",
        hashlib.sha256((destination / "release.json").read_bytes()).hexdigest(),
    )
    print("Installer SHA-256:", release["installer_sha256"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True)
    parser.add_argument("--bundle", type=Path, action="append", default=[])
    parser.add_argument("--archive", type=Path, action="append", default=[])
    parser.add_argument(
        "--evidence",
        type=Path,
        action="append",
        default=[],
        help="Full acceptance evidence.zip for each supplied bundle",
    )
    parser.add_argument("--destination", type=Path, required=True)
    parser.add_argument(
        "--development",
        action="store_true",
        help="Prepare explicitly unpublished development fixtures from a dirty checkout",
    )
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.-]+)?", args.version):
        parser.error("Explicit release version required, without a leading v")
    if not args.bundle and not args.archive:
        parser.error("At least one --bundle or --archive is required")
    if not args.development and not args.evidence:
        parser.error(
            "Release preparation requires --evidence from the full packaged check"
        )
    destination = args.destination.absolute()
    if destination.exists() or destination.is_symlink():
        raise RuntimeError("Release destination already exists")
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(
        prefix=".swiftpods-release-", dir=destination.parent
    ) as temporary:
        staging = Path(temporary) / "release"
        staging.mkdir()
        prepare(args, staging)
        staging.rename(destination)
    print("Prepared", destination)


if __name__ == "__main__":
    main()
