// Copyright © 2022 Brian Drelling. All rights reserved.

import Foundation
import PackagePlugin

@main
struct FormatPlugin {
    // MARK: Constants

    private static let commandName = "swiftformat"

    // MARK: Properties

    private let fileManager: FileManager = .default

    /// A list of files to exclude by default across all projects.
    ///
    /// These are passed manually as arguments because exclusion rules in files passed via the `--config` option are not respected.
    private let excludedFiles: [String] = [
        // Swift Package Manager
        ".build",
        ".swiftpm",
        "**/Package.swift",
        // CoreData
        "**/*+CoreDataProperties.swift",
        // Vapor Public directory
        "Public",
        // Example files (eg. for use as blog snippets)
        "**/*.example.swift",
        // Autogenerated files (eg. Sourcery, SwiftGen, Apollo, etc.)
        "**/*.autogenerated.swift",
    ]

    // MARK: Methods

    private func perform(
        swiftformat: PluginContext.Tool,
        fileProvider: PluginContext.Tool,
        defaultSwiftVersion: String,
        package: Package,
        arguments: [String]
    ) throws {
        var extractor = ArgumentExtractor(arguments)

        let swiftVersion = extractor.option(named: "swiftversion", defaultValue: defaultSwiftVersion)

        // Detect the intended configuration file to use.
        // The order of precedence is as follows:
        //   1. Any file argument passed in should be respected first and foremost.
        //   1. Any file template name argument passed in should be respected second.
        //   3. Any detected file within the working directory where this is executed.
        //   4. The first templated configuration file with a given name.
        //   5. The default templated configuration file.
        let configurationFilePath: String = try {
            if let option = extractor.option(named: "config") {
                return option
            }

            if let templateName = extractor.option(named: "config-template") {
                return try self.templatedConfigurationFilePath(named: templateName, using: fileProvider)
            }

            let defaultConfigurationFilePath = "\(package.directory)/.swiftformat"

            if self.fileManager.fileExists(atPath: defaultConfigurationFilePath) {
                return defaultConfigurationFilePath
            } else {
                // Return the default template file.
                return try self.templatedConfigurationFilePath(named: nil, using: fileProvider)
            }
        }()

        let isDebugging = extractor.flag(named: "debug")
        let shouldFormatStagedFilesOnly = extractor.flag(named: "staged-only")

        let targets = extractor.options(named: "target")

        let fileToFormat: [String] = try {
            let targets = extractor.options(named: "target")

            guard targets.isEmpty else {
                return targets
            }

            if shouldFormatStagedFilesOnly {
                return try self.stagedFilePaths()
            }

            return ["."]
        }()

        let executablePath = swiftformat.path.string

        if isDebugging {
            print("------------------------------------------------------------")
            print("DEBUG INFO")
            print("------------------------------------------------------------")
            print("=> Executable Path:       \(executablePath)")
            print("=> Swift Version:         \(swiftVersion)")
            print("=> Configuration File:    \(configurationFilePath)")
            print("=> Debugging?:            \(isDebugging)")
            print("=> Staged Files Only?:    \(shouldFormatStagedFilesOnly)")
            print("=> Targets:               \(targets)")

            // Adjust printing of file paths for prettier output depending on count.
            if fileToFormat.count > 1 {
                print("=> Formatted File Paths:")

                for file in fileToFormat {
                    print("     - \(file)")
                }
            } else if let firstFile = fileToFormat.first {
                print("=> Formatted File Paths:  \(firstFile)")
            } else {
                print("=> Formatted File Paths:  ?")
            }

            print("=> Arguments:           \(arguments)")
            print("------------------------------------------------------------")
        }

        guard self.fileManager.fileExists(atPath: configurationFilePath) else {
            throw PluginError.configurationFileNotFound
        }

        // Each set of arguments is an array, which is flattened into a single String array before passing into the Process.
        let arguments = [
            // First, include all files that should be formatted.
            fileToFormat,
            ["--swiftversion", swiftVersion],
            ["--config", configurationFilePath],
            // SwiftFormat caches outside of the package directory, which is inaccessible to this package, so we cannot cache results.
            // TODO: Investigate alternative directory or system of caching, or open SwiftFormat issue to address?
            ["--cache", "ignore"],
            ["--exclude", self.excludedFiles.joined(separator: ",")],
            extractor.remainingArguments,
        ].flatMap { $0 }

        if isDebugging {
            let command = "$ swift run \(Self.commandName) \(arguments.joined(separator: " "))"

            print("=> SwiftFormat Command:")
            print(command)
            print("------------------------------------------------------------")
        }

        try self.runSwiftFormat(
            executablePath: executablePath,
            arguments: arguments
        )

        // If we formatted staged files, we need to add them back to the commit.
        if shouldFormatStagedFilesOnly {
            try self.addFilesToCommit(files: fileToFormat)
        }
    }

    private func runSwiftFormat(executablePath: String, arguments: [String]) throws {
        try ConfiguredProcess(
            executablePath: executablePath,
            arguments: arguments
        ).run()
    }

    private func templatedConfigurationFilePath(
        named name: String?,
        using fileProvider: PluginContext.Tool
    ) throws -> String {
        // Create the arguments array with the first argument -- the name of the tool to fetch a configuration file for.
        var arguments = [Self.commandName]

        // If name is included, add it to the arguments array.
        // Otherwise, leave it empty and let the executable handle it.
        if let name = name {
            arguments.append(name)
        }

        let process = ConfiguredProcess(
            executablePath: fileProvider.path.string,
            arguments: arguments
        )

        let output = try process.run()
        let regexPattern = "[A-Z_]*="

        let filePath = output
            .replacingOccurrences(of: regexPattern, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return filePath
    }

    private func stagedFilePaths() throws -> [String] {
        let command = "git diff --diff-filter=d --staged --name-only"
        let output = try ConfiguredProcess.bash(command: command).run()

        return output
            // Split on newline.
            .split(separator: "\n")
            // Filter out non-Swift files.
            .filter { $0.hasSuffix(".swift") }
            // Map from String.Subsequence back to String.
            .map(String.init)
    }

    private func addFilesToCommit(files: [String]) throws {
        let commands = files.map { "git add \($0)" }
        let combinedCommand = commands.joined(separator: " && ")

        try ConfiguredProcess.bash(command: combinedCommand).run()
    }

    private func filePaths(forTargets targets: [String], in package: Package) throws -> [String] {
        // If there are no targets, don't do anything else
        guard !targets.isEmpty else {
            return []
        }

        return try package.targets(named: targets).map(\.directory.string)
    }
}

// MARK: - Supporting Types

enum PluginError: Error {
    case configurationFileNotFound
}

// MARK: - Extensions

extension ArgumentExtractor {
    mutating func option(named argument: String) -> String? {
        extractOption(named: argument).first
    }

    mutating func option(named argument: String, defaultValue: String) -> String {
        self.option(named: argument) ?? defaultValue
    }

    mutating func options(named argument: String) -> [String] {
        let options = extractOption(named: argument)

        // To support passing as a comma-delimited list or unique options, check to see if there is a single value, and if so, split by comma.

        // If there is NOT a single value returned, pass the options array back as-is -- empty or not.
        guard options.count == 1 else {
            return options
        }

        // Unwrap the first option -- it should definitely be there if we reach this point in the code.
        guard let firstOption = options.first else {
            return []
        }

        // Since there is a single value, split the string by comma delimiter and return.
        // This allows us to support passing as either of the following:
        //     --target first --target second
        //     --target first,second
        return firstOption.split(separator: ",").map(String.init)
    }

    mutating func option(named argument: String, defaultValues: [String]) -> [String] {
        let options = self.options(named: argument)

        // If options are empty, return the defaultValues array instead.
        return !options.isEmpty ? options : defaultValues
    }

    mutating func flag(named argument: String) -> Bool {
        // The Int value represents the number of occurrences of the flag.
        // Since we won't ever have a use for passing a flag multiple times, we'll just evaluate as a Bool.
        extractFlag(named: argument) > 0
    }
}

extension FormatPlugin: CommandPlugin {
    func performCommand(context: PackagePlugin.PluginContext, arguments: [String]) async throws {
        let toolsVersion = context.package.toolsVersion
        let swiftVersion = "\(toolsVersion.major).\(toolsVersion.minor).\(toolsVersion.patch)"

        try self.perform(
            swiftformat: try context.tool(named: Self.commandName),
            fileProvider: try context.tool(named: "kipple-file-provider"),
            defaultSwiftVersion: swiftVersion,
            package: context.package,
            arguments: arguments
        )
    }
}
