# Full acceptance

`Profiles/contract.json` is the versioned registry for T-001–T-025,
AC-001–AC-010, DSL declarations, installation options, specification attributes
and the public hook operations exercised by this profile. Each entry names its
required reports. Declaration/consumer comparisons and build effects have separate
evidence; a mapped fixture is not proof of every combination of inputs.

```sh
brew install ruby@3.4 cmake subversion mercurial
export SWIFTPODS_RUBY="$(brew --prefix ruby@3.4)/bin/ruby"
python3 scripts/check.py --full --package dist/SwiftPods-candidate
```

The runner installs frozen test-only reference gems into `.build/reference-gems`.
Use `--reference-gem-home PATH` to reuse a separately prepared environment.
Production execution and packaging never activate or ship those gems.
Compilation finishes before fixture execution; the debug executable must not be
relinked while fixtures run. A source edit invalidates the aggregate.

`test-results/check.json` contains the source revision and digest, contract digest,
toolchain, executable identities, checksummed reports, requirement/API coverage
and external gates. Each fixture also retains its logs and temporary project path.
`compatibility.json` in the package includes only current passing evidence and
actual build/archive/application matrix rows. Earlier reports are not reused as
passing evidence after source changes. Packaged fixtures use the release binary.

`--skip-apple` omits required build checks and cannot establish stable acceptance.
`--require-stable` additionally rejects a dirty revision, missing API/effect cases,
missing required reports or unverified external gates. Passing the local corpus
alone reports `stable_acceptance: not_established`.

## External evidence

Signing/notarization, physical devices, native Intel execution, the minimum macOS,
clean Homebrew installation, remote CI and cross-compiler Swift module stability
require their own infrastructure. Signed Apple product archives and the remaining
reference-supported supplementary host matrix also have explicit gates. Ordinary simulator runs, cross-compilation and
same-toolchain swiftinterface consumption do not close those gates.

For signing, use a clean committed checkout and an explicit identity/profile:

```sh
python3 scripts/check.py --full --package dist/SwiftPods-signed \
  --signing-identity 'Developer ID Application: Explicit Name (TEAMID)' \
  --notary-profile explicit-profile
```

The optional `--notary-keychain PATH` selects the keychain containing that profile.
The CI workflow imports configured credentials into a temporary keychain; see
[release preparation](Release.md). It does not publish.

External acceptance is supplied with `--external-evidence FILE`. Its
`source_digest` and `contract_digest` must match the current source. Each named
gate has `status: passed` and a nonempty `evidence` array of files with `path` and
`sha256`. Unknown gates, stale digests and changed artifacts fail validation.
Keep test commands, OS/architecture/toolchain identities, observations and logs
inside those evidence files. The reviewer remains responsible for their scope;
the validator verifies identity and integrity, not the truth of arbitrary logs.

For cross-compiler binary validation, `native_swift_binary_tests.py` accepts
`--producer-framework PATH --producer-toolchain ID`. The supplied framework must
be produced independently with library evolution enabled. The fixture removes
serialized modules/private interfaces, builds consumers through public interfaces,
checks binary UUID/exported symbols and executes Debug/Release applications.
Its normal local run explicitly leaves cross-compiler stability unverified.

## Portable evidence and Homebrew

A full packaged run automatically exports `test-results/evidence.zip`. Its
index hashes every report and retained log, records the exact source/toolchain,
and identifies the tested distribution manifest and executable. Failed, missing,
changed or incomplete reports cannot be exported. Fixtures also record the
external Ruby executable/library hashes and reject replacement of a toolchain or
executable while running.

Run the generated Homebrew formula through a temporary local tap with:

```sh
python3 scripts/native_homebrew_tests.py --bundle dist/SwiftPods-candidate
python3 scripts/evidence.py
```

This performs `brew install`, `brew test`, runtime verification and a real Ruby
hook, then removes its formula and tap. It requires no existing SwiftPods formula
and preserves any existing installation. The package is served on localhost;
this verifies formula installation without claiming that public release URLs
work. Existing Ruby dependencies are retained. The second command includes the
current Homebrew report and log in the evidence archive. CI performs these steps
on each configured runner. A successful check on a developer machine does not
certify a pristine machine or any other macOS/architecture.

## Repository handoff

`swiftpods-code` owns implementation, contracts and evidence generation.
`swiftpods-release` receives prepared archives, checksums, installer and root
`Formula/swiftpods.rb`; archives are release assets rather than source files.
`swiftpods-site` describes capabilities confirmed by the selected release's
evidence at swiftpods.org. Updating these repositories does not imply publication.
Release assembly requires one matching full evidence archive per distribution.
It verifies archive inventory, source/toolchain and tested manifest/executable
identities before producing a destination. Failed assembly leaves no partial
release directory.

Stable 1.0 requires the complete current corpus and every mandatory gate. An
unavailable gate remains unverified and must not be replaced with an inferred pass.
