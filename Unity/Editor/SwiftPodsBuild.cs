using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Reflection;
using UnityEditor;
using UnityEditor.Build;
using UnityEditor.Build.Reporting;
using UnityEngine;
using Debug = UnityEngine.Debug;

namespace SwiftPods.Editor
{
    /// <summary>
    /// The Podfile of an iOS build: in <c>ios/</c> next to <c>Assets/</c>, or in the directory
    /// <c>SWIFTPODS_PODFILE_DIRECTORY</c> names. Without one, the package does nothing.
    /// </summary>
    static class Podfile
    {
        public static string Directory
        {
            get
            {
                var configured = Environment.GetEnvironmentVariable("SWIFTPODS_PODFILE_DIRECTORY");
                var root = Path.GetDirectoryName(Application.dataPath);
                return Path.GetFullPath(Path.Combine(root, string.IsNullOrEmpty(configured) ? "ios" : configured));
            }
        }

        public static bool Applies(BuildReport report) =>
            report.summary.platform == BuildTarget.iOS && File.Exists(Path.Combine(Directory, "Podfile"));
    }

    /// <summary>
    /// The External Dependency Manager would generate its own Podfile next to the Xcode project and run
    /// <c>pod install</c>; SwiftPods replaces both.
    /// </summary>
    public class SwiftPodsDisableCocoaPods : IPreprocessBuildWithReport
    {
        public int callbackOrder => 0;

        public void OnPreprocessBuild(BuildReport report)
        {
            if (!Podfile.Applies(report)) return;
            var resolver = AppDomain.CurrentDomain.GetAssemblies()
                .Select(assembly => assembly.GetType("Google.IOSResolver", false)).FirstOrDefault(type => type != null);
            var generation = resolver?.GetProperty("PodfileGenerationEnabled", BindingFlags.Public | BindingFlags.Static);
            if (generation == null || !(bool)generation.GetValue(null)) return;
            generation.SetValue(null, false);
            Debug.Log("SwiftPods: turned off Podfile generation in the iOS Resolver settings of the External Dependency Manager, so CocoaPods does not run");
        }
    }

    /// <summary>
    /// Installs the Podfile into the exported Xcode project. Runs last, so script phases other plugins add are already
    /// there; an interface rather than <c>[PostProcessBuild]</c>, whose exceptions Unity logs without failing the build.
    /// </summary>
    public class SwiftPodsInstall : IPostprocessBuildWithReport
    {
        public int callbackOrder => int.MaxValue;

        public void OnPostprocessBuild(BuildReport report)
        {
            if (!Podfile.Applies(report)) return;
            var project = Path.Combine(report.summary.outputPath, "Unity-iPhone.xcodeproj");
            if (Application.platform != RuntimePlatform.OSXEditor)
            {
                Debug.LogWarning($"SwiftPods: run `swiftpods install --project {project}` in {Podfile.Directory} on a Mac before building the Xcode project");
                return;
            }
            ReplacePodsPaths(Path.Combine(project, "project.pbxproj"));
            Install(project);
        }

        /// <summary>
        /// Firebase Crashlytics adds a Run Script that runs its tool from <c>Pods/</c>; with Swift packages the tool is
        /// in Xcode's checkout of firebase-ios-sdk.
        /// </summary>
        static void ReplacePodsPaths(string file)
        {
            var text = File.ReadAllText(file);
            var replaced = text.Replace(
                "${PROJECT_DIR}/Pods/FirebaseCrashlytics/", "${BUILD_DIR%/Build/*}/SourcePackages/checkouts/firebase-ios-sdk/Crashlytics/");
            if (replaced != text) File.WriteAllText(file, replaced);
        }

        static void Install(string project)
        {
            var start = new ProcessStartInfo(Executable(), $"install --project-directory \"{Podfile.Directory}\" --project \"{project}\"")
            {
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
            };
            using var process = Process.Start(start);
            var output = process.StandardOutput.ReadToEndAsync();
            var error = process.StandardError.ReadToEnd();
            process.WaitForExit();
            if (process.ExitCode != 0) throw new BuildFailedException("SwiftPods: " + error.Trim());
            Debug.Log("SwiftPods: " + output.Result.Trim());
        }

        /// <summary>The <c>swiftpods</c> executable: <c>SWIFTPODS</c>, else the first in PATH or Homebrew's directories.</summary>
        static string Executable()
        {
            var configured = Environment.GetEnvironmentVariable("SWIFTPODS");
            if (!string.IsNullOrEmpty(configured)) return configured;
            // An editor started from the Dock or Unity Hub does not see the shell's PATH.
            var directories = (Environment.GetEnvironmentVariable("PATH") ?? "").Split(':').Where(path => path.Length > 0)
                .Concat(new[] { "/opt/homebrew/bin", "/usr/local/bin" });
            return directories.Select(directory => Path.Combine(directory, "swiftpods")).FirstOrDefault(File.Exists)
                ?? throw new BuildFailedException("SwiftPods: swiftpods is not in PATH, /opt/homebrew/bin or /usr/local/bin; install it or set SWIFTPODS to its path");
        }
    }
}
