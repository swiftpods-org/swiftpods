# Build from source

You can build SwiftPods locally from its public source repository. You need
macOS, Xcode with its command-line tools selected, Python 3 and Ruby 2.6 or newer.

Use an existing Ruby installation, then clone and build SwiftPods:

```sh
ruby --version
git clone https://github.com/swiftpods-org/swiftpods.git
cd swiftpods
export SWIFTPODS_RUBY="$(ruby -rrbconfig -e 'print RbConfig.ruby')"
python3 -m scripts.package --destination "$HOME/.local/opt/swiftpods"
```

Add the executable to PATH for the current terminal session and verify it:

```sh
export PATH="$HOME/.local/opt/swiftpods/bin:$PATH"
swiftpods runtime verify --json
```

Compiler output is created in a system temporary directory and removed after
the build. The exported directory contains the executable and its adapter.
Set `SWIFTPODS_RUBY` in other terminal sessions when selecting the same Ruby
installation.

You can now run `swiftpods install` from your Xcode project directory.
If Ruby is unavailable, install it separately, for example with `brew install ruby`.
See [Getting started](../README.md#getting-started) for a Podfile example, or
[Installation and CI](Release.md) to install a published build.

## Regression checks

Run the Swift corpus and the focused header integration matrix from the repository root:

~~~sh
python3 -m Tests.swift_tests
python3 -m Tests.Regression.header_namespace_regressions
~~~

Both checks run before packaging in the Build SwiftPods workflow. The header
matrix also belongs to the full lifecycle suite. It checks conflicting modules,
distinct-module Debug/Release builds and execution, and public-header visibility
after a fresh install or an offline deployment reinstall. Reinstall tests change
the selected files without changing the podspec, so unchanged declaration hashes
cannot hide stale generated links.

Unit controls cover Swift and explicitly defined library modules, disabled maps,
and separate consumers or configurations. Header cleanup removes obsolete source
links from each variant's public and private trees, including dangling links from
older installs. Regular files, links to other source trees and linked directories
are preserved.

The matrix runs all cases before reporting its failures. Assertions remain
active for known defects; a nonzero result blocks the build until the
implementation meets the expected behavior. Compiler warnings fail the checks.
