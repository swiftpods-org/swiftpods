import Foundation
import SwiftPodsManifest

/// The two Run Script phases SwiftPods keeps in every target. What the project says about them never changes;
/// the scripts they run, and the files those scripts read and write, are generated from the Podfile.
enum TargetScripts {
    static let directoryName = "Scripts"
    /// Checksums of the Podfile and its includes when they were installed.
    static let signatureFile = "Podfile.sha256"

    enum Phase: String, CaseIterable {
        /// Before compiling: checks the installation is current, then runs `before_compile` scripts.
        case prepare = "Prepare"
        /// Last: runs `after_compile` and `any` scripts, then copies binary resource bundles into the product.
        case finish = "Finish"

        var file: String { rawValue.lowercased() }
        var position: ScriptPhase.Position { self == .prepare ? .beforeCompile : .any }
    }

    /// Paths below are relative to `$(SRCROOT)`, the directory of the Xcode project.
    struct Locations {
        /// The generated directory.
        let generated: String
        /// The directory of the Podfile.
        let podfile: String
        /// This target's scripts.
        let target: String
    }

    /// The phase's script in the project.
    static func phaseScript(_ phase: Phase, paths: Locations) -> String {
        """
        script=\(sourceRootShellPath(join(paths.target, phase.file + ".sh")))
        if [ ! -f "$script" ]; then
          echo "error: SwiftPods is not installed. Run swiftpods install next to the Podfile." >&2
          exit 1
        fi
        exec /bin/sh "$script"
        """
    }

    static func fileList(_ phase: Phase, outputs: Bool, paths: Locations) -> String {
        sourceRootFileListPath(join(paths.target, "\(phase.file).\(outputs ? "outputs" : "inputs").xcfilelist"))
    }

    /// Embeds dynamic frameworks that the target's embedded frameworks link but Xcode left out: Xcode embeds a
    /// package's dynamic frameworks only into the target that links them, so a framework such as Unity's
    /// UnityFramework links them while the app lacks them. Runs every build; frameworks it copied last time are
    /// copied again, so an SDK update or removal reaches the app. The app's executable is scanned too, so a framework
    /// it links stays when the copy from last time is removed.
    static let embedFrameworks = #"""
        frameworks="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}"
        record="${DERIVED_FILE_DIR}/SwiftPodsEmbeddedFrameworks.txt"
        if [ -f "$record" ]; then
          while IFS= read -r name; do
            case "$name" in
              ""|"."|".."|*/*|*\\*)
                echo "warning: SwiftPods: ignored unsafe framework name in $record" >&2
                continue
                ;;
            esac
            /bin/rm -rf "$frameworks/$name.framework"
          done < "$record"
        fi
        /bin/mkdir -p "${DERIVED_FILE_DIR}"
        : > "$record"
        missing=" "
        embedded=1
        while [ "$embedded" = 1 ]; do
          embedded=0
          for framework in "${TARGET_BUILD_DIR}/${EXECUTABLE_PATH}" "$frameworks"/*.framework; do
            binary="$framework"
            [ -d "$framework" ] && binary="$framework/$(/usr/bin/basename "$framework" .framework)"
            [ -f "$binary" ] || continue
            for name in $(/usr/bin/xcrun otool -L "$binary" | /usr/bin/sed -n 's|^[[:space:]]*@rpath/\([^/]*\)\.framework/.*|\1|p'); do
              [ -d "$frameworks/$name.framework" ] && continue
              source="${BUILT_PRODUCTS_DIR}/$name.framework"
              [ -d "$source" ] || source="${BUILT_PRODUCTS_DIR}/PackageFrameworks/$name.framework"
              if [ ! -d "$source" ]; then
                case "$missing" in
                  *" $name "*) ;;
                  *) echo "warning: SwiftPods: $(/usr/bin/basename "$framework") links $name.framework, which the build did not produce"; missing="$missing$name " ;;
                esac
                continue
              fi
              echo "SwiftPods: embedding $name.framework"
              /bin/mkdir -p "$frameworks"
              /usr/bin/rsync -a --exclude Headers --exclude PrivateHeaders --exclude Modules "$source" "$frameworks/"
              if [ -n "${EXPANDED_CODE_SIGN_IDENTITY}" ] && [ "${CODE_SIGNING_REQUIRED}" != NO ] && [ "${CODE_SIGNING_ALLOWED}" != NO ]; then
                /usr/bin/codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY}" ${OTHER_CODE_SIGN_FLAGS} \
                  --preserve-metadata=identifier,entitlements "$frameworks/$name.framework"
              fi
              echo "$name" >> "$record"
              embedded=1
            done
          done
        done
        """#

    /// One target's generated files, relative to its scripts directory.
    /// - Parameters:
    ///   - signed: the Podfile and its includes, relative to the Podfile's directory.
    ///   - resources: resource bundles to copy, relative to `$(SRCROOT)`.
    ///   - embedsFrameworks: whether the target embeds a framework target of the Podfile.
    ///   - fileLists: contents of the scripts' input and output file lists, by the path the Podfile gives.
    static func files(
        scripts: [ScriptPhase], resources: [String], embedsFrameworks: Bool = false, signed: [String], fileLists: [String: [String]],
        paths: Locations
    ) -> [String: String] {
        var files: [String: String] = [:]
        var numbered: [(Int, ScriptPhase)] = []
        for (index, script) in scripts.enumerated() {
            files["\(index + 1).sh"] = script.script.hasSuffix("\n") ? script.script : script.script + "\n"
            numbered.append((index + 1, script))
        }
        func run(_ scripts: [(Int, ScriptPhase)]) -> [String] {
            scripts.flatMap { index, script in
                ["echo \(shellQuoted("SwiftPods: " + script.name))"]
                    + (script.showEnvironmentInLog ? safeEnvironmentDiagnostics : [])
                    + ["\(shellQuoted(script.shellPath)) \(sourceRootShellPath(join(paths.target, "\(index).sh")))"]
            }
        }
        func declared(_ scripts: [(Int, ScriptPhase)], outputs: Bool) -> [String] {
            scripts.flatMap { _, script in
                (outputs ? script.outputFiles : script.inputFiles)
                    + (outputs ? script.outputFileLists : script.inputFileLists).flatMap { fileLists[$0] ?? [] }
            }
        }
        let header = ["#!/bin/sh", "# Generated by SwiftPods from the Podfile. Do not edit.", "set -e"]
        let before = numbered.filter { $0.1.position == .beforeCompile }
        let prepare = header + [
            "if ! (cd \(sourceRootShellPath(paths.podfile)) && /usr/bin/shasum -a 256 --check --strict --status \(sourceRootShellPath(join(paths.generated, directoryName, signatureFile)))); then",
            "  echo \"error: The Podfile changed after swiftpods install. Run swiftpods install next to the Podfile.\" >&2",
            "  exit 1",
            "fi",
        ] + run(before)
        files["prepare.sh"] = prepare.joined(separator: "\n") + "\n"
        files["prepare.inputs.xcfilelist"] = lines(
            [sourceRootFileListPath(join(paths.target, "prepare.sh")), sourceRootFileListPath(join(paths.generated, directoryName, signatureFile))]
                + signed.map {
                    $0.hasPrefix("/") ? xcodeLiteral($0) : sourceRootFileListPath(join(paths.podfile, $0))
                }
                + before.map { sourceRootFileListPath(join(paths.target, "\($0.0).sh")) }
                + declared(before, outputs: false))
        files["prepare.outputs.xcfilelist"] = lines(declared(before, outputs: true))

        let after = numbered.filter { $0.1.position != .beforeCompile }
        var finish = header + run(after)
        if !resources.isEmpty {
            finish += ["destination=\"${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}\"", "/bin/mkdir -p \"$destination\""]
            finish += resources.map { "/usr/bin/rsync -a --delete \(sourceRootShellPath($0)) \"$destination/\"" }
        }
        if embedsFrameworks { finish.append(embedFrameworks) }
        files["finish.sh"] = finish.joined(separator: "\n") + "\n"
        files["finish.inputs.xcfilelist"] = lines(
            [sourceRootFileListPath(join(paths.target, "finish.sh"))]
                + after.map { sourceRootFileListPath(join(paths.target, "\($0.0).sh")) }
                + declared(after, outputs: false) + resources.map(sourceRootFileListPath))
        files["finish.outputs.xcfilelist"] = lines(
            declared(after, outputs: true)
                + resources.map {
                    "$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/" + xcodeLiteral(($0 as NSString).lastPathComponent)
                })
        return files
    }

    /// An explicit diagnostic request prints only build metadata known not to
    /// contain credentials. Never write the complete process environment.
    private static let safeEnvironmentDiagnostics = [
        #"/usr/bin/printf '%s\n' "ACTION=${ACTION-}" "CONFIGURATION=${CONFIGURATION-}" "PLATFORM_NAME=${PLATFORM_NAME-}" "SDK_NAME=${SDK_NAME-}" "ARCHS=${ARCHS-}" | LC_ALL=C /usr/bin/tr -cd '\011\012\040-\176' | /usr/bin/sed 's/^/SwiftPods environment: /'"#
    ]

    private static func lines(_ entries: [String]) -> String {
        entries.isEmpty ? "" : entries.joined(separator: "\n") + "\n"
    }

    private static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func sourceRootShellPath(_ relative: String) -> String {
        if relative.isEmpty || relative == "." { return #""${SRCROOT}""# }
        return #""${SRCROOT}/""# + shellQuoted(relative)
    }

    private static func sourceRootFileListPath(_ relative: String) -> String {
        if relative.isEmpty || relative == "." { return "$(SRCROOT)" }
        return "$(SRCROOT)/" + xcodeLiteral(relative)
    }

    /// Only the generated suffix is literal. The build-setting prefix remains
    /// expandable, while dollar signs in file names do not become new macros.
    private static func xcodeLiteral(_ text: String) -> String {
        text.replacingOccurrences(of: "$", with: "$$")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private static func join(_ components: String...) -> String {
        components.filter { !$0.isEmpty && $0 != "." }.joined(separator: "/")
    }
}
