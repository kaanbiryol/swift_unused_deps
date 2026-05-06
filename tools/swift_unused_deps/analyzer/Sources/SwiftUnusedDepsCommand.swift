import ArgumentParser
import Foundation

struct BazelInfoProvider {
    private let lookupImpl: (String, URL, [String]) -> String?

    init(_ lookup: @escaping (String, URL) -> String?) {
        self.lookupImpl = { key, currentDirectory, _ in
            lookup(key, currentDirectory)
        }
    }

    init(_ lookup: @escaping (String, URL, [String]) -> String?) {
        self.lookupImpl = lookup
    }

    func lookup(_ key: String, currentDirectory: URL, options: [String] = []) -> String? {
        lookupImpl(key, currentDirectory, options)
    }

    static let process = BazelInfoProvider { key, currentDirectory, options in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["bazel", "info"] + options + [key]
        process.currentDirectoryURL = currentDirectory

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let value = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

public struct SwiftUnusedDepsAnalyzeCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "analyze",
        abstract: "Analyze already-produced swift_unused_deps metadata and Swift index-store artifacts."
    )

    @Flag(help: "Output JSON.")
    var json = false

    @Argument(help: "Bazel target pattern to analyze.")
    var targetPattern: String?

    @Option(name: .customLong("fix-output"), help: "Write a structured JSON fix file.")
    var fixOutput: String?

    @Option(
        name: .customLong("min-report-confidence"),
        help: "Minimum confidence level to report and use for the analyze exit code: low, medium, high. Default: low."
    )
    var minReportConfidence: String?

    @Option(
        name: .customLong("min-fix-confidence"),
        help: "Minimum confidence level to include in fix output: low, medium, high. Default: high."
    )
    var minFixConfidence: String?

    @Option(name: .customLong("min-confidence"), help: .hidden)
    var legacyMinConfidence: String?

    @Option(name: .customLong("fix-plan-min-confidence"), help: .hidden)
    var legacyFixPlanMinConfidence: String?

    @Option(name: .customLong("fix-plan-output"), help: .hidden)
    var legacyFixPlanOutput: String?

    @Option(help: .hidden)
    var extraSystemModules: String?

    @Option(help: .hidden)
    var metadataRoot: String?

    @Option(help: .hidden)
    var indexStorePath: String?

    @Option(help: .hidden)
    var filter: String?

    @Option(help: .hidden)
    var workspaceDirectory: String?

    @Option(help: .hidden)
    var reportOutput: String?

    @Option(help: .hidden)
    var exitCodeOutput: String?

    public init() {}

    public func validate() throws {
        try Self.validateNonEmpty(metadataRoot, option: "--metadata-root")
        try Self.validateNonEmpty(targetPattern, option: "TARGET_PATTERN")
        try Self.validateNonEmpty(filter, option: "--filter")
        try Self.validateNonEmpty(workspaceDirectory, option: "--workspace-directory")
        try Self.validateNonEmpty(fixOutput, option: "--fix-output")
        try Self.validateNonEmpty(legacyFixPlanOutput, option: "--fix-plan-output")
        if let targetPattern, let filter, targetPattern != filter {
            throw ValidationError("Provide either TARGET_PATTERN or --filter, not both.")
        }
        if let fixOutput, let legacyFixPlanOutput, fixOutput != legacyFixPlanOutput {
            throw ValidationError("Provide either --fix-output or --fix-plan-output, not both.")
        }
        if let minReportConfidence, let legacyMinConfidence, minReportConfidence != legacyMinConfidence {
            throw ValidationError("Provide either --min-report-confidence or --min-confidence, not both.")
        }
        if let minFixConfidence, let legacyFixPlanMinConfidence, minFixConfidence != legacyFixPlanMinConfidence {
            throw ValidationError("Provide either --min-fix-confidence or --fix-plan-min-confidence, not both.")
        }
    }

    public func run() throws {
        let reportConfidence = try Self.confidence(
            minReportConfidence ?? legacyMinConfidence ?? "low",
            option: "--min-report-confidence"
        )
        let fixConfidence = try Self.confidence(
            minFixConfidence ?? legacyFixPlanMinConfidence ?? "high",
            option: "--min-fix-confidence"
        )

        let workspace = resolvedWorkspaceDirectory()
        let resolvedMetadataRoot = try self.resolvedMetadataRoot(workspace: workspace)
        let resolvedFilter = targetPattern ?? filter
        let resolvedFixOutput = fixOutput ?? legacyFixPlanOutput
        let labelConverter = LabelConverter.loadFromBazel(workspaceDirectory: workspace?.path) ?? .identity

        let output = BatchAnalyzer.analyze(options: .init(
            bazelBin: resolvedMetadataRoot,
            indexStorePath: indexStorePath,
            extraSystemModules: SwiftUnusedDepsCommand.parseExtraSystemModules(extraSystemModules),
            filter: resolvedFilter,
            labelConverter: labelConverter,
            workspaceDirectory: workspace
        ))

        for warning in output.warnings {
            printErr("WARNING: \(warning)")
        }

        if output.results.isEmpty && output.warnings.isEmpty {
            printErr("ERROR: No metadata files found under \(resolvedMetadataRoot).")
            throw ExitCode(2)
        }

        if let resolvedFixOutput {
            let plan = FixPlan.from(results: output.results, minConfidence: fixConfidence)
            try SwiftUnusedDepsCommand.write(FixPlan.formatJSON(plan), to: resolvedFixOutput)
        }

        let rendered = json
            ? Report.formatJSON(results: output.results, minConfidence: reportConfidence)
            : Report.formatText(
                results: output.results,
                minConfidence: reportConfidence,
                includesFixPlanHint: resolvedFixOutput == nil
            )

        let exitCode = Self.exitCode(
            output: output,
            minConfidence: reportConfidence
        )

        if let reportOutput {
            try SwiftUnusedDepsCommand.write(rendered, to: reportOutput)
        } else {
            print(rendered)
        }

        if let exitCodeOutput {
            try SwiftUnusedDepsCommand.write("\(exitCode)\n", to: exitCodeOutput)
            return
        }

        if exitCode != 0 {
            throw ExitCode(exitCode)
        }
    }

    private func resolvedWorkspaceDirectory() -> URL? {
        if let workspaceDirectory {
            return URL(fileURLWithPath: workspaceDirectory, isDirectory: true)
        }
        return SwiftUnusedDepsCommand.workspaceDirectory()
    }

    private func resolvedMetadataRoot(workspace: URL?) throws -> String {
        if let metadataRoot {
            return metadataRoot
        }

        let currentDirectory = bazelInfoCurrentDirectory(workspace: workspace)
        if let bazelBin = BazelInfoProvider.process.lookup("bazel-bin", currentDirectory: currentDirectory) {
            return bazelBin
        }

        throw ValidationError("Could not infer metadata root with 'bazel info bazel-bin'. Pass --metadata-root <path>.")
    }

    private func bazelInfoCurrentDirectory(workspace: URL?) -> URL {
        if let workingDirectory = ProcessInfo.processInfo.environment["BUILD_WORKING_DIRECTORY"] {
            return URL(fileURLWithPath: workingDirectory, isDirectory: true)
        }
        if let workspace {
            return workspace
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    }

    private static func confidence(_ rawValue: String, option: String) throws -> Confidence {
        guard let confidence = Confidence(rawValue: rawValue) else {
            throw ValidationError("Invalid confidence level '\(rawValue)' for \(option). Use: low, medium, high")
        }
        return confidence
    }

    private static func validateNonEmpty(_ value: String?, option: String) throws {
        if let value, value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ValidationError("\(option) cannot be empty.")
        }
    }

    private static func exitCode(
        output: BatchAnalyzer.Output,
        minConfidence: Confidence
    ) -> Int32 {
        if !output.warnings.isEmpty {
            return 2
        }
        let hasIssues = output.results.contains { result in
            result.issues.contains { $0.confidence >= minConfidence }
        }
        return hasIssues ? 1 : 0
    }

}

public struct SwiftUnusedDepsApplyCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "apply",
        abstract: "Apply swift_unused_deps fixes to the workspace."
    )

    @Option(help: "Workspace directory where source and BUILD edits should be applied.")
    var workspaceDirectory: String?

    @Argument(help: "One or more fix JSON files.")
    var fixPlanPaths: [String] = []

    public init() {}

    public func validate() throws {
        if fixPlanPaths.isEmpty {
            throw ValidationError("apply requires at least one fix file path.")
        }
        if let workspaceDirectory,
           workspaceDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ValidationError("--workspace-directory cannot be empty.")
        }
    }

    public func run() throws {
        let plans = try fixPlanPaths.map {
            try FixPlan.read(from: URL(fileURLWithPath: $0))
        }
        let plan = FixPlan.merge(plans)
        let workspace = resolvedWorkspaceDirectory()

        printErr("Applying \(plan.buildEdits.count) BUILD fix(es) and \(plan.sourceImportRemovals.count) source import removal(s)...")
        let result = try FixPlanApplier.apply(plan, workspaceDirectory: workspace)
        if result.applied {
            printErr("Done: \(result.buildFixCount) BUILD fix(es) and \(result.sourceImportRemovalCount) source import removal(s) applied.")
        }
    }

    private func resolvedWorkspaceDirectory() -> URL? {
        if let workspaceDirectory {
            return URL(fileURLWithPath: workspaceDirectory, isDirectory: true)
        }
        return SwiftUnusedDepsCommand.workspaceDirectory()
    }
}

public struct SwiftUnusedDepsCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "swift_unused_deps",
        abstract: "Detect unused and missing direct Bazel deps for Swift targets.",
        subcommands: [
            SwiftUnusedDepsAnalyzeCommand.self,
            SwiftUnusedDepsApplyCommand.self,
        ]
    )

    public init() {}

    static func parseExtraSystemModules(_ rawValue: String?) -> Set<String> {
        guard let rawValue else { return [] }
        return Set(rawValue.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty })
    }

    static func write(_ contents: String, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    static func workspaceDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bazelInfo: BazelInfoProvider = .process
    ) -> URL? {
        if let workingDirectory = environment["BUILD_WORKING_DIRECTORY"],
           let workspace = bazelInfo.lookup(
               "workspace",
               currentDirectory: URL(fileURLWithPath: workingDirectory, isDirectory: true)
           ) {
            return URL(fileURLWithPath: workspace, isDirectory: true)
        }
        if let workspace = environment["BUILD_WORKSPACE_DIRECTORY"] {
            return URL(fileURLWithPath: workspace, isDirectory: true)
        }
        return nil
    }
}
