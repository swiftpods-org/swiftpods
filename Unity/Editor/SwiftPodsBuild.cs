using System;
using System.Collections;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
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
        const int MaximumCommandCharacters = 4 * 1024 * 1024;
        const int NoSuchProcess = 3;
        const int SignalTerminate = 15;
        const int SignalKill = 9;
        const string SessionLauncher = "import os,sys; os.setsid(); os.execv(sys.argv[1], sys.argv[1:])";
        static readonly TimeSpan CommandTimeout = TimeSpan.FromMinutes(30);
        static readonly TimeSpan TerminationGracePeriod = TimeSpan.FromSeconds(2);
        static readonly TimeSpan ForcedTerminationPeriod = TimeSpan.FromSeconds(5);

        [DllImport("/usr/lib/libproc.dylib", SetLastError = true)]
        static extern int proc_listallpids([Out] int[] buffer, int bufferSize);

        [DllImport("libc", SetLastError = true)]
        static extern int getsid(int processId);

        [DllImport("libc", SetLastError = true)]
        static extern int kill(int processId, int signal);

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
            Install(project);
        }

        static void Install(string project)
        {
            var arguments = new[] { "install", "--project-directory", Podfile.Directory, "--project", project }.ToList();
            if (string.Equals(Environment.GetEnvironmentVariable("SWIFTPODS_ALLOW_EXTERNAL_FILE_LISTS"), "1", StringComparison.Ordinal))
                arguments.Add("--allow-external-file-lists");
            var start = StartInfo(Executable(), arguments.ToArray());
            using var process = Process.Start(start) ?? throw new BuildFailedException("SwiftPods: failed to start the configured executable");
            var output = new BoundedCapture(MaximumCommandCharacters);
            var error = new BoundedCapture(MaximumCommandCharacters);
            var outputTask = Task.Run(() => output.Read(process.StandardOutput));
            var errorTask = Task.Run(() => error.Read(process.StandardError));
            var elapsed = Stopwatch.StartNew();
            while (!process.WaitForExit(200))
            {
                if (output.Exceeded || error.Exceeded)
                {
                    Stop(process, outputTask, errorTask);
                    throw new BuildFailedException("SwiftPods: command output exceeded the 4 MiB limit");
                }
                if (elapsed.Elapsed > CommandTimeout)
                {
                    Stop(process, outputTask, errorTask);
                    throw new BuildFailedException("SwiftPods: install timed out after 30 minutes");
                }
            }
            process.WaitForExit();
            if (!Task.WaitAll(new[] { outputTask, errorTask }, TimeSpan.FromSeconds(5)))
            {
                Stop(process, outputTask, errorTask);
                throw new BuildFailedException("SwiftPods: command output did not close after process exit");
            }
            if (output.Exceeded || error.Exceeded)
                throw new BuildFailedException("SwiftPods: command output exceeded the 4 MiB limit");
            if (process.ExitCode != 0) throw new BuildFailedException("SwiftPods: " + error.Text.Trim());
            Debug.Log("SwiftPods: " + output.Text.Trim());
        }

        static void Stop(Process process, params Task[] readers)
        {
            var sessionId = process.Id;
            try
            {
                SignalSession(sessionId, SignalTerminate);
                if (!WaitForSessionExit(process, sessionId, TerminationGracePeriod))
                {
                    var elapsed = Stopwatch.StartNew();
                    do
                    {
                        SignalSession(sessionId, SignalKill);
                        if (WaitForSessionExit(process, sessionId, TimeSpan.FromMilliseconds(100))) break;
                    }
                    while (elapsed.Elapsed < ForcedTerminationPeriod);
                }

                if (SessionProcessIds(sessionId).Length != 0)
                    throw new InvalidOperationException("processes remained in the SwiftPods session after SIGKILL");
            }
            catch (Exception exception)
            {
                // libproc should always be available in the macOS editor. These last-resort signals prevent the
                // session leader from being left behind, but do not hide an inability to enumerate its descendants.
                try { kill(-sessionId, SignalKill); } catch (Exception) { }
                try { if (!process.HasExited) process.Kill(); } catch (InvalidOperationException) { }
                throw new BuildFailedException("SwiftPods: failed to terminate the install process session: " + exception.Message);
            }

            try { process.WaitForExit(5000); } catch (InvalidOperationException) { }
            try
            {
                if (!Task.WaitAll(readers, TimeSpan.FromSeconds(5)))
                    throw new BuildFailedException("SwiftPods: install process streams remained open after its session was terminated");
            }
            catch (AggregateException exception)
            {
                throw new BuildFailedException("SwiftPods: failed to finish reading install process output: " + exception.GetBaseException().Message);
            }
        }

        static bool WaitForSessionExit(Process process, int sessionId, TimeSpan timeout)
        {
            var elapsed = Stopwatch.StartNew();
            do
            {
                try { process.WaitForExit(0); } catch (InvalidOperationException) { }
                if (SessionProcessIds(sessionId).Length == 0) return true;
                Thread.Sleep(50);
            }
            while (elapsed.Elapsed < timeout);
            return SessionProcessIds(sessionId).Length == 0;
        }

        static void SignalSession(int sessionId, int signal)
        {
            Exception failure = null;
            foreach (var processId in SessionProcessIds(sessionId).OrderBy(processId => processId == sessionId ? 0 : 1))
            {
                if (kill(processId, signal) == 0 || Marshal.GetLastWin32Error() == NoSuchProcess) continue;
                if (failure == null)
                    failure = new InvalidOperationException($"kill({processId}, {signal}) failed with errno {Marshal.GetLastWin32Error()}");
            }
            if (failure != null) throw failure;
        }

        static int[] SessionProcessIds(int sessionId)
        {
            var capacity = 1024;
            while (capacity <= 262144)
            {
                var processIds = new int[capacity];
                var count = proc_listallpids(processIds, processIds.Length * sizeof(int));
                if (count < 0)
                    throw new InvalidOperationException("proc_listallpids failed with errno " + Marshal.GetLastWin32Error());
                if (count < processIds.Length)
                    return processIds.Take(count).Where(processId => processId > 0 && getsid(processId) == sessionId).ToArray();
                capacity *= 2;
            }
            throw new InvalidOperationException("the process table exceeded the supported size");
        }

        sealed class BoundedCapture
        {
            readonly int maximum;
            readonly StringBuilder contents = new StringBuilder();
            int exceeded;

            public BoundedCapture(int maximum) => this.maximum = maximum;
            public bool Exceeded => Volatile.Read(ref exceeded) != 0;
            public string Text { get { lock (contents) return contents.ToString(); } }

            public void Read(StreamReader reader)
            {
                var buffer = new char[4096];
                int count;
                while ((count = reader.Read(buffer, 0, buffer.Length)) > 0)
                {
                    lock (contents)
                    {
                        var available = Math.Max(0, maximum - contents.Length);
                        if (available > 0) contents.Append(buffer, 0, Math.Min(available, count));
                        if (count > available) Volatile.Write(ref exceeded, 1);
                    }
                }
            }
        }

        static ProcessStartInfo StartInfo(string executable, params string[] arguments)
        {
            // The constant Python launcher does not use a shell. It creates a fresh session before exec, so cleanup
            // can reach SwiftPods and tools that deliberately create their own process groups.
            var launcherArguments = new[] { "-I", "-c", SessionLauncher, executable }.Concat(arguments).ToArray();
            var start = new ProcessStartInfo("/usr/bin/python3")
            {
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
            };
            foreach (var name in start.EnvironmentVariables.Keys.Cast<string>().Where(name =>
                name.StartsWith("DYLD_", StringComparison.Ordinal) || name.StartsWith("LD_", StringComparison.Ordinal)
                || name.StartsWith("PYTHON", StringComparison.Ordinal) || name == "BASH_ENV" || name == "ENV"
                || name == "CDPATH" || name == "GIT_CONFIG_PARAMETERS").ToArray())
                start.EnvironmentVariables.Remove(name);
            start.EnvironmentVariables["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin";
            // Unity 2021 can run against profiles both with and without ArgumentList. Prefer real argv where the
            // runtime provides it; the fallback implements ProcessStartInfo's documented quote/backslash grammar.
            var property = typeof(ProcessStartInfo).GetProperty("ArgumentList");
            if (property?.GetValue(start) is IList list)
            {
                foreach (var argument in launcherArguments) list.Add(argument);
            }
            else
            {
                start.Arguments = string.Join(" ", launcherArguments.Select(QuoteArgument));
            }
            return start;
        }

        static string QuoteArgument(string argument)
        {
            var result = new StringBuilder("\"");
            var backslashes = 0;
            foreach (var character in argument)
            {
                if (character == '\\')
                {
                    backslashes++;
                }
                else if (character == '"')
                {
                    result.Append('\\', backslashes * 2 + 1).Append('"');
                    backslashes = 0;
                }
                else
                {
                    result.Append('\\', backslashes).Append(character);
                    backslashes = 0;
                }
            }
            result.Append('\\', backslashes * 2).Append('"');
            return result.ToString();
        }

        /// <summary>An explicit absolute <c>SWIFTPODS</c> path is the user's executable trust decision.</summary>
        static string Executable()
        {
            var configured = Environment.GetEnvironmentVariable("SWIFTPODS");
            if (string.IsNullOrWhiteSpace(configured))
                throw new BuildFailedException("SwiftPods: set SWIFTPODS to the absolute path of the trusted swiftpods executable");
            if (!Path.IsPathRooted(configured))
                throw new BuildFailedException("SwiftPods: SWIFTPODS must be an absolute path");
            var executable = Path.GetFullPath(configured);
            if (!File.Exists(executable))
                throw new BuildFailedException("SwiftPods: the SWIFTPODS executable does not exist: " + executable);
            return executable;
        }
    }
}
