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

XCTest build products use an owned system temporary directory, with a fixture
`DerivedData` symlink for inspection during the run. Explicit `SYMROOT` and
`OBJROOT` arguments keep project-level overrides in that same directory. This avoids test runners
blocking while opening libraries under a privacy-protected Desktop when the Mac
is locked. Project sources stay in the fixture; command and XCTest diagnostic
logs are retained there before temporary products are cleaned up. Timed-out or
interrupted fixture commands stop their owned process groups and remain failures.

`test-results/check.json` contains the source revision and digest, contract digest,
toolchain, executable identities, checksummed reports, requirement/API coverage
and external gates. Each fixture also retains its logs and temporary project path.
`compatibility.json` in the package includes only current passing evidence and
actual build/archive/application matrix rows. Earlier reports are not reused as
passing evidence after source changes. Packaged fixtures use the release binary.

`--skip-apple` omits required build checks and cannot establish stable acceptance.
`--require-stable` additionally rejects a dirty revision, missing API/effect cases,
missing required reports, unverified differences or unverified external gates. Passing the local corpus
alone reports `stable_acceptance: not_established`.

The compatibility contract is `input_compatible`: preserve existing manifests,
helpers, supported public hooks and lockfiles while permitting simpler native
implementations and corrected behavior.
`compatibility_policy.improvements` in `Profiles/contract.json` links each tested
improvement to unchanged-input and correct-effect cases. The aggregate retains
`compatibility_differences`, including raw `parity: false`, and records the
classification. `blocking_compatibility_differences` excludes only improvements
whose current evidence satisfies that policy. The BridgeSupport aggregate header
path has dedicated input and effect checks. This does not waive required reports
or external acceptance gates.

## External evidence

Signing/notarization, physical devices, native Intel execution, the minimum macOS,
clean Homebrew installation, remote CI and cross-compiler Swift module stability
require their own infrastructure. Signed Apple product archives and the remaining
required supplementary host matrix also have explicit gates. Ordinary simulator
runs, cross-compilation and same-toolchain swiftinterface consumption do not close those gates.

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
`--producer-framework PATH --producer-manifest FILE`. The supplied framework must
be produced independently with library evolution enabled. The fixture removes
serialized modules/private interfaces, builds consumers through public interfaces,
checks binary UUID/exported symbols and executes Debug/Release applications.
Its normal local run explicitly leaves cross-compiler stability unverified.
The `Swift binary module compatibility` workflow produces the framework with
Xcode 16.4 and consumes it with Xcode 26.6. The producer manifest pins the actual
compiler, source revision, contract and every framework file. Consumer validation
rejects stale, modified or mismatched artifacts and compares the compiler identity
inside public text interfaces; a caller-supplied label cannot establish a pass.

```sh
# Run on the producer machine; preserve the entire directory, including symlinks.
python3 scripts/swift_binary_producer.py --destination .build/swift-producer
# Run on the consumer machine with the same clean source revision.
python3 scripts/native_swift_binary_tests.py \
  --producer-framework imported/swift-producer/SwiftBinaryKit.framework \
  --producer-manifest imported/swift-producer/producer.json
```

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

## Repository and release ownership

`swiftpods-org/swiftpods` owns implementation, contracts, evidence generation,
installation tooling and GitHub Releases. Prepared archives, checksums, the
installer and matching evidence are release assets rather than Git source files.
The generated binary Homebrew fixture supports isolated installation tests;
it is not the source-build formula for submission to `homebrew/core`.
`swiftpods-site` documents the product workflow at swiftpods.org. Release
metadata and acceptance evidence identify the actual published artifacts and
their verified scope. Updating either repository does not imply publication.
Release assembly requires one matching full evidence archive per distribution.
It verifies archive inventory, source/toolchain and tested manifest/executable
identities before producing a destination. Failed assembly leaves no partial
release directory.

Stable 1.0 requires the complete current corpus and every mandatory gate. An
unavailable gate remains unverified and must not be replaced with an inferred pass.
