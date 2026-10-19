# Installation and releases

SwiftPods source, installation tooling, GitHub Action and release downloads live
in [swiftpods-org/swiftpods](https://github.com/swiftpods-org/swiftpods).
The project is distributed under the [MIT License](../LICENSE).
The website is maintained separately in `swiftpods-site` at swiftpods.org.

Version 0.1.0 and official Homebrew distribution are being prepared. There is no
public installation until the corresponding release is published. The Homebrew
command becomes available after the formula is accepted into `homebrew/core`.
See [development setup](Development.md) to build from source in the meantime.

## Homebrew

Once the official formula is available:

```sh
brew install swiftpods
brew upgrade swiftpods
```

Homebrew builds the official formula from the tagged source and distributes
binary bottles for supported systems. The formula belongs in `homebrew/core`.
Generated binary archive formulae are local installation-test fixtures, not
submissions to the official source-built catalog.

SwiftPods ships its native executable and its own Ruby DSL adapter. Ruby is
installed separately. The supported interpreter is CRuby >= 3.4.11, < 3.5.0,
with ABI 3.4.0 and the distribution architecture. No installation engine gems
or native gem extensions are included in the distribution.

## Pinned installation and CI

Download `install.py` from the selected version in this repository's
[GitHub Releases](https://github.com/swiftpods-org/swiftpods/releases).
Verify its SHA-256 before execution and pin the SHA-256 of `release.json` in
CI. The manifest pins the compatible archive and its checksum. Python 3.9+ and
compatible Ruby are required; `SWIFTPODS_RUBY` selects its absolute executable.

```sh
python3 install.py --version VERSION --manifest-sha256 MANIFEST_SHA256 \
  --prefix "$PWD/.build/swiftpods"
export PATH="$PWD/.build/swiftpods/bin:$PATH"
swiftpods install --deployment
```

Replace VERSION and MANIFEST_SHA256 with published release values. For strict
reproducibility, pin the external Ruby patch and runner toolchain too. Offline
installation accepts `--manifest release.json --archive /path/to/archive.zip`
from the same release, together with the pinned manifest SHA-256.

The root `action.yml` wraps this installer for GitHub Actions. Use
`swiftpods-org/swiftpods@COMMIT_SHA` after the repository is public, replacing
COMMIT_SHA with a reviewed commit. Supply `version` and `manifest-sha256`.
Supply `ruby-path` for a preinstalled compatible interpreter; otherwise the
action installs Homebrew `ruby@3.4`. Pinning SwiftPods does not pin that Ruby patch.

## Preparing a release

Run from a clean, committed source checkout whose version matches the intended
immutable release tag, such as `v0.1.0`:

```sh
brew install ruby@3.4 cmake subversion mercurial
python3 scripts/bootstrap.py
python3 scripts/check.py --full --package dist/SwiftPods-native
python3 scripts/release.py --version VERSION \
  --bundle dist/SwiftPods-native --evidence test-results/evidence.zip \
  --destination dist/release-native
```

A package requires acceptance reports for its own source revision and payload.
Architecture, macOS, Ruby, Xcode and signing evidence apply only to the actual
tested package. Intel, remote CI and physical-device acceptance require
independent runs. See [published installation verification](Verification.md).

Release assembly requires a clean committed revision matching the package
revision and source digest. Each architecture requires its own matching
`--evidence` archive from the full packaged run. Assembly verifies payload hashes
and evidence identity and creates its output atomically. `publishable` remains
false until stable acceptance is established for all supplied architectures.
`--development` is reserved for unpublished local fixtures and always sets
`publishable: false`.

Publish the prepared distribution and evidence archives, `release.json`,
`install.py` and `SHA256SUMS` as assets of the corresponding GitHub Release in
`swiftpods-org/swiftpods`. Keep binaries and generated acceptance snapshots out
of the Git tree. Preserve the repository README; do not replace it with the
README generated for the binary Homebrew fixture.

The `Prepare release` workflow assembles and uploads reviewable build artifacts.
It does not publish a GitHub Release, create a tag or push a repository. Actual
publication requires a passing release manifest and matching signed packages.

## Signing and notarization

`scripts/sign_release.py` signs included native binaries and a CMS manifest
with an explicitly selected Developer ID. Ruby remains external. Notarization
uses an explicitly supplied keychain profile.

Configure `SWIFTPODS_SIGNING_P12` (base64), `SWIFTPODS_SIGNING_PASSWORD`,
`SWIFTPODS_SIGNING_IDENTITY`, `SWIFTPODS_NOTARY_KEY` (the p8 contents),
`SWIFTPODS_NOTARY_KEY_ID` and `SWIFTPODS_NOTARY_ISSUER` as repository secrets.
The release workflow imports credentials into a temporary keychain and removes
them in its cleanup step. An absent identity is a failure; no identity is chosen
automatically. A checked-in workflow is not remote CI acceptance evidence.
