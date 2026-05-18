import ArgumentParser
import Foundation

struct SwiftUnusedDepsAnalyzeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "analyze",
        abstract: "Analyze already-produced swift_unused_deps metadata and Swift index-store artifacts."
    )

    @Flag(help: .hidden)
    var json = false

    @Argument(help: "Bazel target pattern to analyze.")
    var targetPattern: String?

    @Option(name: .customLong("fix-output"), help: "Write a structured JSON fix file.")
    var fixOutput: String?

    @Option(
        name: .customLong("min-report-confidence"),
        help: .hidden
    )
    var minReportConfidence: String?

    @Option(
        name: .customLong("min-fix-confidence"),
        help: "Minimum confidence level included in --fix-output. Use: low, high. Defaults to high."
    )
    var minFixConfidence: String?

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

    @Option(
        name: .customLong("report-output"),
        help: "Write a JSON analysis report to a file while still printing the text report."
    )
    var reportOutput: String?

    @Option(help: .hidden)
    var exitCodeOutput: String?

    init() {}

    func validate() throws {
        try SwiftUnusedDepsCommand.validateNonEmpty(metadataRoot, option: "--metadata-root")
        try SwiftUnusedDepsCommand.validateNonEmpty(targetPattern, option: "TARGET_PATTERN")
        try SwiftUnusedDepsCommand.validateNonEmpty(filter, option: "--filter")
        try SwiftUnusedDepsCommand.validateNonEmpty(workspaceDirectory, option: "--workspace-directory")
        try SwiftUnusedDepsCommand.validateNonEmpty(fixOutput, option: "--fix-output")
        try SwiftUnusedDepsCommand.validateNonEmpty(reportOutput, option: "--report-output")
        try SwiftUnusedDepsCommand.validateNonEmpty(exitCodeOutput, option: "--exit-code-output")
        if let targetPattern, let filter, targetPattern != filter {
            throw ValidationError("Provide either TARGET_PATTERN or --filter, not both.")
        }
    }

    func run() throws {
        let reportConfidence = try SwiftUnusedDepsCommand.confidence(
            minReportConfidence ?? "low",
            option: "--min-report-confidence"
        )
        let fixConfidence = try SwiftUnusedDepsCommand.fixConfidence(
            minFixConfidence: minFixConfidence
        )

        let run = try SwiftUnusedDepsCommand.runAnalysis(AnalysisInvocation(
            targetPattern: targetPattern,
            filter: filter,
            workspaceDirectory: workspaceDirectory,
            metadataRoot: metadataRoot,
            indexStorePath: indexStorePath,
            extraSystemModules: extraSystemModules
        ))
        SwiftUnusedDepsCommand.printWarnings(run.output)
        try SwiftUnusedDepsCommand.validateFoundMetadata(run.output, metadataRoot: run.metadataRoot)

        let jsonReport = Report.formatJSON(results: run.output.results, minConfidence: reportConfidence)
        if let fixOutput {
            let plan = FixPlan.from(results: run.output.results, minConfidence: fixConfidence)
            try SwiftUnusedDepsCommand.write(FixPlan.formatJSON(plan), to: fixOutput)
        }
        if let reportOutput {
            try SwiftUnusedDepsCommand.write(jsonReport, to: reportOutput)
        }

        let rendered = json
            ? jsonReport
            : Report.formatText(
                results: run.output.results,
                minConfidence: reportConfidence,
                includesFixPlanHint: fixOutput == nil
            )

        let exitCode = SwiftUnusedDepsCommand.analysisExitCode(
            output: run.output,
            minConfidence: reportConfidence
        )

        print(rendered)

        if let exitCodeOutput {
            try SwiftUnusedDepsCommand.write("\(exitCode)\n", to: exitCodeOutput)
            return
        }

        if exitCode != 0 {
            throw ExitCode(exitCode)
        }
    }
}

struct SwiftUnusedDepsFixCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fix",
        abstract: "Analyze and apply swift_unused_deps fixes to the workspace."
    )

    @Argument(help: "Bazel target pattern to analyze and fix.")
    var targetPattern: String?

    @Option(name: .customLong("fix-output"), help: "Write the structured JSON fix file before applying it.")
    var fixOutput: String?

    @Option(
        name: .customLong("report-output"),
        help: "Write a JSON analysis report to a file before applying fixes."
    )
    var reportOutput: String?

    @Option(name: .customLong("min-report-confidence"), help: .hidden)
    var minReportConfidence: String?

    @Option(
        name: .customLong("min-fix-confidence"),
        help: "Minimum confidence level to apply. Use: low, high. Defaults to high."
    )
    var minFixConfidence: String?

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

    init() {}

    func validate() throws {
        try SwiftUnusedDepsCommand.validateNonEmpty(targetPattern, option: "TARGET_PATTERN")
        try SwiftUnusedDepsCommand.validateNonEmpty(filter, option: "--filter")
        try SwiftUnusedDepsCommand.validateNonEmpty(workspaceDirectory, option: "--workspace-directory")
        try SwiftUnusedDepsCommand.validateNonEmpty(fixOutput, option: "--fix-output")
        try SwiftUnusedDepsCommand.validateNonEmpty(reportOutput, option: "--report-output")
        if let targetPattern, let filter, targetPattern != filter {
            throw ValidationError("Provide either TARGET_PATTERN or --filter, not both.")
        }
    }

    func run() throws {
        let reportConfidence = try SwiftUnusedDepsCommand.confidence(
            minReportConfidence ?? "low",
            option: "--min-report-confidence"
        )
        let fixConfidence = try SwiftUnusedDepsCommand.fixConfidence(
            minFixConfidence: minFixConfidence
        )

        let run = try SwiftUnusedDepsCommand.runAnalysis(AnalysisInvocation(
            targetPattern: targetPattern,
            filter: filter,
            workspaceDirectory: workspaceDirectory,
            metadataRoot: metadataRoot,
            indexStorePath: indexStorePath,
            extraSystemModules: extraSystemModules
        ))
        SwiftUnusedDepsCommand.printWarnings(run.output)
        try SwiftUnusedDepsCommand.validateFoundMetadata(run.output, metadataRoot: run.metadataRoot)

        let textReport = Report.formatText(
            results: run.output.results,
            minConfidence: reportConfidence,
            includesFixPlanHint: false
        )
        print(textReport)

        if let reportOutput {
            try SwiftUnusedDepsCommand.write(
                Report.formatJSON(results: run.output.results, minConfidence: reportConfidence),
                to: reportOutput
            )
        }

        let exitCode = SwiftUnusedDepsCommand.analysisExitCode(
            output: run.output,
            minConfidence: reportConfidence
        )
        if exitCode == 2 {
            throw ExitCode(exitCode)
        }

        let plan = FixPlan.from(results: run.output.results, minConfidence: fixConfidence)
        if let fixOutput {
            try SwiftUnusedDepsCommand.write(FixPlan.formatJSON(plan), to: fixOutput)
        }

        let result = try FixPlanApplier.apply(plan, workspaceDirectory: run.workspaceDirectory)
        if result.applied {
            printErr("Done: \(result.buildFixCount) BUILD fix(es) and \(result.sourceImportRemovalCount) source import removal(s) applied.")
        }
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
        let output = BatchAnalyzer.analyze(
            metadataFiles: [URL(fileURLWithPath: metadataFile)],
            options: .init(
                bazelBin: bazelBin,
                indexStorePath: indexStorePath,
                dependencyIndexStorePaths: dependencyIndexStorePaths,
                extraSystemModules: SwiftUnusedDepsCommand.parseExtraSystemModules(extraSystemModules),
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
            SwiftUnusedDepsAnalyzeCommand.self,
            SwiftUnusedDepsFixCommand.self,
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
        AnalysisRunner.workspaceDirectory(environment: environment, bazelInfo: bazelInfo)
    }

    static func runAnalysis(_ invocation: AnalysisInvocation) throws -> AnalysisRun {
        try AnalysisRunner.run(invocation)
    }

    static func printWarnings(_ output: BatchAnalyzer.Output) {
        for warning in output.warnings {
            printErr("WARNING: \(warning)")
        }
    }

    static func validateFoundMetadata(_ output: BatchAnalyzer.Output, metadataRoot: String) throws {
        if output.results.isEmpty && output.warnings.isEmpty {
            printErr("ERROR: No metadata files found under \(metadataRoot).")
            throw ExitCode(2)
        }
    }

    static func confidence(_ rawValue: String, option: String) throws -> Confidence {
        guard let confidence = Confidence(rawValue: rawValue) else {
            throw ValidationError("Invalid confidence level '\(rawValue)' for \(option). Use: low, high")
        }
        return confidence
    }

    static func fixConfidence(minFixConfidence: String?) throws -> Confidence {
        let rawValue = minFixConfidence ?? "high"
        return try confidence(rawValue, option: "--min-fix-confidence")
    }

    static func validateNonEmpty(_ value: String?, option: String) throws {
        if let value, value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ValidationError("\(option) cannot be empty.")
        }
    }

    static func analysisExitCode(
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
