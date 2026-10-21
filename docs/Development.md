# Build from source

You can build SwiftPods locally from its public source repository. You need
macOS, Xcode with its command-line tools selected, Python 3 and Ruby 2.6 or newer.

Use an existing Ruby installation, then clone and build SwiftPods:

```sh
ruby --version
git clone https://github.com/swiftpods-org/swiftpods.git
cd swiftpods
export SWIFTPODS_RUBY="$(ruby -rrbconfig -e 'print RbConfig.ruby')"
python3 scripts/package.py --destination "$HOME/.local/opt/swiftpods"
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
