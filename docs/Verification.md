# Verify an installation

The `Verify published installation` workflow downloads a pinned public release
from this repository, verifies the installer and manifest checksums, installs
it, executes a Podfile hook and performs an offline deployment reinstall.
It records results separately on Apple Silicon and Intel runners.

Supply `version` (without `v`) and the independently verified
`manifest_sha256`. The downloaded manifest must have `publishable: true` and
`development: false`. A missing release, unsupported architecture, changed
checksum or failed runtime check fails the job. Logs are retained as
`installation-<runner>` artifacts. This workflow does not publish a release.

After Homebrew accepts the source-build formula, enable `verify_homebrew` to
also install and test `swiftpods` from `homebrew/core`. The workflow checks the
formula's origin and version and the installed executable's version. Official
formula source URLs and Homebrew bottles are independent of our binary archive
URLs; their checksums are not interchangeable. Leaving this input disabled
provides installer evidence only, not official Homebrew acceptance evidence.

Source compatibility CI tests packages through a temporary local binary tap
before publication. The published-installation workflow checks the final public
download path after the release exists. Neither runner compilation nor a newer
macOS runner proves execution on the minimum supported macOS or a physical device.

## Collect independent evidence

Keep the full packaged run and independent gate artifacts from the same clean
source revision. The source runner accepts `--external-evidence FILE` when the
artifacts are available before the full run. To attach newly completed checks
to an existing full run, use the collector in this repository:

```sh
python3 scripts/collect_external.py \
  --source-checkout . \
  --evidence /path/to/full-evidence.zip \
  --external-evidence /path/to/external.json \
  --destination /path/to/combined-evidence.zip
```

The collector uses the matching checkout's acceptance validator, rechecks report
and executable hashes, and includes external artifacts in the portable archive.
It preserves the original full run and does not rerun or replace its tests.
Missing gates remain unverified. Supply the combined archive when assembling
release assets from the matching source checkout.
