# Installation and releases

SwiftPods source, installation tooling, GitHub Action and release downloads live
in [swiftpods-org/swiftpods](https://github.com/swiftpods-org/swiftpods).
The project is distributed under the [MIT License](../LICENSE).

Published versions and installation availability are listed on the
[downloads page](https://swiftpods.org/downloads/). See
[building from source](Development.md) for a local installation.

## Homebrew

```sh
brew install swiftpods
brew upgrade swiftpods
```

SwiftPods ships its native executable and its own Ruby DSL adapter. Ruby is
installed separately. The supported interpreter is CRuby >= 2.6, without an
upper version bound, matching the distribution architecture. No installation engine gems
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
`swiftpods-org/swiftpods@COMMIT_SHA`, replacing COMMIT_SHA with the selected
commit. Supply `version` and `manifest-sha256`.
The action uses an installed compatible Ruby. Supply `ruby-path` to select an
interpreter explicitly. Pinning SwiftPods does not pin that Ruby patch.
