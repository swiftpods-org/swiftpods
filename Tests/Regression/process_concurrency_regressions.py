"""Concurrent process streams and signal state preserve ownership and caller data."""

import json
import platform
import subprocess
import tempfile
from pathlib import Path

from scripts.support.bootstrap import ROOT
from Tests.Fixtures.vendor_fixture import run


def compile_c(fixture, build, source_root, source, label, options=()):
    binary = build / label
    run(
        [
            "xcrun",
            "clang",
            "-std=c11",
            "-Wall",
            "-Wextra",
            "-Werror",
            "-mmacosx-version-min=13.0",
            *options,
            "-I",
            source_root / "Sources/ProcessSupport/include",
            source_root / "Sources/ProcessSupport/ProcessSupport.c",
            ROOT / "Tests/Fixtures" / source,
            "-o",
            binary,
        ],
        ROOT,
        fixture.root / (label + "-build.log"),
        env=fixture.env,
    )
    return binary


def capture_concurrency(fixture, source_root=ROOT):
    with tempfile.TemporaryDirectory(
        prefix="concurrent-capture-", dir=fixture.root
    ) as temporary:
        build = Path(temporary)
        include = source_root / "Sources/ProcessSupport/include"
        (build / "module.modulemap").write_text(
            "module ProcessSupport { header "
            + json.dumps(str(include / "ProcessSupport.h"))
            + " export * }\n"
        )
        object_file = build / "ProcessSupport.o"
        run(
            [
                "xcrun",
                "clang",
                "-std=c11",
                "-Wall",
                "-Wextra",
                "-Werror",
                "-mmacosx-version-min=13.0",
                "-I",
                include,
                "-c",
                source_root / "Sources/ProcessSupport/ProcessSupport.c",
                "-o",
                object_file,
            ],
            ROOT,
            fixture.root / "concurrent-capture-c-build.log",
            env=fixture.env,
        )
        sources = [
            source_root / "Sources/SwiftPodsCore" / (name + ".swift")
            for name in [
                "NativeChildProcess",
                "ToolProcess",
                "NativeGitEnvironment",
                "NativeProcessEnvironment",
                "Diagnostics",
                "NativeJSON",
                "NativeDictionaryKeys",
                "NativeScalarString",
            ]
        ]
        for optimization in ["Onone", "O"]:
            binary = build / ("fixture-" + optimization)
            run(
                [
                    "xcrun",
                    "swiftc",
                    "-swift-version",
                    "5",
                    "-warnings-as-errors",
                    "-" + optimization,
                    "-target",
                    platform.machine() + "-apple-macosx13.0",
                    "-I",
                    build,
                    *sources,
                    ROOT / "Tests/Fixtures/ConcurrentProcessInput.swift",
                    object_file,
                    "-o",
                    binary,
                ],
                ROOT,
                fixture.root / ("concurrent-capture-swift-" + optimization + ".log"),
                env=fixture.env,
            )
            for mask in range(1, 8):
                observation = build / (str(mask) + ".json")
                driver = subprocess.run(
                    [str(binary), str(mask), str(observation)],
                    stdin=subprocess.DEVNULL,
                    capture_output=True,
                    text=True,
                    timeout=45,
                    env=fixture.env,
                )
                assert driver.returncode == 0, (
                    mask,
                    driver.returncode,
                    driver.stdout,
                    driver.stderr,
                )
                result = json.loads(observation.read_text())
                label = (
                    "concurrent_capture_" + optimization + "_closed_mask_" + str(mask)
                )
                (fixture.root / (label + ".json")).write_text(
                    json.dumps(result, indent=2) + "\n"
                )
                assert result == {
                    "mask": mask,
                    "calls": 800,
                    "succeeded": 800,
                    "rejected": 48,
                    "failed": 0,
                    "examples": [],
                }, result
                fixture.verified.append(label)


def cancellation_concurrency(fixture, source_root=ROOT):
    with tempfile.TemporaryDirectory(
        prefix="signal-tsan-", dir=fixture.root
    ) as temporary:
        build = Path(temporary)
        binary = compile_c(
            fixture,
            build,
            source_root,
            "ProcessCancellationFixture.c",
            "signal-tsan",
            ["-fsanitize=thread", "-g", "-O1"],
        )
        environment = dict(fixture.env)
        environment["TSAN_OPTIONS"] = "halt_on_error=0:abort_on_error=0:exitcode=66"
        for mode in ["reader", "registry"]:
            text = run(
                [binary, mode, build],
                ROOT,
                fixture.root / ("signal-tsan-" + mode + ".log"),
                env=environment,
                timeout=15,
            )
            assert "passed=" + mode in text and "ThreadSanitizer" not in text, text
            fixture.verified.append("signal_" + mode + "_thread_sanitizer_clean")


def signal_errno(fixture, source_root=ROOT):
    with tempfile.TemporaryDirectory(
        prefix="signal-errno-", dir=fixture.root
    ) as temporary:
        build = Path(temporary)
        binary = compile_c(
            fixture,
            build,
            source_root,
            "ProcessSignalErrnoFixture.c",
            "signal-errno",
            ["-Dkill=fixture_kill"],
        )
        for mode, arguments in [("empty", []), ("registered", ["registered-child"])]:
            text = run(
                [binary, *arguments],
                ROOT,
                fixture.root / ("signal-errno-" + mode + ".log"),
                env=fixture.env,
                timeout=8,
            )
            assert "raise=0 errno=33 expected=33" in text, text
            fixture.verified.append("signal_preserves_errno_" + mode + "_registry")


def run_regressions(fixture):
    capture_concurrency(fixture)
    cancellation_concurrency(fixture)
    signal_errno(fixture)
