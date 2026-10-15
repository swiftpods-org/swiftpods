SwiftPods uses externally installed CRuby >= 3.4.11, < 3.5.0 (ABI 3.4.0).
It never builds, patches or distributes Ruby, OpenSSL or libyaml. Homebrew's
ruby@3.4 formula manages the interpreter and its native dependencies.

Generated gem executable shebangs use /usr/bin/env ruby. The launcher prepends
the validated external interpreter directory for hooks and child processes.
SWIFTPODS_RUBY explicitly selects an absolute path; an incompatible explicit
selection fails without fallback. Standard gems remain private and frozen.

The CocoaPods and CocoaPods-core sources in vendor/ are unmodified exports of
the commits in Profiles/baseline.json. SwiftPods adapters live in Runtime/,
outside those exports.
