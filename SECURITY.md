# Security reports

Report a suspected vulnerability privately through the repository's GitHub
security advisory form (Security → Advisories → Report a vulnerability). Do not
attach credentials or private project sources to public issues. Repository
owners must enable private reporting before using this route for a public release.

Maintainers reproduce reports against the pinned profile, update the affected
Swift engine, Ruby compatibility policy or adapter, run native and differential checks, and publish an
advisory with affected versions, remediation and replacement checksums. Ruby is an external dependency maintained by its provider. A changed
engine/adapter compatibility profile requires a new signed distribution; installed bundles are never
silently modified or updated during project installation.

Podfiles, Ruby podspecs, plugins, hooks and build scripts execute trusted user
code. Hardened JSON mode rejects executable manifest features; it is not an OS
sandbox. Complete network isolation requires an external CI/VM egress policy.
SHA checks verify content, not publisher trust. Signed releases bind the complete
manifest to the launcher's Developer ID certificate. Unsigned development bundles
are explicitly experimental and require a trusted source of distribution.
