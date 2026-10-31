# Installation and releases

SwiftPods source, the installer, the GitHub Action and release downloads live
in [swiftpods-org/swiftpods](https://github.com/swiftpods-org/swiftpods).
The project is distributed under the [MIT License](../LICENSE).

Each release is one signed and notarized `swiftpods` executable for Apple
Silicon and Intel Macs. It needs nothing else at run time. See
[building from source](Development.md) for a local build.

## Homebrew

```sh
brew tap swiftpods-org/swiftpods https://github.com/swiftpods-org/swiftpods.git
brew install swiftpods-org/swiftpods/swiftpods
brew upgrade swiftpods-org/swiftpods/swiftpods
```

The formula follows the latest stable release. Pre-releases are published only
on [GitHub Releases](https://github.com/swiftpods-org/swiftpods/releases).

## Pinned installation in CI

Pin two values from the release notes: the version and the SHA-256 of its
`release.json`. That manifest pins the SHA-256 of every archive, so the
installer trusts nothing that is not covered by your pin.

In GitHub Actions, pin the action by commit too:

```yaml
- uses: swiftpods-org/swiftpods@COMMIT_SHA
  with:
    version: VERSION
    manifest-sha256: MANIFEST_SHA256
- run: swiftpods install --deployment
```

Elsewhere, download `install.py` from the same release and check its SHA-256
against `SHA256SUMS` (or `installer_sha256` in `release.json`) before running
it. It needs Python 3.9 or newer.

```sh
python3 install.py --version VERSION --manifest-sha256 MANIFEST_SHA256 \
  --prefix "$PWD/.build/swiftpods"
export PATH="$PWD/.build/swiftpods/bin:$PATH"
swiftpods install --deployment
```

The installer selects the archive for the machine's architecture and macOS
version, verifies its checksum and checks that the executable reports the
requested version. Running it again with the same values reuses the
installation; it never replaces a prefix that holds anything else. For offline
installation, add `--manifest release.json --archive ARCHIVE.zip` from the same
release.

## Releasing

1. Change the version line in `Sources/swiftpods/main.swift`
   (`let version = "X.Y.Z"`). It is the only version source; `Unity/package.json`
   repeats it, and a test keeps the two equal. Merge to `main`.
2. When Build SwiftPods has passed for that commit, tag it and push the tag:
   `git tag vX.Y.Z COMMIT && git push origin vX.Y.Z`.
3. Release SwiftPods checks that the tag matches the version line, points to a
   commit on `main` with a successful build, and names an unpublished version.
   It then builds both architectures, signs them with Developer ID, notarizes
   them and publishes the archives, `install.py`, `release.json` and
   `SHA256SUMS` together. For a stable version that is still current on `main`,
   it updates `Formula/swiftpods.rb`. Versions with a suffix (`X.Y.Z-beta.1`)
   are marked as pre-releases and leave the formula unchanged.

Published versions are immutable: a release or its tag is never replaced. To
fix a release, publish a new version.

Signing needs the repository secrets `SWIFTPODS_SIGNING_P12`,
`SWIFTPODS_SIGNING_PASSWORD`, `SWIFTPODS_SIGNING_IDENTITY`,
`SWIFTPODS_NOTARY_KEY`, `SWIFTPODS_NOTARY_KEY_ID` and `SWIFTPODS_NOTARY_ISSUER`.

To try the pipeline locally, `python3 -m scripts.package --destination DIR`
builds an unsigned `SwiftPods/` directory, and
`python3 -m scripts.release --development --bundle DIR --version VERSION --destination OUT`
assembles an unpublishable release from it for testing the installer.
