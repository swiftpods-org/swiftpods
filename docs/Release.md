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
`release.json`. That manifest pins both the SHA-256 of every archive and a
deterministic digest of its complete extracted payload, so the installer
trusts nothing that is not covered by your pin. A production manifest also
records the exact annotated source-tag object as well as its commit; the
manifest hash therefore preserves the original tag identity across later
workflow runs.

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
runtime_parent="$(mktemp -d "${TMPDIR:-/tmp}/swiftpods-runtime.XXXXXX")"
chmod 700 "$runtime_parent"
runtime_directory="$runtime_parent/runtime"
mkdir -m 700 "$runtime_directory"
python3 install.py --version VERSION --manifest-sha256 MANIFEST_SHA256 \
  --prefix "$PWD/.build/swiftpods" \
  --runtime-directory "$runtime_directory"
export PATH="$runtime_directory:$PATH"
swiftpods install --deployment
```

The installer selects the archive for the machine's architecture and macOS
version, enforces download and expansion limits, verifies the archive and the
complete extracted tree, verifies the exact Developer ID leaf certificate and
Team ID recorded by the schema-v3 manifest, and only then runs the executable's
version check. Schema-v2 manifests remain supported for existing releases, but
do not contain this independent Apple publisher evidence.
Running it again with the same values re-verifies the cached tree; it never
replaces a prefix that holds anything else. The authenticated manifest and
archive are retained as offline verification evidence. `--runtime-directory`
copies the authenticated executable into a private location, so later commands
cannot race a mutable shared cache path. Keep that directory for as long as the
tool is needed, then remove its private parent. Add `--offline` to
reuse that verified installation without network access. For a fresh
air-gapped installation, pass `--manifest release.json --archive ARCHIVE.zip`
from the same release; older caches need one online verification to acquire the
new evidence format.

## Releasing

Run tests locally before pushing the release commit. CI/CD builds and packages
the artifacts, verifies their integrity, and signs and notarizes the executables;
it does not run test suites or runtime smoke tests. After publication, test the
downloaded signed executable through a verified installation.

1. Change the version line in `Sources/swiftpods/main.swift`
   (`let version = "X.Y.Z"`). It is the only version source; `Unity/package.json`
   repeats it, and a test keeps the two equal. Merge to `main`.
2. When Build SwiftPods has passed for that commit, create an annotated tag and
   push it: `git tag -a vX.Y.Z COMMIT -m 'SwiftPods X.Y.Z' && git push origin vX.Y.Z`.
3. Release SwiftPods checks that the tag matches the version line, points to a
   commit on `main` with a successful run of the exact
   `.github/workflows/build.yml` workflow for that commit, and names a
   version that is either unpublished or is already published with the exact
   same tag, source commit, manifest checksum and complete public asset set.
   It pins the exact annotated-tag object selected at workflow start and
   rechecks through the GitHub Git-data API that `refs/tags/vX.Y.Z` still has
   that object and that the object directly names the built commit. The exact
   object ID is written into both `release.json` and the GitHub Release notes,
   so replacing the tag with another annotated object for the same commit does
   not create a new acceptable release identity.
   The build workflow packages both architectures on separate, fresh runners.
   Release downloads the exact content-addressed bundles produced by that
   successful build run, signs them with the pinned Developer ID certificate and
   notarizes them. The signing job never executes artifact code. A separate
   protected job, using an independently managed App Store Connect credential,
   queries Apple's `notarytool info` and `notarytool log` services and requires
   their accepted submission ID, archive filename and SHA-256 to match the exact
   downloaded archive. A subsequent fresh job with no release credentials
   verifies the local receipt and code signature before
   publication. The release publishes the archives, `install.py`, `release.json`
   and `SHA256SUMS` together.
   For a stable version, it prepares the Homebrew and Fastlane pins on the
   current captured `main` and separately prepares the Fastlane tag from the
   exact release commit plus only the authenticated release pin. It builds both
   immutable candidates, then publishes the current-main pin commit and the
   annotated release-tree Fastlane tag atomically. A newer pin already on
   `main` is never downgraded. Versions with a suffix (`X.Y.Z-beta.1`) are
   marked as pre-releases and leave the integrations unchanged.

If that build run's artifacts have expired, rerun `Build SwiftPods` for the
same exact commit; the release fails closed instead of recompiling different
release bytes.

Published versions are immutable: a release or its tag is never replaced. The
repository-level GitHub **Immutable releases** setting is mandatory; publication
fails closed unless the Releases API reports `immutable: true`, and the workflow
downloads and hashes every asset again after the release becomes public. To fix
a release, publish a new version.

An interrupted asset upload remains a hidden draft. Dispatch the release again
for the same version: the workflow accepts only a draft for the exact source
annotated-tag object with no unexpected asset names, overwrites its metadata
and every expected asset from the freshly validated signed payload, downloads
and compares every remote byte, rechecks the tag object immediately before
publication, and only then makes the draft public. A mismatched public release
or a foreign draft is never replaced. The draft must already contain the same
tag-object ID, publisher identity and a valid prior manifest checksum in its
canonical notes before any asset is changed. The checksum may differ from the
freshly rebuilt signed payload; after that identity check, the workflow
replaces the notes and all expected assets with the current validated payload.
A draft created by an older workflow without that binding is intentionally not
adopted automatically.

If publication succeeds but the integration update is interrupted or `main`
moves while its exact candidate is being built, dispatch `Release SwiftPods`
again for the same version. The resume path does not rebuild, re-sign or replace
the release: it downloads every public asset, verifies the tag and source
commit and the exact annotated-tag object, checks all files through
`SHA256SUMS` and `release.json`, and requires the manifest SHA-256 recorded by
the first observation of that publication.
An already-created Fastlane tag is accepted only when its annotated-tag name
and message are exact and its commit tree is either the release tree itself or
a single pin-only child of the release commit. The independently updated
current `main` must retain the same or a newer integration version.

Configure a protected GitHub Environment named `release-signing` with required
reviewers and the secrets `SWIFTPODS_SIGNING_P12`,
`SWIFTPODS_SIGNING_PASSWORD`, `SWIFTPODS_SIGNING_IDENTITY`,
`SWIFTPODS_SIGNING_TEAM_ID`, `SWIFTPODS_NOTARY_KEY`,
`SWIFTPODS_NOTARY_KEY_ID` and `SWIFTPODS_NOTARY_ISSUER`.
`SWIFTPODS_SIGNING_IDENTITY` is the exact 40-character SHA-1 fingerprint shown
by `security find-identity -v -p codesigning`; it is not a certificate-name
substring. `SWIFTPODS_SIGNING_TEAM_ID` is the exact 10-character Apple Team ID.
Configure a second protected Environment named
`release-notarization-verification` with required reviewers and a separately
managed App Store Connect API credential in `SWIFTPODS_NOTARY_VERIFY_KEY`,
`SWIFTPODS_NOTARY_VERIFY_KEY_ID` and `SWIFTPODS_NOTARY_VERIFY_ISSUER`. Give that
credential the minimum Apple role that can read notarization submission info and
logs; do not reuse the signing job's API key. Missing credentials or an Apple log
without the exact archive SHA-256 stop the release before assembly.
Configure a third protected Environment named `release-publish` with required
reviewers for GitHub Release and integration-ref writes. Protect `v*` tags so
only release maintainers can create them. The workflow requires annotated tags;
requiring cryptographically signed tags additionally needs a repository-level
verification policy and a separately managed maintainer key.

To try the pipeline locally, `python3 -m scripts.package --destination DIR`
builds an unsigned `SwiftPods/` directory, and
`python3 -m scripts.release --development --bundle DIR --version VERSION --destination OUT`
assembles an unpublishable release from it for testing the installer.
