import Foundation

/// Keep filesystem text separate from the build variables expanded by Xcode and the shell.
struct NativeConsumerPath {
    let variable: String
    let relative: String
    var setting: String { "$(" + variable + ")/" + NativeBuildSetting.literal(relative) }
    var shell: String { "\"${" + variable + "}/\"" + NativeShellString.quote(relative) }
}

struct NativeConsumerCopy {
    let source: NativeConsumerPath
    let destination: String
}

extension NativeXcode {
    func consumerPath(_ url: URL) -> NativeConsumerPath {
        NativeConsumerPath(
            variable: "PODS_ROOT",
            relative: NativePath.relativePath(of: url, to: project.appendingPathComponent("Pods")))
    }

    func consumerProductPath(_ product: String) -> NativeConsumerPath {
        if let path = productBuildPaths[product] {
            return NativeConsumerPath(variable: "PODS_CONFIGURATION_BUILD_DIR", relative: path)
        }
        return NativeConsumerPath(
            variable: "BUILT_PRODUCTS_DIR", relative: graph.objects[product]?["path"] as? String ?? "")
    }

    func consumerSDKPath(_ sdk: NativeVendorSDK) -> NativeConsumerPath {
        guard sdk.isXCFramework else { return consumerPath(sdk.url) }
        let variant = activeVariants.keys.sorted().compactMap { root -> NativePodVariant? in
            guard let key = activeVariants[root], (vendorSDKs[key] ?? []).contains(where: { $0.url == sdk.url }) else {
                return nil
            }
            return variantPlan?.variants[key]
        }.first
        let directory = variant.map { $0.scoped ? $0.label + "/" : "" } ?? ""
        return NativeConsumerPath(variable: "PODS_CONFIGURATION_BUILD_DIR", relative: directory + sdk.productName)
    }

    func consumerSDKHeaders(_ sdk: NativeVendorSDK) -> String? {
        guard sdk.isXCFramework, !sdk.isFramework, sdk.slices.contains(where: { $0.headers != nil }) else { return nil }
        let path = consumerSDKPath(sdk)
        let directory = (path.relative as NSString).deletingLastPathComponent
        return NativeConsumerPath(
            variable: path.variable, relative: (directory.isEmpty ? "" : directory + "/") + "include"
        ).setting
    }

    /// File lists provide dependency ordering and sandbox access without per-SDK PBX objects.
    func consumerCopyPhase(
        _ copies: [String: [NativeConsumerCopy]], kind: String, label: String, target: String, user: NativePBX
    ) throws {
        // Generated bundles and loose resources share the final copy namespace.
        // Validate the complete plan before changing phases or support files.
        let locale = Locale(identifier: "en_US_POSIX")
        for configuration in copies.keys.sorted() {
            var destinations: [String: (source: String, destination: String)] = [:]
            for transfer in copies[configuration] ?? [] {
                let key = transfer.destination.folding(options: .caseInsensitive, locale: locale)
                if let previous = destinations[key],
                    previous.source != transfer.source.setting || previous.destination != transfer.destination
                {
                    throw Diagnostic(
                        kind == "frameworks" ? "SP-DUPLICATE-SDK" : "SP-XCODE-RESOURCE", stage: "integrate",
                        "Multiple dependencies copy to the same destination in " + configuration,
                        file: transfer.destination)
                }
                destinations[key] = (transfer.source.setting, transfer.destination)
            }
        }
        let key = "swiftpods:" + (kind == "frameworks" ? "embedphase" : "resources") + ":" + target
        let id = NativePBX.identifier(key)
        var phases = user.objects[target]?["buildPhases"] as? [String] ?? []
        phases.removeAll { $0 == id }
        user.objects.removeValue(forKey: id)
        guard copies.values.contains(where: { !$0.isEmpty }) else {
            user.objects[target]?["buildPhases"] = phases
            return
        }
        let support = project.appendingPathComponent("Pods/Target Support Files/" + label)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let script = support.appendingPathComponent(label + "-" + kind + ".sh")
        let destination = kind == "frameworks" ? "FRAMEWORKS_FOLDER_PATH" : "UNLOCALIZED_RESOURCES_FOLDER_PATH"
        let stamp = "$(DERIVED_FILE_DIR)/swiftpods-" + target + "-" + kind + ".stamp"
        var commands = [Self.consumerCopyScript, "case \"${CONFIGURATION}\" in"]
        var allInputs: Set<String> = [consumerPath(script).setting]
        var allOutputs: Set<String> = [stamp]
        var fileLists = true
        for configuration in copies.keys.sorted() {
            let transfers = copies[configuration] ?? []
            let inputs = Set(transfers.map { $0.source.setting }).union([consumerPath(script).setting]).sorted()
            let outputs = Set(
                transfers.map {
                    "$(TARGET_BUILD_DIR)/$(" + destination + ")/" + NativeBuildSetting.literal($0.destination)
                }
            ).union([stamp]).sorted()
            allInputs.formUnion(inputs)
            allOutputs.formUnion(outputs)
            for (name, paths) in [("input", inputs), ("output", outputs)] {
                if paths.contains(where: { $0.contains("\n") || $0.contains("\r") }) {
                    fileLists = false
                    continue
                }
                try Data((paths.joined(separator: "\n") + "\n").utf8).writeIfChanged(
                    to: support.appendingPathComponent(
                        label + "-" + kind + "-" + configuration + "-" + name + "-files.xcfilelist"))
            }
            commands.append(NativeShellString.quote(configuration) + ")")
            for transfer in transfers {
                commands.append(
                    "  install_" + kind + " " + transfer.source.shell + " "
                        + NativeShellString.quote(transfer.destination))
            }
            commands.append("  ;;")
        }
        commands += [
            "*) echo \"Unsupported SwiftPods build configuration: ${CONFIGURATION}\" >&2; exit 1 ;;", "esac",
            "mkdir -p \"${DERIVED_FILE_DIR}\"",
            "touch \"${DERIVED_FILE_DIR}/swiftpods-" + target + "-" + kind + ".stamp\"",
        ]
        try Data((commands.joined(separator: "\n") + "\n").utf8).writeIfChanged(to: script)
        var phase: [String: Any] = [
            "isa": "PBXShellScriptBuildPhase",
            "name": "[SwiftPods] " + (kind == "frameworks" ? "Embed Frameworks" : "Copy Resources"),
            "buildActionMask": "2147483647", "runOnlyForDeploymentPostprocessing": "0", "files": [],
            "shellPath": "/bin/sh", "shellScript": "/bin/sh " + consumerPath(script).shell + "\n",
            // Directory timestamps do not track changes to nested binaries or
            // resources. Check each snapshot while retaining lists for ordering
            // and sandbox access; rsync only transfers changed content.
            "alwaysOutOfDate": "1",
        ]
        if fileLists {
            let prefix = consumerPath(support).setting + "/" + label + "-" + kind + "-$(CONFIGURATION)-"
            phase["inputFileListPaths"] = [prefix + "input-files.xcfilelist"]
            phase["outputFileListPaths"] = [prefix + "output-files.xcfilelist"]
        } else {
            // Newlines cannot be represented in a line-oriented file list.
            phase["inputPaths"] = allInputs.sorted()
            phase["outputPaths"] = allOutputs.sorted()
        }
        let added = user.add(key, phase)
        insertConsumerCopyPhase(added, into: &phases, user: user)
        user.objects[target]?["buildPhases"] = phases
    }

    private static let consumerCopyScript = #"""
        #!/bin/sh
        set -eu
        install_resources() {
          source=$1
          destination="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/$2"
          mkdir -p "$(dirname "${destination}")"
          if [ -d "${source}" ]; then
            mkdir -p "${destination}"
            /usr/bin/rsync -a --checksum --delete "${source}/" "${destination}/"
          else
            /bin/cp -p "${source}" "${destination}"
          fi
        }
        install_frameworks() {
          source=$1
          destination="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}/$2"
          mkdir -p "$(dirname "${destination}")"
          if [ -d "${source}" ]; then
            mkdir -p "${destination}"
            /usr/bin/rsync -a --checksum --delete --exclude Headers --exclude PrivateHeaders --exclude Modules "${source}/" "${destination}/"
            binary="${destination}/$(basename "$2" .framework)"
          else
            /bin/cp -p "${source}" "${destination}"
            binary="${destination}"
          fi
          if [ -n "${ARCHS:-}" ] && [ -f "${binary}" ]; then
            # lipo replaces its output; follow binary links to retain versioned framework layouts.
            while [ -L "${binary}" ]; do
              link=$(/usr/bin/readlink "${binary}")
              case "${link}" in
                /*) binary="${link}" ;;
                *) binary="$(dirname "${binary}")/${link}" ;;
              esac
            done
            /bin/chmod u+w "${binary}"
            architectures=$(/usr/bin/lipo -archs "${binary}")
            for architecture in ${architectures}; do
              case " ${ARCHS} " in
                *" ${architecture} "*) ;;
                *) /usr/bin/lipo -remove "${architecture}" "${binary}" -output "${binary}" ;;
              esac
            done
          fi
          if [ "${CODE_SIGNING_ALLOWED:-NO}" != NO ] && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
            /usr/bin/codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY}" --preserve-metadata=identifier,entitlements "${destination}"
          fi
        }
        """#
}
