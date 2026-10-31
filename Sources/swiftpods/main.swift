import Foundation
import SwiftPodsKit
import SwiftPodsManifest

let version = "0.3.1"

let help = """
    SwiftPods \(version): Swift packages and binary SDKs for Xcode projects, declared in a Podfile.

    Usage: swiftpods <command> [options]

    Commands:
      install       Write the Podfile's declarations into the Xcode projects
        --deployment  Require a committed Package.resolved that satisfies the Podfile
        --resolve     Resolve packages with Xcode afterwards and check the result
        --adopt       Manage package references that were added without SwiftPods
        --offline     Use cached binary archives and catalogs only
        --update-sources  Fetch the latest catalogs first
      deintegrate   Remove everything SwiftPods added
        --cocoapods   Also remove a CocoaPods or SwiftPods 0.1 integration
      check         Read the Podfile and show what each target gets
        --offline     Use cached catalogs only
      search TEXT   Find packages in a catalog (the public one, or --source URL)
      catalog lint [DIR]  Check a catalog repository (default: current directory)
      version       Print the version

    Options:
      --project-directory DIR   Directory with the Podfile (default: current directory)
      --project PATH            Xcode project of targets that do not name one (default: the only one next to the Podfile)
      --json                    Machine-readable output

    Reference: https://swiftpods.org/docs/podfile/
    """

struct Usage: Error, CustomStringConvertible {
    let description: String
}

func output(_ value: some Encodable) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    print(String(decoding: try encoder.encode(value), as: UTF8.self))
}

func printReport(_ report: InstallReport) {
    for note in report.notes { print("note: " + note) }
    for project in report.projects {
        if project.changes.isEmpty {
            print("\(project.project): up to date")
        } else {
            print("\(project.project):")
            for change in project.changes { print("  \(change)") }
        }
    }
}

func describe(_ manifest: Manifest) {
    let packages = Dictionary(manifest.packages.map { ($0.identity, $0) }, uniquingKeysWith: { first, _ in first })
    for target in manifest.targets {
        print("\(target.name)" + (target.project.map { " (\($0))" } ?? "") + (target.platform.map { " \($0.name.rawValue) \($0.deploymentTarget ?? "")" } ?? ""))
        for product in target.products {
            let package = packages[product.package]!
            let source: String
            switch package.location {
            case .remote(let url): source = "\(url) \(package.requirement!)"
            case .local(let path): source = path
            }
            print("  \(product.product)\(product.link ? "" : " (not linked)") from \(source)")
        }
        for binary in target.binaries { print("  \(binary) (binary)") }
        for setting in target.settings {
            print("  \(setting.key) = \(setting.value)" + (setting.configurations.map { " [\($0.joined(separator: ", "))]" } ?? ""))
        }
        for script in target.scriptPhases { print("  script phase '\(script.name)' (\(script.position.rawValue))") }
    }
}

func run(_ arguments: [String]) throws {
    var arguments = arguments
    var directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    var json = false
    var flags = Set<String>()
    var command: String?
    var operands: [String] = []
    var source: String?
    var project: URL?
    while !arguments.isEmpty {
        let argument = arguments.removeFirst()
        switch argument {
        case "--project-directory":
            guard !arguments.isEmpty else { throw Usage(description: "--project-directory needs a path") }
            directory = URL(fileURLWithPath: arguments.removeFirst())
        case "--project":
            guard !arguments.isEmpty else { throw Usage(description: "--project needs a path") }
            project = URL(fileURLWithPath: arguments.removeFirst())
        case "--json": json = true
        case "--source":
            guard !arguments.isEmpty else { throw Usage(description: "--source needs a catalog URL") }
            source = arguments.removeFirst()
        case "-h", "--help", "help": command = command ?? "help"
        case "--version": command = command ?? "version"
        default:
            if argument.hasPrefix("-") {
                flags.insert(argument)
            } else if command == nil {
                command = argument
            } else {
                operands.append(argument)
            }
        }
    }
    let allowed: [String: Set<String>] = [
        "install": ["--deployment", "--resolve", "--adopt", "--offline", "--update-sources"], "deintegrate": ["--cocoapods"],
        "check": ["--update-sources", "--offline"], "search": ["--update-sources"], "catalog": [], "version": [], "help": [],
    ]
    let operandCounts: [String: ClosedRange<Int>] = ["search": 1...1, "catalog": 1...2]
    guard let command = command ?? (flags.isEmpty ? "help" : nil), let options = allowed[command] else {
        throw Usage(description: "Unknown command '\(command ?? "")'. Run `swiftpods help`.")
    }
    if let unknown = flags.subtracting(options).sorted().first {
        throw Usage(description: "`\(command)` has no option \(unknown)")
    }
    guard (operandCounts[command] ?? 0...0).contains(operands.count) else {
        throw Usage(description: "Unexpected arguments for `\(command)`. Run `swiftpods help`.")
    }
    if source != nil && command != "search" { throw Usage(description: "--source applies to `search`") }
    if project != nil && !["install", "deintegrate"].contains(command) {
        throw Usage(description: "--project applies to `install` and `deintegrate`")
    }
    let installer = Installer(directory: directory, project: project)
    switch command {
    case "install":
        var options = InstallOptions()
        options.deployment = flags.contains("--deployment")
        options.resolve = flags.contains("--resolve")
        options.adopt = flags.contains("--adopt")
        options.offline = flags.contains("--offline")
        options.updateSources = flags.contains("--update-sources")
        let report = try installer.install(options)
        if json { try output(report) } else { printReport(report) }
    case "deintegrate":
        let report = try installer.deintegrate(cocoapods: flags.contains("--cocoapods"))
        if json { try output(report) } else { printReport(report) }
    case "check":
        let manifest = try installer.manifest(updateSources: flags.contains("--update-sources"), offline: flags.contains("--offline"))
        if json { try output(manifest) } else { describe(manifest) }
    case "search":
        let entries = try CatalogTools.search(
            operands[0], sources: [Source(url: source ?? Source.publicCatalog)], update: flags.contains("--update-sources"))
        if json {
            try output(entries.map {
                ["name": $0.name, "url": $0.url ?? "", "products": $0.products.joined(separator: " "),
                 "binary_versions": ($0.binary?.releases.map(\.version) ?? []).joined(separator: " ")]
            })
        } else if entries.isEmpty {
            print("No packages match '\(operands[0])'")
        } else {
            for entry in entries {
                var line = entry.name
                if let url = entry.url {
                    line += "  \(url)" + (entry.products.isEmpty ? "" : "  products: " + entry.products.joined(separator: ", "))
                }
                if let sdk = entry.binary { line += "  binary: " + sdk.releases.map(\.version).joined(separator: ", ") }
                print(line)
            }
        }
    case "catalog":
        guard operands[0] == "lint" else { throw Usage(description: "Unknown catalog command '\(operands[0])'") }
        let root = operands.count > 1 ? URL(fileURLWithPath: operands[1]) : directory
        let problems = CatalogTools.lint(root)
        if json { try output(["problems": problems]) } else { problems.forEach { print($0) } }
        if !problems.isEmpty { exit(1) }
        if !json { print("Catalog is valid") }
    case "version":
        if json { try output(["version": version]) } else { print(version) }
    default:
        print(help)
    }
}

do {
    try run(Array(CommandLine.arguments.dropFirst()))
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
