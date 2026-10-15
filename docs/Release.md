# Installation and releases

SwiftPods ships its native executable and its own Ruby DSL adapter. Ruby is
installed separately. The supported interpreter is CRuby >= 3.4.11, < 3.5.0,
with ABI 3.4.0 and the distribution architecture. No installation engine gems
or native gem extensions are included in the distribution.

## Homebrew

```sh
brew install swiftpods
```

Homebrew installs a compatible Ruby as a separate dependency.
Upgrades use `brew upgrade swiftpods`.

## CI

Install a release with the checksummed `install.py` from
`swiftpods-org/swiftpods-release`. Pin the installer checksum and the SHA-256 of
`release.json` in your CI configuration. Python 3.9+ and compatible Ruby are
required; `SWIFTPODS_RUBY` selects its absolute executable path.

```sh
python3 install.py --version VERSION --manifest-sha256 MANIFEST_SHA256 \
  --prefix "$PWD/.build/swiftpods"
export PATH="$PWD/.build/swiftpods/bin:$PATH"
swiftpods install --deployment
```

Replace VERSION and MANIFEST_SHA256 with published release values. For strict
reproducibility, pin the external Ruby patch in the runner image too.

## Preparing a release

Source, release and site repositories are `swiftpods-code`, `swiftpods-release`
and `swiftpods-site`. Source preparation does not publish changes automatically.

```sh
brew install ruby@3.4 cmake subversion mercurial
python3 scripts/bootstrap.py
python3 scripts/check.py --full --package dist/SwiftPods-native
python3 scripts/release.py --version VERSION \
  --bundle dist/SwiftPods-native --evidence test-results/evidence.zip \
  --destination dist/release-native
```

Publish distribution/evidence archives, `release.json`, `install.py` and `SHA256SUMS` as GitHub Release
assets in `swiftpods-release`. Copy the generated Homebrew Formula and README to
that repository. The formula downloads those assets; archive files are not Git
source files. The site is maintained separately at swiftpods.org.

A package requires acceptance reports for its own source revision and payload.
Architecture, macOS, Ruby, Xcode and signing evidence apply only to the actual tested package. Intel,
remote CI and physical-device acceptance require independent runs.

`scripts/sign_release.py` signs included native binaries and a CMS manifest
with an explicitly selected Developer ID. Ruby remains external. Notarization
uses an explicitly supplied keychain profile.

Release preparation requires a clean committed source revision matching both the
package revision and source digest. `release.py --development` is reserved for
unpublished local fixtures; its manifest explicitly has `publishable: false`.
Each architecture requires its own matching `--evidence` archive from the full
packaged run. Assembly verifies every payload hash and evidence identity and
creates its output atomically. `publishable` remains false until stable acceptance
is established for all supplied architectures.
No command in this workflow publishes a release or pushes a repository.

The release workflow runs the full corpus, then signs/notarizes and tests the final
package. Configure `SWIFTPODS_SIGNING_P12` (base64),
`SWIFTPODS_SIGNING_PASSWORD`, `SWIFTPODS_SIGNING_IDENTITY`,
`SWIFTPODS_NOTARY_KEY` (the p8 contents), `SWIFTPODS_NOTARY_KEY_ID` and
`SWIFTPODS_NOTARY_ISSUER` as repository secrets. Credentials are imported into a
temporary keychain and removed in the final cleanup step. An absent identity is a
failure; the workflow never chooses one. The configured macOS and Intel runner
labels follow the [GitHub runner images](https://github.com/actions/runner-images).
A checked-in workflow is not remote CI acceptance evidence.
