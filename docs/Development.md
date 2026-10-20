# Build from source

You can build SwiftPods locally from its public source repository. You need
macOS, Xcode with its command-line tools selected, Python 3 and Homebrew.

Install Ruby, then clone and build SwiftPods:

```sh
brew install ruby@3.4
git clone https://github.com/swiftpods-org/swiftpods.git
cd swiftpods
export SWIFTPODS_RUBY="$(brew --prefix ruby@3.4)/bin/ruby"
python3 scripts/bootstrap.py
swift build -c release -Xswiftc -warnings-as-errors -Xcc -Wall -Xcc -Wextra -Xcc -Werror
```

Add the executable to PATH for the current terminal session and verify it:

```sh
export PATH="$PWD/.build/release:$PATH"
swiftpods runtime verify --json
```

Keep the source checkout and its generated `.runtime` directory together.
The executable locates the adapter in that checkout. Set `SWIFTPODS_RUBY` in
other terminal sessions when selecting the same Ruby installation.

You can now run `swiftpods install` from your Xcode project directory.
See [Getting started](../README.md#getting-started) for a Podfile example, or
[Installation and CI](Release.md) to install a published build.
