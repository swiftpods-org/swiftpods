"""Build actual binary SDKs with distinct platform payloads; no Ruby project tools."""

import atexit
import os
import plistlib
import shutil
import signal
import subprocess
import tempfile
from pathlib import Path

_derived_data = {}


def fixture_derived_data(parent):
    """Keep test executables outside privacy-protected project directories."""
    parent = Path(parent).resolve()
    if parent not in _derived_data:
        alias = parent / "DerivedData"
        if alias.exists() or alias.is_symlink():
            raise RuntimeError(
                "Existing fixture build directory was preserved: " + str(alias)
            )
        temporary = tempfile.TemporaryDirectory(prefix="swiftpods-xcode-")
        alias.symlink_to(temporary.name, target_is_directory=True)
        _derived_data[parent] = temporary
    return Path(_derived_data[parent].name)


def fixture_build_arguments(parent):
    directory = fixture_derived_data(parent)
    # A project's explicit SYMROOT can otherwise escape -derivedDataPath.
    return [
        "-derivedDataPath",
        directory,
        "SYMROOT=" + str(directory / "Build/Products"),
        "OBJROOT=" + str(directory / "Build/Intermediates.noindex"),
    ]


def _cleanup_derived_data():
    for parent, temporary in _derived_data.items():
        diagnostics = Path(temporary.name) / "Logs/Test"
        for log in diagnostics.rglob("*.log"):
            if log.is_file() and not log.is_symlink():
                destination = (
                    parent / "xctest-diagnostics" / log.relative_to(diagnostics)
                )
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(log, destination)
        temporary.cleanup()


atexit.register(_cleanup_derived_data)


def _cancel_command(process):
    try:
        os.killpg(process.pid, signal.SIGINT)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=2)
    except subprocess.TimeoutExpired:
        pass
    # A parent can exit after SIGINT while its descendants remain alive.
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait()


def run(arguments, cwd, log, env=None, timeout=300):
    with log.open("wb") as output:
        process = subprocess.Popen(
            [str(arg) for arg in arguments],
            cwd=cwd,
            env=env,
            stdout=output,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        try:
            process.wait(timeout=timeout)
        except BaseException:
            _cancel_command(process)
            raise
    text = log.read_text(errors="replace")
    if process.returncode or " warning:" in text or "\nwarning:" in text:
        raise RuntimeError("SDK fixture command failed or warned: " + str(log))
    return text


def sdk(
    root,
    name,
    dynamic=False,
    library=False,
    platforms=("macosx", "iphoneos", "iphonesimulator"),
):
    """Return an XCFramework; keep producer intermediates outside consumer pods."""
    producer = root / ("producer-" + name)
    producer.mkdir()
    arguments = ["xcodebuild", "-create-xcframework"]
    for platform in platforms:
        folder = producer / platform
        folder.mkdir()
        value = {
            "macosx": 42,
            "iphoneos": 101,
            "iphonesimulator": 202,
            "appletvos": 301,
            "appletvsimulator": 302,
            "watchos": 401,
            "watchsimulator": 402,
            "xros": 501,
            "xrsimulator": 502,
            "maccatalyst": 601,
        }[platform]
        source = folder / "sdk.c"
        source.write_text(f"int {name}_value(void) {{ return {value}; }}\n")
        framework = folder / (name + ".framework")
        contents = framework / "Versions/A" if platform == "macosx" else framework
        headers = folder / "Headers" if library else contents / "Headers"
        headers.mkdir(parents=True)
        headers.joinpath(name + ".h").write_text(
            f"int {name}_value(void);\n#define {name}_EXPECTED {value}\n"
        )
        if not library:
            contents.joinpath("Modules").mkdir()
            contents.joinpath("Modules/module.modulemap").write_text(
                f'framework module {name} {{ umbrella header "{name}.h" export * }}\n'
            )
            resources = contents / "Resources" if platform == "macosx" else contents
            resources.mkdir(exist_ok=True)
            resources.joinpath("Info.plist").write_bytes(
                plistlib.dumps(
                    {
                        "CFBundleIdentifier": "org.swiftpods." + name,
                        "CFBundleName": name,
                        "CFBundleExecutable": name,
                        "CFBundlePackageType": "FMWK",
                        "CFBundleVersion": "1",
                        "CFBundleShortVersionString": "1.0",
                        "CFBundleSupportedPlatforms": [
                            {
                                "macosx": "MacOSX",
                                "iphoneos": "iPhoneOS",
                                "iphonesimulator": "iPhoneSimulator",
                                "appletvos": "AppleTVOS",
                                "appletvsimulator": "AppleTVSimulator",
                                "watchos": "WatchOS",
                                "watchsimulator": "WatchSimulator",
                                "xros": "XROS",
                                "xrsimulator": "XRSimulator",
                                "maccatalyst": "MacOSX",
                            }[platform]
                        ],
                        "MinimumOSVersion": {
                            "macosx": "13.0",
                            "watchos": "10.0",
                            "watchsimulator": "10.0",
                            "xros": "1.0",
                            "xrsimulator": "1.0",
                        }.get(platform, "15.0"),
                    }
                )
            )
        binaries = []
        architectures = (
            ["arm64"]
            if platform in ("iphoneos", "appletvos", "xros")
            else ["arm64", "arm64_32"]
            if platform == "watchos"
            else ["arm64", "x86_64"]
        )
        target_os = {
            "macosx": "macos13.0",
            "iphoneos": "ios15.0",
            "iphonesimulator": "ios15.0-simulator",
            "appletvos": "tvos15.0",
            "appletvsimulator": "tvos15.0-simulator",
            "watchos": "watchos10.0",
            "watchsimulator": "watchos10.0-simulator",
            "xros": "xros1.0",
            "xrsimulator": "xros1.0-simulator",
            "maccatalyst": "ios15.0-macabi",
        }[platform]
        for arch in architectures:
            triple = arch + "-apple-" + target_os
            flags = [
                "xcrun",
                "--sdk",
                "macosx" if platform == "maccatalyst" else platform,
                "clang",
                "-target",
                triple,
                "-Wall",
                "-Wextra",
                "-Werror",
            ]
            binary = folder / arch
            if dynamic:
                run(
                    [
                        *flags,
                        "-dynamiclib",
                        source,
                        "-install_name",
                        "@rpath/" + name + ".framework/" + name,
                        "-compatibility_version",
                        "1.0",
                        "-current_version",
                        "1.0",
                        "-o",
                        binary,
                    ],
                    root,
                    folder / (arch + "-compile.log"),
                )
            else:
                obj = folder / (arch + ".o")
                run(
                    [*flags, "-c", source, "-o", obj],
                    root,
                    folder / (arch + "-compile.log"),
                )
                run(
                    ["xcrun", "libtool", "-static", "-o", binary, obj],
                    root,
                    folder / (arch + "-archive.log"),
                )
            binaries.append(binary)
        product = folder / ("lib" + name + ".a") if library else contents / name
        run(
            ["xcrun", "lipo", "-create", *binaries, "-output", product],
            root,
            folder / "universal.log",
        )
        if not library and platform == "macosx":
            framework.joinpath("Versions/Current").symlink_to("A")
            for item in ("Headers", "Modules", "Resources", name):
                framework.joinpath(item).symlink_to("Versions/Current/" + item)
        if library:
            arguments += ["-library", product, "-headers", headers]
        else:
            arguments += ["-framework", framework]
    output = root / (name + ".xcframework")
    run([*arguments, "-output", output], root, producer / "xcframework.log")
    return output
