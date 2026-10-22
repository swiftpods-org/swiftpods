"""Small local Git packages for lifecycle and module identity regressions."""

import subprocess


def create(directory, name="Net", module=None, versions=("1.0.0",)):
    """Return a file URL for a package with one product and one target."""
    module = module or name
    sources = directory / "Sources" / module
    sources.mkdir(parents=True)
    (sources / "API.swift").write_text("public struct PackageAPI {}\n")
    (directory / "Package.swift").write_text(
        "// swift-tools-version: 6.0\nimport PackageDescription\n"
        f'let package = Package(name: "{name}", platforms: [.macOS(.v13)], '
        f'products: [.library(name: "{name}", targets: ["{module}"])], '
        f'targets: [.target(name: "{module}")])\n'
    )
    for arguments in [
        ["init", "-b", "main"],
        ["add", "."],
        [
            "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
            "-c", "commit.gpgsign=false", "commit", "-m", "Package fixture",
        ],
        *[["tag", version] for version in versions],
    ]:
        subprocess.run(
            ["git", "-C", str(directory), *arguments], check=True, capture_output=True
        )
    return directory.as_uri()
