# Verification and readiness

SwiftPods is experimental. A passing test count describes executed cases; it is
not a probability of correctness. Readiness belongs to one source digest,
contract, executable, toolchain and host. Results from different snapshots cannot
be combined to declare that snapshot accepted.

## Acceptance levels

| Level | Required evidence | Meaning |
| --- | --- | --- |
| Focused development check | Swift corpus and the affected integration matrix | The selected contracts passed. This is insufficient for a public readiness claim. |
| Local technical preview | Every registered suite, Ruby compatibility, all mapped requirements/API cases, independent reference comparisons and packaged consumer checks; no unclassified differences | Demonstrations and supervised trials of the documented profile can use this exact tested build. This does not establish production reliability. |
| Stable release | Complete local acceptance, clean source revision and every verified external gate | The release acceptance contract is complete for the recorded profile. It still does not certify untested applications or combinations. |

`check.json` records `local_acceptance`, its `local_blockers`, and the separate
`stable_acceptance`. A partial successful command can have `status: passed` while
both acceptance levels remain `not_established`. Missing evidence never counts
as a pass. Full packaged verification fails if local acceptance is incomplete.

## Risk structure

`Profiles/contract.json` is the executable registry of suites, requirements,
public API cases, accepted reference differences and external gates. New suites
automatically become required for local and stable acceptance and portable
evidence export. The acceptance harness checks registration and report uniqueness.

| Area | Main suites | Required behavior |
| --- | --- | --- |
| Input and compatibility | `contract`, `compatibility`, their reference suites, Ruby adapter/compatibility | Preserve valid declarations and hook effects; reject unsupported or malformed inputs explicitly. Reference differences require evidence for an approved improvement. |
| Resolution and source state | `sources`, `management`, `source-contract`, `mercurial`, resolver reference | Preserve pins, integrity and unrelated dependencies; distinguish install/update/deployment/offline behavior. |
| Lifecycle and preservation | `lifecycle`, `ownership-source`, `resource-isolation` | Reinstall is idempotent; edits/removals leave the correct managed files; recovery, cancellation and concurrent mutations preserve their declared boundaries. |
| Xcode configuration | `integration`, `configuration`, `layout`, `variants`, `batch`, `xcconfig` and references | Generated projects, inherited settings and configuration selection must build and retain user settings. |
| Compiler and module boundaries | `vendor`, `swift-binary`, `linker-manifest`, `catalog-module`, `module-scopes`, `lint-interface`, `subspec-files` | Check actual compiler imports/linking, source/binary ownership and consumer/configuration isolation. Positive controls must remain usable. |
| Apple platforms and hosts | `platforms`, `host-platforms`, `platform-inference`, `supplementary`, `ui` and references | Record build, archive and execution separately, including platform, configuration and linkage. A simulator build is not a physical-device execution. |
| Performance | `benchmarks` | Retain measured results for the fixture workload. Do not infer a production SLA from synthetic workloads. |
| Test and distribution tooling | package/local-build/runtime/acceptance harnesses, integration distribution tests | Reject stale/replaced/missing evidence; preserve failure logs; bind artifacts to their source and executable. Release/network mutations in harness tests are simulated. |
| Packaged CLI | `distribution`, packaged `variants`, `configuration`, `layout`, `ui` | Repeat consumer checks through the exported release binary and adapter, not only the debug executable. |
| Fastlane plugin | `Tests/FastlanePlugin/run.rb` | Build/install the gem, run a nonempty suite and exercise the action and installer boundary. This is a separate plugin gate. |

The module-scope matrix builds two independent Swift consumers together, runs
both applications and checks an offline deployment reinstall without project or
lockfile changes. It covers Debug/Release, library/static-framework/dynamic-framework
products and case-equivalent module names. Disjoint configuration selections are
positive controls. Scoped output paths do not make case-equivalent Swift imports
safe inside one consumer; those graphs are rejected. Distinct source pods with
the exact same Swift module name in one platform/configuration are rejected
across the workspace because Xcode's producer scan is ambiguous. Clang maps with
distinct module identifiers remain supported.

The matrices are a bounded set of cases, not a Cartesian product of all public
options. Arbitrary private plugins, every commercial SDK version and every real
application are outside this local evidence. Authenticated remote sources and
production-network conditions need their own consumer acceptance.

## Running checks

For a local change:

```sh
python3 -m Tests.swift_tests
python3 -m Tests.Tooling.acceptance_tests
python3 -m Tests.Integration.native_module_scope_tests
```

Select the integration suites affected by the change as well. Before assessing a
public technical preview, run the complete corpus from an unchanged checkout:

```sh
python3 -u -m Tests.check --full --package --jobs 2 \
  --evidence-destination /absolute/path/to/evidence.zip
```

The runner uses temporary compiler/fixture storage. It runs every registered
native and isolated CocoaPods reference suite, then builds and tests the release
package. A changed source, toolchain or executable invalidates the evidence.
Compile warnings are failures. Evidence export validates every required report,
package identity and archived log inventory. After a failure, fix its cause and
repeat affected checks; the final full run must use one frozen snapshot.

For retained failure diagnostics, create a fresh system-temporary directory with
a `temporary` subdirectory, set `SWIFTPODS_CHECK_ROOT` to it and `TMPDIR` to that
subdirectory before running the command. Its `reports/check.json`, stage logs and
fixture logs survive failure. Do not reuse old reports to fill missing results.

The Build SwiftPods workflow provides frequent unit, evidence-rule and focused
compiler regression checks on ARM/Intel runners. In GitHub, use **Actions → Full
local acceptance → Run workflow** for the full corpus on a selected revision.
It retains reports and fixture logs even on failure. This expensive workflow is
manual; ordinary build CI alone does not establish local acceptance. The Package
Fastlane plugin workflow also runs the plugin tests before exporting the gem.

## Exit criteria and remaining gates

For local technical preview acceptance:

1. All registered local and reference suites and packaged checks passed on one
   snapshot, without compiler warnings or skipped required cases.
2. All mapped requirements/API cases have current evidence; compatibility
   differences are classified and justified by the registry.
3. Newly confirmed defects have failing reproducers before repair and passing
   controls after repair. Record whether a defect existed at the audit baseline
   or was introduced during repair; do not guess its historical origin.
4. A full evidence archive validates and there are no unresolved failures from
   additional checks outside that archive. Publish the exact scope and known
   limitations with the assessment.

Stable acceptance additionally requires signed distribution, notarization,
physical devices, Intel execution, minimum macOS execution, clean Homebrew
installation, remote CI, Swift binary stability across toolchains, signed Apple
archives and the supplementary host matrix. `external_gates` lists their current
statuses. Local unsigned archives, mocks, Rosetta or a machine's existing
Homebrew installation cannot silently satisfy those gates.

There is no fixed number of bugs or repair batches to reach. Stop the iteration
when the chosen level's evidence is complete and all known blockers for that
level are resolved. Reopen it for a new failure, a changed supported contract or
a changed implementation, and report the acceptance level instead of just the
number of tests.
