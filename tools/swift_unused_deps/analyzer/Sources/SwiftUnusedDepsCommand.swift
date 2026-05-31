import ArgumentParser
import Foundation

struct BazelInfoProvider {
    private let lookupImpl: (String, URL) -> String?

    init(_ lookup: @escaping (String, URL) -> String?) {
        self.lookupImpl = lookup
    }

    func lookup(_ key: String, currentDirectory: URL) -> String? {
        lookupImpl(key, currentDirectory)
    }

    static let process = BazelInfoProvider { key, currentDirectory in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["bazel", "info", key]
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

struct SwiftUnusedDepsAnalyzeTargetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "analyze-target",
        abstract: "Analyze one target metadata artifact for Bazel actions.",
        shouldDisplay: false
    )

    @Option(help: .hidden)
    var metadataFile: String?

    @Option(name: .customLong("dependency-metadata-file"), help: .hidden)
    var dependencyMetadataFiles: [String] = []

    @Option(help: .hidden)
    var bazelBin: String = "."

    @Option(help: .hidden)
    var indexStorePath: String?

    @Option(name: .customLong("dependency-index-store-path"), help: .hidden)
    var dependencyIndexStorePaths: [String] = []

    @Option(help: .hidden)
    var extraSystemModules: String?

    @Option(help: .hidden)
    var reportOutput: String?

    @Option(help: .hidden)
    var fixOutput: String?

    @Option(help: .hidden)
    var fixLowOutput: String?

    init() {}

    func validate() throws {
        try SwiftUnusedDepsCommand.validateNonEmpty(metadataFile, option: "--metadata-file")
        try dependencyMetadataFiles.forEach {
            try SwiftUnusedDepsCommand.validateNonEmpty($0, option: "--dependency-metadata-file")
        }
        try SwiftUnusedDepsCommand.validateNonEmpty(bazelBin, option: "--bazel-bin")
        try SwiftUnusedDepsCommand.validateNonEmpty(indexStorePath, option: "--index-store-path")
        try SwiftUnusedDepsCommand.validateNonEmpty(reportOutput, option: "--report-output")
        try SwiftUnusedDepsCommand.validateNonEmpty(fixOutput, option: "--fix-output")
        try SwiftUnusedDepsCommand.validateNonEmpty(fixLowOutput, option: "--fix-low-output")
    }

    func run() throws {
        guard let metadataFile, let reportOutput, let fixOutput, let fixLowOutput else {
            throw ValidationError("analyze-target requires --metadata-file, --report-output, --fix-output, and --fix-low-output.")
        }
        let primaryMetadataFile = URL(fileURLWithPath: metadataFile)
        var metadataWarnings: [String] = []
        let includedLabels = MetadataArtifactDiscovery
            .loadMetadata(from: primaryMetadataFile, warnings: &metadataWarnings)
            .map { Set([$0.target.label]) }
        if includedLabels == nil {
            let output = BatchAnalyzer.Output(results: [], warnings: metadataWarnings)
            SwiftUnusedDepsCommand.printWarnings(output)
            try SwiftUnusedDepsCommand.write(
                Report.formatJSON(results: output.results, minConfidence: .low),
                to: reportOutput
            )
            try SwiftUnusedDepsCommand.write(
                FixPlan.formatJSON(FixPlan(sourceImportRemovals: [], buildEdits: [])),
                to: fixOutput
            )
            try SwiftUnusedDepsCommand.write(
                FixPlan.formatJSON(FixPlan(sourceImportRemovals: [], buildEdits: [])),
                to: fixLowOutput
            )
            return
        }

        let output = BatchAnalyzer.analyze(
            metadataFiles: [primaryMetadataFile] + dependencyMetadataFiles.map {
                URL(fileURLWithPath: $0)
            },
            options: .init(
                bazelBin: bazelBin,
                indexStorePath: indexStorePath,
                dependencyIndexStorePaths: dependencyIndexStorePaths,
                extraSystemModules: SwiftUnusedDepsCommand.parseExtraSystemModules(extraSystemModules),
                includedLabels: includedLabels,
                labelConverter: .identity,
                workspaceDirectory: nil
            )
        )

        SwiftUnusedDepsCommand.printWarnings(output)
        try SwiftUnusedDepsCommand.write(
            Report.formatJSON(results: output.results, minConfidence: .low),
            to: reportOutput
        )
        try SwiftUnusedDepsCommand.write(
            FixPlan.formatJSON(FixPlan.from(results: output.results, minConfidence: .high)),
            to: fixOutput
        )
        try SwiftUnusedDepsCommand.write(
            FixPlan.formatJSON(FixPlan.from(results: output.results, minConfidence: .low)),
            to: fixLowOutput
        )
    }
}

struct SwiftUnusedDepsMergeReportsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "merge-reports",
        abstract: "Merge declared swift_unused_deps report and fix artifacts.",
        shouldDisplay: false
    )

    @Option(name: .customLong("report-input"), help: .hidden)
    var reportInputs: [String] = []

    @Option(name: .customLong("fix-input"), help: .hidden)
    var fixInputs: [String] = []

    @Option(name: .customLong("min-report-confidence"), help: .hidden)
    var minReportConfidence = "low"

    @Option(name: .customLong("report-output"), help: .hidden)
    var reportOutput: String?

    @Option(name: .customLong("text-output"), help: .hidden)
    var textOutput: String?

    @Option(name: .customLong("fix-output"), help: .hidden)
    var fixOutput: String?

    @Option(name: .customLong("exit-code-output"), help: .hidden)
    var exitCodeOutput: String?

    init() {}

    func validate() throws {
        try SwiftUnusedDepsCommand.validateNonEmpty(minReportConfidence, option: "--min-report-confidence")
        try SwiftUnusedDepsCommand.validateNonEmpty(reportOutput, option: "--report-output")
        try SwiftUnusedDepsCommand.validateNonEmpty(textOutput, option: "--text-output")
        try SwiftUnusedDepsCommand.validateNonEmpty(fixOutput, option: "--fix-output")
        try SwiftUnusedDepsCommand.validateNonEmpty(exitCodeOutput, option: "--exit-code-output")
        try reportInputs.forEach {
            try SwiftUnusedDepsCommand.validateNonEmpty($0, option: "--report-input")
        }
        try fixInputs.forEach {
            try SwiftUnusedDepsCommand.validateNonEmpty($0, option: "--fix-input")
        }
    }

    func run() throws {
        let reportConfidence = try SwiftUnusedDepsCommand.confidence(
            minReportConfidence,
            option: "--min-report-confidence"
        )
        let report = try Report.mergeJSONReports(reportInputs.map {
            try Report.readJSONReport(from: URL(fileURLWithPath: $0))
        })
        let fixPlan = try FixPlan.merge(fixInputs.map {
            try FixPlan.read(from: URL(fileURLWithPath: $0))
        })

        let jsonReport = Report.formatJSON(report: report)
        let textReport = Report.formatText(
            report: report,
            minConfidence: reportConfidence,
            includesFixPlanHint: false
        )
        let exitCode = SwiftUnusedDepsCommand.analysisExitCode(
            report: report,
            minConfidence: reportConfidence
        )

        if let reportOutput {
            try SwiftUnusedDepsCommand.write(jsonReport, to: reportOutput)
        }
        if let textOutput {
            try SwiftUnusedDepsCommand.write(textReport, to: textOutput)
        }
        if let fixOutput {
            try SwiftUnusedDepsCommand.write(FixPlan.formatJSON(fixPlan), to: fixOutput)
        }
        if let exitCodeOutput {
            try SwiftUnusedDepsCommand.write("\(exitCode)\n", to: exitCodeOutput)
        }

        if reportOutput == nil && textOutput == nil {
            print(textReport)
        }
    }
}

public struct SwiftUnusedDepsCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "swift_unused_deps",
        abstract: "Detect unused and missing direct Bazel deps for Swift targets.",
        subcommands: [
            SwiftUnusedDepsApplyCommand.self,
            SwiftUnusedDepsAnalyzeTargetCommand.self,
            SwiftUnusedDepsMergeReportsCommand.self,
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

    static func printWarnings(_ output: BatchAnalyzer.Output) {
        for warning in output.warnings {
            printErr("WARNING: \(warning)")
        }
    }

    static func confidence(_ rawValue: String, option: String) throws -> Confidence {
        guard let confidence = Confidence(rawValue: rawValue) else {
            throw ValidationError("Invalid confidence level '\(rawValue)' for \(option). Use: low, high")
        }
        return confidence
    }

    static func validateNonEmpty(_ value: String?, option: String) throws {
        if let value, value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ValidationError("\(option) cannot be empty.")
        }
    }

    static func analysisExitCode(
        report: Report.JSONReport,
        minConfidence: Confidence
    ) -> Int32 {
        let hasIssues = report.results.contains { result in
            result.issues.contains { issue in
                guard let confidence = Confidence(rawValue: issue.confidence) else {
                    return false
                }
                return confidence >= minConfidence
            }
        }
        return hasIssues ? 1 : 0
    }

}
