#!/usr/bin/env python3
"""Import explicit CI credentials into a temporary keychain and remove them."""

import argparse
import base64
import json
import os
import secrets
import shlex
import subprocess
import tempfile
from pathlib import Path


def run(*arguments):
    result = subprocess.run(
        list(map(str, arguments)),
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    if result.returncode:
        raise RuntimeError(
            "Signing credential command failed: "
            + Path(arguments[0]).name
            + " "
            + str(arguments[1])
        )
    return result.stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=["setup", "cleanup"])
    args = parser.parse_args()
    parent = Path(os.environ["RUNNER_TEMP"])
    state = parent / "swiftpods-signing.json"
    if args.operation == "cleanup":
        if state.is_file():
            saved = json.loads(state.read_text())
            run(
                "/usr/bin/security",
                "list-keychains",
                "-d",
                "user",
                "-s",
                *saved["previous"],
            )
            run("/usr/bin/security", "delete-keychain", saved["keychain"])
            state.unlink()
        return
    names = [
        "SWIFTPODS_SIGNING_P12",
        "SWIFTPODS_SIGNING_PASSWORD",
        "SWIFTPODS_SIGNING_IDENTITY",
        "SWIFTPODS_NOTARY_KEY",
        "SWIFTPODS_NOTARY_KEY_ID",
        "SWIFTPODS_NOTARY_ISSUER",
    ]
    missing = [name for name in names if not os.environ.get(name)]
    if missing:
        raise RuntimeError("Configure explicit release secrets: " + ", ".join(missing))
    identity = os.environ["SWIFTPODS_SIGNING_IDENTITY"]
    if "\n" in identity or "\r" in identity:
        raise RuntimeError("Invalid signing identity")
    if state.exists():
        raise RuntimeError("Signing state already exists; run cleanup first")
    keychain = parent / ("swiftpods-" + secrets.token_hex(8) + ".keychain-db")
    previous = shlex.split(run("/usr/bin/security", "list-keychains", "-d", "user"))
    password = secrets.token_urlsafe(32)
    run("/usr/bin/security", "create-keychain", "-p", password, keychain)
    state.write_text(json.dumps({"keychain": str(keychain), "previous": previous}))
    os.chmod(state, 0o600)
    try:
        run("/usr/bin/security", "set-keychain-settings", "-lut", "21600", keychain)
        run("/usr/bin/security", "unlock-keychain", "-p", password, keychain)
        run(
            "/usr/bin/security",
            "list-keychains",
            "-d",
            "user",
            "-s",
            *previous,
            keychain,
        )
        with tempfile.TemporaryDirectory(
            prefix="swiftpods-credentials-", dir=parent
        ) as temporary:
            certificate, key = (
                Path(temporary) / "identity.p12",
                Path(temporary) / "notary.p8",
            )
            certificate.write_bytes(
                base64.b64decode(os.environ["SWIFTPODS_SIGNING_P12"], validate=True)
            )
            key.write_text(os.environ["SWIFTPODS_NOTARY_KEY"])
            for file in [certificate, key]:
                os.chmod(file, 0o600)
            run(
                "/usr/bin/security",
                "import",
                certificate,
                "-k",
                keychain,
                "-P",
                os.environ["SWIFTPODS_SIGNING_PASSWORD"],
                "-T",
                "/usr/bin/codesign",
                "-T",
                "/usr/bin/security",
            )
            run(
                "/usr/bin/security",
                "set-key-partition-list",
                "-S",
                "apple-tool:,apple:",
                "-s",
                "-k",
                password,
                keychain,
            )
            profile = "swiftpods-release-" + keychain.stem
            run(
                "/usr/bin/xcrun",
                "notarytool",
                "store-credentials",
                profile,
                "--keychain",
                keychain,
                "--key",
                key,
                "--key-id",
                os.environ["SWIFTPODS_NOTARY_KEY_ID"],
                "--issuer",
                os.environ["SWIFTPODS_NOTARY_ISSUER"],
            )
        with open(os.environ["GITHUB_ENV"], "a") as output:
            output.write(
                "SWIFTPODS_SIGNING_IDENTITY="
                + identity
                + "\nSWIFTPODS_NOTARY_PROFILE="
                + profile
                + "\nSWIFTPODS_NOTARY_KEYCHAIN="
                + str(keychain)
                + "\n"
            )
    except BaseException:
        run("/usr/bin/security", "list-keychains", "-d", "user", "-s", *previous)
        run("/usr/bin/security", "delete-keychain", keychain)
        state.unlink()
        raise


if __name__ == "__main__":
    main()
