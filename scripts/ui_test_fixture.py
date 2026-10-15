"""Independent iOS test/app fixture with observable UI interaction."""

import json
import platform
import shutil
import subprocess
from contextlib import contextmanager
from pathlib import Path

from bootstrap import ROOT
from native_integration import project
from script_phase_fixture import ruby
from vendor_fixture import fixture_build_arguments, run

APP = """import UIKit
import UIWidget

@main final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Example", sessionRole: session.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = ExampleController()
        self.window = window
        window.makeKeyAndVisible()
    }
}
final class ExampleController: UIViewController {
    private var value = uiwidget_value()
    private let label = UILabel()
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        label.frame = CGRect(x: 24, y: 100, width: 240, height: 44)
        label.accessibilityIdentifier = "value"
        label.text = String(value)
        view.addSubview(label)
        let button = UIButton(type: .system)
        button.frame = CGRect(x: 24, y: 180, width: 240, height: 44)
        button.setTitle("Increment", for: .normal)
        button.accessibilityIdentifier = "increment"
        button.addTarget(self, action: #selector(increment), for: .touchUpInside)
        view.addSubview(button)
    }
    @objc private func increment() { value += 1; label.text = String(value) }
}
"""

UI_TEST = """import XCTest
import UIWidget

final class InterfaceTests: XCTestCase {
    @MainActor func testButtonChangesLibraryValue() throws {
        XCTAssertEqual(uiwidget_value(), 7)
        XCTAssertEqual(ProcessInfo.processInfo.environment["SWIFTPODS_UI_CASE"], "interactive")
        let bundle = Bundle(for: Self.self)
        XCTAssertEqual(bundle.infoDictionary?["OwnMarker"] as? String, "ui")
        XCTAssertNotNil(bundle.url(forResource: "fixture", withExtension: "json"))
        let app = XCUIApplication()
        app.launch()
        let button = app.buttons["increment"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["value"].label, "7")
        button.tap()
        XCTAssertEqual(app.staticTexts["value"].label, "8")
        app.terminate()
    }
}
"""

GENERATED_TEST = """import XCTest
import UIWidget

final class GeneratedHostTests: XCTestCase {
    @MainActor func testGeneratedHostLaunches() {
        XCTAssertEqual(uiwidget_value(), 7)
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["SwiftPods"].waitForExistence(timeout: 10))
        app.terminate()
    }
}
"""

UNIT_TEST = """import XCTest
import UIWidget

final class LibraryTests: XCTestCase {
    func testLibraryAndOwnResources() {
        XCTAssertEqual(uiwidget_value(), 7)
        let bundle = Bundle(for: Self.self)
        XCTAssertEqual(bundle.infoDictionary?["OwnMarker"] as? String, "unit")
        XCTAssertNotNil(bundle.url(forResource: "unit", withExtension: "json"))
        XCTAssertNil(bundle.url(forResource: "fixture", withExtension: "json"))
    }
}
"""


def podfile(work, linkage="static", selections=True):
    text = "platform :ios, '15.0'\nproject 'Demo.xcodeproj'\n"
    if linkage:
        text += "use_frameworks! :linkage => :" + linkage + "\n"
    options = (
        ", :testspecs => ['Interface', 'Generated', 'Units', 'Hosted']"
        if selections
        else ""
    )
    work.joinpath("Podfile").write_text(
        text
        + "target 'Demo' do\n  pod 'UIWidget', :path => './Modules/UIWidget'"
        + options
        + "\nend\n"
    )


def create(work, linkage="static"):
    work.mkdir()
    module = work / "Modules/UIWidget"
    module.mkdir(parents=True)
    for folder in ["Sources", "Example", "Interface", "Generated", "Units"]:
        module.joinpath(folder).mkdir()
    module.joinpath("Sources/UIWidget.h").write_text("int uiwidget_value(void);\n")
    module.joinpath("Sources/UIWidget.m").write_text(
        "int uiwidget_value(void) { return 7; }\n"
    )
    for folder, name, content in [
        ("Example", "Example.swift", APP),
        ("Interface", "InterfaceTests.swift", UI_TEST),
        ("Generated", "GeneratedTests.swift", GENERATED_TEST),
        ("Units", "LibraryTests.swift", UNIT_TEST),
    ]:
        module.joinpath(folder, name).write_text(content)
        # A real AppIntents declaration keeps current Xcode metadata extraction
        # meaningful in each Swift product, without disabling diagnostics.
        shutil.copy2(
            ROOT / "Tests/Fixtures/iOS/FixtureIntent.swift",
            module / folder / "FixtureIntent.swift",
        )
    module.joinpath("Interface/fixture.json").write_text('{"scope":"ui"}\n')
    module.joinpath("Units/unit.json").write_text('{"scope":"unit"}\n')
    data = {
        "name": "UIWidget",
        "version": "1.0.0",
        "summary": "Independent UI runner fixture",
        "homepage": "https://swiftpods.org",
        "license": "MIT",
        "author": "SwiftPods",
        "source": {"git": "https://example.invalid/widget.git", "tag": "1.0.0"},
        "source_files": "Sources/*.{h,m}",
        "platforms": {"ios": "15.0"},
    }
    tests = [
        {
            "name": "Interface",
            "test_type": "ui",
            "requires_app_host": True,
            "app_host_name": "UIWidget/Example",
            "dependencies": {"UIWidget/Example": []},
            "source_files": "Interface/*.swift",
            "resources": "Interface/*.json",
            "info_plist": {"OwnMarker": "ui"},
            "scheme": {"environment_variables": {"SWIFTPODS_UI_CASE": "interactive"}},
        },
        {
            "name": "Generated",
            "test_type": "ui",
            "requires_app_host": True,
            "source_files": "Generated/*.swift",
        },
        {
            "name": "Units",
            "test_type": "unit",
            "source_files": "Units/*.swift",
            "resources": "Units/*.json",
            "info_plist": {"OwnMarker": "unit"},
        },
        {
            "name": "Hosted",
            "test_type": "unit",
            "requires_app_host": True,
            "app_host_name": "UIWidget/Example",
            "dependencies": {"UIWidget/Example": []},
            "source_files": "Units/*.swift",
            "resources": "Units/*.json",
            "info_plist": {"OwnMarker": "unit"},
        },
    ]
    for node in tests:
        node["ios"] = {"deployment_target": "17.0"}
    apps = [
        {
            "name": "Example",
            "source_files": "Example/*.swift",
            "frameworks": ["UIKit"],
            "info_plist": {
                "UIApplicationSceneManifest": {
                    "UIApplicationSupportsMultipleScenes": False,
                    "UISceneConfigurations": {},
                }
            },
        }
    ]
    lines = ["Pod::Spec.new do |s|"]
    lines += [
        "  s." + key + " = " + ruby(value)
        for key, value in data.items()
        if key != "platforms"
    ]
    lines += ["  s.ios.deployment_target = '15.0'"]
    for field, nodes in [("test_spec", tests), ("app_spec", apps)]:
        for node in nodes:
            lines.append("  s." + field + " " + ruby(node["name"]) + " do |n|")
            for key, value in node.items():
                if key == "name":
                    continue
                if key == "ios":
                    lines.append(
                        "    n.ios.deployment_target = "
                        + ruby(value["deployment_target"])
                    )
                elif key == "dependencies":
                    lines += ["    n.dependency " + ruby(name) for name in value]
                else:
                    lines.append("    n." + key + " = " + ruby(value))
            lines.append("  end")
    module.joinpath("UIWidget.podspec").write_text("\n".join(lines + ["end"]) + "\n")
    data.update(testspecs=tests, appspecs=apps)
    work.joinpath("Sources").mkdir()
    work.joinpath("Sources/main.mm").write_text("int main(void) { return 0; }\n")
    shutil.copy2(
        ROOT / "Tests/Fixtures/iOS/FixtureIntent.swift",
        work / "Sources/FixtureIntent.swift",
    )
    project(work / "Demo.xcodeproj", "ios")
    podfile(work, linkage)
    return data


def declarative(work, data):
    work.joinpath("Modules/UIWidget/UIWidget.podspec.json").write_text(
        json.dumps(data, indent=2) + "\n"
    )
    manifest = {
        "schema_version": 1,
        "platform": {"name": "ios", "deployment_target": "15.0"},
        "project": "Demo.xcodeproj",
        "frameworks": "static",
        "targets": [
            {
                "name": "Demo",
                "pods": [
                    {
                        "name": "UIWidget",
                        "path": "./Modules/UIWidget",
                        "testspecs": ["Interface", "Generated", "Units", "Hosted"],
                    }
                ],
            }
        ],
    }
    work.joinpath("Podfile.json").write_text(json.dumps(manifest, indent=2) + "\n")


@contextmanager
def simulator(parent):
    runtimes = json.loads(
        subprocess.check_output(["xcrun", "simctl", "list", "runtimes", "-j"])
    )["runtimes"]
    available = [
        item
        for item in runtimes
        if item.get("isAvailable")
        and item["identifier"].startswith("com.apple.CoreSimulator.SimRuntime.iOS-")
        and platform.machine()
        in item.get("supportedArchitectures", [platform.machine()])
    ]
    if not available:
        raise RuntimeError(
            "An available iOS simulator runtime is required for UI acceptance"
        )
    runtime = max(
        available, key=lambda item: tuple(map(int, item["version"].split(".")))
    )
    kind = next(
        item["identifier"]
        for item in runtime["supportedDeviceTypes"]
        if item["productFamily"] == "iPhone"
    )
    device = subprocess.check_output(
        [
            "xcrun",
            "simctl",
            "create",
            "SwiftPods UI Fixture",
            kind,
            runtime["identifier"],
        ],
        text=True,
    ).strip()
    try:
        run(["xcrun", "simctl", "boot", device], parent, parent / "simulator-boot.log")
        run(
            ["xcrun", "simctl", "bootstatus", device, "-b"],
            parent,
            parent / "simulator-ready.log",
        )
        yield device
    finally:
        subprocess.run(["xcrun", "simctl", "shutdown", device], capture_output=True)
        subprocess.run(
            ["xcrun", "simctl", "delete", device], check=True, capture_output=True
        )


def build(
    work, parent, scheme, device=None, action="build-for-testing", configuration="Debug"
):
    destination = (
        "platform=iOS Simulator,id=" + device
        if device
        else "generic/platform=iOS Simulator"
    )
    # SwiftBuild can otherwise expand the reference's Swift library path using
    # the installed Metal toolchain, which has no Swift runtime libraries.
    swift = Path(
        subprocess.check_output(["xcrun", "--find", "swiftc"], text=True).strip()
    )
    arguments = [
        "xcodebuild",
        "-project",
        "Pods/Pods.xcodeproj",
        "-scheme",
        scheme,
        "-configuration",
        configuration,
        "-destination",
        destination,
        *fixture_build_arguments(parent),
        "-parallel-testing-enabled",
        "NO",
        "CODE_SIGNING_ALLOWED=YES",
        "CODE_SIGN_IDENTITY=-",
        "TOOLCHAIN_DIR=" + str(swift.parents[2]),
        action,
    ]
    prefix = scheme + "-" + configuration + "-" + action
    text = run(
        arguments,
        work,
        parent
        / (prefix + "-" + str(len(list(parent.glob(prefix + "-*.log")))) + ".log"),
    )
    if action == "test":
        assert "** TEST SUCCEEDED **" in text
    return text
