# Unity

In the Xcode project Unity exports for iOS, `Unity-iPhone` embeds
`UnityFramework`, the target that holds the native code of plugins. The
SwiftPods package for Unity installs a Podfile's Swift packages and binary SDKs
into `UnityFramework` after every iOS build, in place of CocoaPods and the
External Dependency Manager (EDM4U).

## Setup

1. Add the package to `Packages/manifest.json`:

   ```json
   "org.swiftpods.unity": "https://github.com/swiftpods-org/swiftpods.git?path=Unity#v0.3.1"
   ```

2. Install `swiftpods` on every Mac that builds the game ([Installation](Release.md)).
3. Write the Podfile in `ios/` next to `Assets/`. Inside `Assets/`, Unity would
   import its Swift files as plugins.

   ```ruby
   platform :ios, '15.0'

   target 'UnityFramework' do
     spm 'Firebase', '12.0.0', products: %w[FirebaseCore FirebaseAnalytics FirebaseCrashlytics]
     spm 'Facebook', '~> 18.0.0', products: %w[FacebookCore FacebookLogin FacebookShare FacebookGamingServices]
   end
   ```

   Leave out `project`: the package passes the exported project. Declare the
   versions the Unity plugins list in their `*Dependencies.xml`; the native
   libraries of the Firebase Unity SDK, for example, are built for one Firebase
   iOS version.
4. Add `ios/SwiftPods/` to `.gitignore`.

`Unity-iPhone` needs no entry: SwiftPods embeds the dynamic frameworks that
`UnityFramework` links ([Frameworks embedded in an app](Podfile.md#frameworks-embedded-in-an-app)).

## What the package does

On an iOS build of a project with `ios/Podfile`:

- Before the build, it turns off Podfile generation in EDM4U's iOS Resolver
  settings, so CocoaPods does not run. EDM4U saves the setting in
  `ProjectSettings/GvhProjectSettings.xml`; commit that change.
- After the build and the other plugins' post-processing, it points the
  Crashlytics Run Script that Firebase adds from `Pods/` to Xcode's checkout of
  `firebase-ios-sdk`, then runs `swiftpods install` with
  `--project <export>/Unity-iPhone.xcodeproj` in `ios/`. A SwiftPods error fails
  the Unity build.

Both of Unity's build modes work: Replace exports a new project, and Append
keeps the project, which `swiftpods install` brings up to date. Without CocoaPods
there is no workspace, so build `Unity-iPhone.xcodeproj` with `xcodebuild -project`
or Fastlane's `project:`.

## Environment

| Variable | Default |
| --- | --- |
| `SWIFTPODS_PODFILE_DIRECTORY` | `ios`, relative to the Unity project |
| `SWIFTPODS` | the first `swiftpods` in `PATH`, `/opt/homebrew/bin` or `/usr/local/bin` |

An editor started from the Dock or Unity Hub does not see the shell's `PATH`.
On Windows the package installs nothing and logs the command to run on a Mac.
