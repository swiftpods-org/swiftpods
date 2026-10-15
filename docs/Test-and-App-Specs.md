# Test and app specs

Keep a library's tests and example application in the same podspec. SwiftPods
creates their targets when you select them in a Podfile. A regular installation
of the library leaves them out.

```ruby
Pod::Spec.new do |s|
  s.name = 'MyLibrary'
  s.version = '1.0.0'
  s.osx.deployment_target = '13.0'
  s.source_files = 'Sources/*.{h,m}'

  s.test_spec 'Tests' do |t|
    t.osx.deployment_target = '14.0'
    t.source_files = 'Tests/*.m'
    t.resources = 'Tests/Fixtures/*.json'
    t.dependency 'TestSupport'
    t.scheme = {
      :environment_variables => { 'FIXTURE_MODE' => 'local' },
      :code_coverage => true
    }
  end

  s.app_spec 'Example' do |a|
    a.source_files = 'Example/*.{h,m}'
    a.resources = 'Example/Resources/*'
    a.dependency 'ExampleSupport'
    a.info_plist = { 'ExampleMode' => 'local' }
  end
end
```

Select the additional specs in a Podfile:

```ruby
platform :osx, '13.0'
use_frameworks! :linkage => :static

target 'MyApp' do
  pod 'MyLibrary', :path => './Modules/MyLibrary',
      :testspecs => ['Tests'], :appspecs => ['Example']
end
```

After `swiftpods install`, open the generated workspace and select
`MyLibrary-Unit-Tests` or `MyLibrary-Example`. You can also run a test scheme
directly:

```sh
xcodebuild -project Pods/Pods.xcodeproj \
  -scheme MyLibrary-Unit-Tests -destination 'platform=macOS' test
```

Test and app sources, resources, bundles, Info.plist entries and script phases
belong to their own targets. Their additional dependencies are linked into those
targets and stay out of the consumer application. Use `resource_bundles` for
named resource bundles. Test targets can require a higher deployment minimum
than the library.

Tests that require an application host can set `t.requires_app_host = true`.
SwiftPods generates a host application. To use your own app spec instead,
declare it as a dependency of the test spec:

```ruby
t.requires_app_host = true
t.app_host_name = 'MyLibrary/Example'
t.dependency 'MyLibrary/Example'
```

Removing a selection and running `swiftpods install` again removes its generated
target and managed scheme.

## UI tests

In an iOS podspec, set `test_type` to `:ui` to generate a UI test target and runner. A named app
spec lets `XCUIApplication()` launch the application you want to test:

```ruby
s.test_spec 'Interface' do |t|
  t.test_type = :ui
  t.ios.deployment_target = '17.0'
  t.source_files = 'Interface/*.swift'
  t.requires_app_host = true
  t.app_host_name = 'MyLibrary/Example'
  t.dependency 'MyLibrary/Example'
end
```

Select `Interface` in `:testspecs` and run the `MyLibrary-UI-Interface` scheme.
If you omit `app_host_name` while keeping `requires_app_host = true`, SwiftPods
generates a host application. Unit tests and UI tests use separate hosts and
runner settings.

```swift
import XCTest

final class InterfaceTests: XCTestCase {
    @MainActor func testIncrement() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["increment"].waitForExistence(timeout: 10))
        app.buttons["increment"].tap()
        XCTAssertEqual(app.staticTexts["value"].label, "8")
    }
}
```

The currently verified build/run paths cover macOS C/Objective-C unit tests and
apps, and iOS Simulator Swift unit/UI tests and apps, including generated and
named hosts. Simulator tests use ad-hoc code signing. Choose a test deployment
minimum supported by the XCTest libraries in your installed Xcode; this can be
higher than the library minimum. Scheme `build_configurations` accepts action mappings such as
`{ 'Test' => 'Staging', 'Archive' => 'Release' }`; referenced configurations
must exist in the generated project.
macOS/tvOS UI execution, other Apple destinations and distribution signing
require further validation.

Supplementary builds also cover tvOS Simulator, visionOS Simulator and Mac
Catalyst across the three library linkage modes and Debug/Release. These build
checks do not certify execution on those destinations. For Catalyst app/test
schemes, enable Catalyst support in the generated targets, for example with the
project's existing `post_install` hook:

```ruby
post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |configuration|
      configuration.build_settings['SUPPORTS_MACCATALYST'] = 'YES'
      configuration.build_settings['SUPPORTED_PLATFORMS'] = 'iphoneos iphonesimulator macosx'
    end
  end
end
```

Selected test/app products also work with separate pod projects. Shared schemes
in `Pods/Pods.xcodeproj` point to the child project that owns each target and host.
The main project can be used with `xcodebuild -project Pods/Pods.xcodeproj -scheme
NAME test`; use the destination appropriate for the platform. See
[Projects and configurations](Projects-and-Configurations.md) for the layout and
hook project lists.
