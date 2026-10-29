# Security reports

Report a suspected vulnerability privately through the repository's GitHub
security advisory form (Security → Advisories → Report a vulnerability). Do not
attach credentials or private project sources to public issues.

SwiftPods never executes a `Podfile`: it is parsed as data. It does run what the
Podfile declares at build time, through Xcode: script phases, Swift package
manifests and plugins, and the linker flags of binary SDKs. Treat a `Podfile`
and the packages it names as code you trust.

Binary archives are verified against the SHA-256 written in the `Podfile`
before use. A checksum proves the content is what the author pinned, not that
the publisher is trustworthy.

Published releases are signed, notarized and immutable. A fix ships as a new
version with new checksums; an existing version is never replaced.
