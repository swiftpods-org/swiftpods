#!/usr/bin/env python3
"""Build supplementary hosts and execute locally available Catalyst tests."""

import argparse
import json
import os
import platform
import signal
import subprocess
import sys
from pathlib import Path

from scripts.support.bootstrap import environment
from scripts.support.local_build import fixture_directory, results_directory
from scripts.support.reporting import execute
from Tests.Fixtures.vendor_fixture import (
    fixture_build_arguments,
    fixture_derived_data,
    run,
)
from Tests.Integration.native_supplementary_tests import install

DESTINATIONS = {
    "tvos": ("tvos", "17.0", "appletvsimulator", "tvOS Simulator"),
    "visionos": ("visionos", "1.0", "xrsimulator", "visionOS Simulator"),
    "catalyst": ("ios", "17.0", "macosx", "macOS,variant=Mac Catalyst"),
}


def report_name():
    arguments = sys.argv[1:]
    if "--" in arguments:
        arguments = arguments[: arguments.index("--")]
    execution = any(
        value == "--execute-ui" or value.startswith("--execute-ui=")
        for value in arguments
    )
    return "native-host-executions.json" if execution else "native-host-platforms.json"


def execute_catalyst(work, scheme, configuration, swift, env):
    parent = work / "Executed"
    parent.mkdir(exist_ok=True)
    log = work / (scheme + "-" + configuration + "-execution.log")
    arguments = [
        "xcodebuild",
        "-project",
        "Pods/Pods.xcodeproj",
        "-scheme",
        scheme,
        "-configuration",
        configuration,
        "-destination",
        "platform=macOS,variant=Mac Catalyst,arch=" + platform.machine(),
        *fixture_build_arguments(parent),
        "-parallel-testing-enabled",
        "NO",
        "CODE_SIGNING_ALLOWED=YES",
        "CODE_SIGN_IDENTITY=-",
        # Ad-hoc hosted tests cannot satisfy hardened runtime library validation.
        "ENABLE_HARDENED_RUNTIME=NO",
        "GCC_TREAT_WARNINGS_AS_ERRORS=YES",
        "SWIFT_TREAT_WARNINGS_AS_ERRORS=YES",
        "ARCHS=" + platform.machine(),
        "ONLY_ACTIVE_ARCH=YES",
        "TOOLCHAIN_DIR=" + str(swift.parents[2]),
        "TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault",
        "test",
    ]
    try:
        text = run(arguments, work, log, env, timeout=180)
    finally:
        # LaunchServices can detach a test host from xcodebuild's process group.
        directory = fixture_derived_data(parent)
        prefixes = [str(directory) + "/", str(directory.resolve()) + "/"]
        processes = subprocess.check_output(["ps", "-axo", "pid=,command="], text=True)
        for line in processes.splitlines():
            fields = line.strip().split(maxsplit=1)
            if len(fields) == 2 and any(
                fields[1].startswith(prefix) for prefix in prefixes
            ):
                try:
                    os.kill(int(fields[0]), signal.SIGTERM)
                except ProcessLookupError:
                    pass
    test = "testHostLaunch" if "-UI-" in scheme else "testLibraryAndResource"
    assert test in text and "** TEST SUCCEEDED **" in text, log
    return {
        "platform": "ios",
        "sdk": "maccatalyst",
        "configuration": configuration,
        "scheme": scheme,
        "architecture": platform.machine(),
        "test": test,
        "log": str(log),
    }


def create(work, name, linkage):
    work.mkdir(parents=True)
    platform_name, minimum, _, _ = DESTINATIONS[name]
    module = work / "HostMatrixKit"
    module.mkdir()
    for folder in ["Sources", "Tests", "UI", "App"]:
        (module / folder).mkdir()
    (module / "Sources/HostMatrixKit.h").write_text("int host_matrix_value(void);\n")
    (module / "Sources/HostMatrixKit.m").write_text(
        "int host_matrix_value(void) { return 41; }\n"
    )
    (module / "Tests/own.txt").write_text("unit-resource")
    (module / "Tests/Tests.m").write_text("""#import <XCTest/XCTest.h>
#import <HostMatrixKit/HostMatrixKit.h>
@interface HostMatrixTests : XCTestCase @end
@implementation HostMatrixTests
- (void)testLibraryAndResource { XCTAssertEqual(host_matrix_value(), 41); XCTAssertNotNil([[NSBundle bundleForClass:self.class] pathForResource:@"own" ofType:@"txt"]); }
@end
""")
    (module / "UI/Tests.m").write_text("""#import <XCTest/XCTest.h>
@interface HostMatrixUITests : XCTestCase @end
@implementation HostMatrixUITests
- (void)testHostLaunch { XCUIApplication *app = [XCUIApplication new]; [app launch]; XCTAssertNotEqual(app.state, XCUIApplicationStateNotRunning); [app terminate]; }
@end
""")
    (module / "App/main.m").write_text(
        """#import <UIKit/UIKit.h>
#import <HostMatrixKit/HostMatrixKit.h>
@interface HostMatrixScene : UIResponder <UIWindowSceneDelegate>
@property (nonatomic, strong) UIWindow *window;
@end
@implementation HostMatrixScene
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    UIViewController *controller = [UIViewController new];
    controller.view.backgroundColor = UIColor.whiteColor;
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(24, 80, 200, 44)];
    label.textColor = UIColor.blackColor;
    label.text = [NSString stringWithFormat:@"%d", host_matrix_value()];
    label.accessibilityIdentifier = @"library-value";
    [controller.view addSubview:label];
    self.window.rootViewController = controller;
    [self.window makeKeyAndVisible];
}
@end
@interface HostMatrixDelegate : UIResponder <UIApplicationDelegate>
@end
@implementation HostMatrixDelegate
- (UISceneConfiguration *)application:(UIApplication *)application configurationForConnectingSceneSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    UISceneConfiguration *configuration = [[UISceneConfiguration alloc] initWithName:@"Main" sessionRole:session.role];
    configuration.delegateClass = HostMatrixScene.class;
    return configuration;
}
@end
int main(int argc, char **argv) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(HostMatrixDelegate.class)); }
}
"""
    )
    tests = [
        {"name": label, "source_files": "Tests/*.m", "resources": "Tests/own.txt"}
        for label in ["Standalone", "Generated", "Named"]
    ]
    tests[1]["requires_app_host"] = True
    tests[2].update(
        requires_app_host=True,
        app_host_name="HostMatrixKit/Example",
        dependencies={"HostMatrixKit/Example": []},
    )
    tests += [
        {
            "name": label,
            "test_type": "ui",
            "requires_app_host": True,
            "source_files": "UI/*.m",
            **(
                {
                    "app_host_name": "HostMatrixKit/Example",
                    "dependencies": {"HostMatrixKit/Example": []},
                }
                if label == "NamedUI"
                else {}
            ),
        }
        for label in ["NamedUI", "GeneratedUI"]
    ]
    spec = {
        "name": "HostMatrixKit",
        "version": "1.0",
        "summary": "Supplementary SDK fixture",
        "homepage": "https://swiftpods.org",
        "authors": "SwiftPods",
        "license": "MIT",
        "source": {"git": "https://example.invalid/fixture.git", "tag": "1.0"},
        "source_files": "Sources/*.{h,m}",
        "platforms": {platform_name: minimum},
        "testspecs": tests,
        "appspecs": [
            {
                "name": "Example",
                "source_files": "App/main.m",
                "frameworks": ["UIKit"],
                "info_plist": {
                    "UIApplicationSceneManifest": {
                        "UIApplicationSupportsMultipleScenes": False,
                        "UISceneConfigurations": {},
                    }
                },
            }
        ],
    }
    (module / "HostMatrixKit.podspec.json").write_text(json.dumps(spec))
    text = f"platform :{platform_name}, '{minimum}'\n"
    if linkage != "library":
        text += f"use_frameworks! :linkage => :{linkage}\n"
    text += "target 'App' do\n pod 'HostMatrixKit', :path => './HostMatrixKit', :testspecs => ['Standalone', 'Generated', 'Named', 'NamedUI', 'GeneratedUI']\nend\n"
    if name == "catalyst":
        text += """post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |configuration|
      configuration.build_settings['SUPPORTS_MACCATALYST'] = 'YES'
      configuration.build_settings['SUPPORTED_PLATFORMS'] = 'iphoneos iphonesimulator macosx'
    end
  end
end
"""
    (work / "Podfile").write_text(text)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", choices=list(DESTINATIONS), action="append")
    parser.add_argument(
        "--linkage", choices=["library", "static", "dynamic"], action="append"
    )
    parser.add_argument(
        "--configuration", choices=["Debug", "Release"], action="append"
    )
    parser.add_argument(
        "--execute-ui",
        action="store_true",
        help="Also execute Catalyst UI runners; requires macOS developer mode",
    )
    args = parser.parse_args()
    platforms = list(dict.fromkeys(args.platform or DESTINATIONS))
    linkages = list(dict.fromkeys(args.linkage or ["library", "static", "dynamic"]))
    configurations = list(dict.fromkeys(args.configuration or ["Debug", "Release"]))
    if args.execute_ui:
        if "catalyst" not in platforms:
            parser.error("--execute-ui requires Catalyst in the selected platforms")
        status = subprocess.check_output(["DevToolsSecurity", "-status"], text=True)
        if "disabled" in status.lower():
            raise RuntimeError(
                "Catalyst UI execution requires macOS developer mode: sudo DevToolsSecurity -enable"
            )
    parent = fixture_directory("native-host-platforms-")
    print("Host platform fixtures:", parent, flush=True)
    env = environment()
    env["SWIFTPODS_CACHE_ROOT"] = str(parent / "cache")
    swift = Path(
        subprocess.check_output(["xcrun", "--find", "swiftc"], text=True).strip()
    )
    builds = []
    executions = []
    for name in platforms:
        platform_name, minimum, sdk, destination = DESTINATIONS[name]
        for linkage in linkages:
            work = parent / (name + "-" + linkage)
            create(work, name, linkage)
            install(work, env, "--no-integrate")
            for configuration in configurations:
                for scheme in [
                    "HostMatrixKit-Example",
                    "HostMatrixKit-Unit-Standalone",
                    "HostMatrixKit-Unit-Generated",
                    "HostMatrixKit-Unit-Named",
                    "HostMatrixKit-UI-NamedUI",
                    "HostMatrixKit-UI-GeneratedUI",
                ]:
                    command = [
                        "xcodebuild",
                        "-project",
                        "Pods/Pods.xcodeproj",
                        "-scheme",
                        scheme,
                        "-configuration",
                        configuration,
                        "-destination",
                        "generic/platform=" + destination,
                        "-sdk",
                        sdk,
                        "-derivedDataPath",
                        work / "DerivedData",
                        "CODE_SIGNING_ALLOWED=NO",
                        "GCC_TREAT_WARNINGS_AS_ERRORS=YES",
                        "SWIFT_TREAT_WARNINGS_AS_ERRORS=YES",
                        "ARCHS=" + platform.machine(),
                        "ONLY_ACTIVE_ARCH=YES",
                    ]
                    command += [
                        "TOOLCHAIN_DIR=" + str(swift.parents[2]),
                        "TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault",
                    ]
                    if name == "catalyst":
                        command += ["SUPPORTS_MACCATALYST=YES"]
                    log = work / (scheme + "-" + configuration + ".log")
                    run(
                        command
                        + [
                            "build-for-testing"
                            if "-Unit-" in scheme or "-UI-" in scheme
                            else "build"
                        ],
                        work,
                        log,
                        env,
                    )
                    builds.append(
                        {
                            "platform": platform_name,
                            "sdk": "maccatalyst" if name == "catalyst" else sdk,
                            "destination": destination,
                            "configuration": configuration,
                            "linkage": linkage,
                            "scheme": scheme,
                            "architecture": platform.machine(),
                            "log": str(log),
                        }
                    )
                    if name == "catalyst" and (
                        "-Unit-" in scheme or (args.execute_ui and "-UI-" in scheme)
                    ):
                        execution = execute_catalyst(
                            work, scheme, configuration, swift, env
                        )
                        execution["linkage"] = linkage
                        executions.append(execution)
    report = {
        "status": "passed",
        "engine": "swift",
        "fixture": str(parent),
        "builds": builds,
        "executions": executions,
        "verified": [
            "real app, standalone/generated/named unit targets and generated/named UI runners build for the explicitly listed SDK configurations",
        ],
        "unverified": [
            "tvOS and visionOS execution",
            "device SDK supplementary builds and signing",
            "watchOS supplementary targets",
            "native macOS AppKit UI interaction",
            "complete supplementary host matrix",
        ],
    }
    if executions:
        report["verified"].append(
            "Catalyst standalone/generated/named unit targets execute and verify their library "
            "and bundle resources in the explicitly selected configurations"
        )
    if args.execute_ui:
        report["verified"].append(
            "Catalyst named/generated UI runners execute in the explicitly selected configurations"
        )
    else:
        report["unverified"].append(
            "Catalyst UI execution requires --execute-ui and macOS developer mode"
        )
    (results_directory() / report_name()).write_text(
        json.dumps(report, indent=2) + "\n"
    )
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    execute(main, report_name())
