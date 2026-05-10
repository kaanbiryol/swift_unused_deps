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

struct BazelQueryProvider {
    private let depsImpl: (String, URL) -> Set<String>?

    init(_ deps: @escaping (String, URL) -> Set<String>?) {
        self.depsImpl = deps
    }

    func deps(of targetPattern: String, currentDirectory: URL) -> Set<String>? {
        depsImpl(targetPattern, currentDirectory)
    }

    static let process = BazelQueryProvider { targetPattern, currentDirectory in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "bazel",
            "query",
            "deps(\(targetPattern))",
            "--output=label",
        ]
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
        guard let output = String(data: data, encoding: .utf8) else { return nil }
        let labels = output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return Set(labels)
    }
}

struct AnalysisInvocation {
    let targetPattern: String?
    let filter: String?
    let workspaceDirectory: String?
    let metadataRoot: String?
    let indexStorePath: String?
    let extraSystemModules: String?
}

struct AnalysisRun {
    let output: BatchAnalyzer.Output
    let workspaceDirectory: URL?
    let metadataRoot: String
}

public struct SwiftUnusedDepsAnalyzeCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "analyze",
        abstract: "Analyze already-produced swift_unused_deps metadata and Swift index-store artifacts."
    )

    @Flag(help: .hidden)
    var json = false

    @Argument(help: "Bazel target pattern to analyze.")
    var targetPattern: String?

    @Option(name: .customLong("fix-output"), help: "Write a structured JSON fix file.")
    var fixOutput: String?

    @Flag(
        name: .customLong("include-low-confidence-fixes"),
        help: "Include low-confidence fixes in --fix-output."
    )
    var includeLowConfidenceFixes = false

    @Option(
        name: .customLong("min-report-confidence"),
        help: .hidden
    )
    var minReportConfidence: String?

    @Option(
        name: .customLong("min-fix-confidence"),
        help: .hidden
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

    @Option(
        name: .customLong("report-output"),
        help: "Write a JSON analysis report to a file while still printing the text report."
    )
    var reportOutput: String?

    @Option(help: .hidden)
    var exitCodeOutput: String?

    public init() {}

    public func validate() throws {
        try SwiftUnusedDepsCommand.validateNonEmpty(metadataRoot, option: "--metadata-root")
        try SwiftUnusedDepsCommand.validateNonEmpty(targetPattern, option: "TARGET_PATTERN")
        try SwiftUnusedDepsCommand.validateNonEmpty(filter, option: "--filter")
        try SwiftUnusedDepsCommand.validateNonEmpty(workspaceDirectory, option: "--workspace-directory")
        try SwiftUnusedDepsCommand.validateNonEmpty(fixOutput, option: "--fix-output")
        try SwiftUnusedDepsCommand.validateNonEmpty(legacyFixPlanOutput, option: "--fix-plan-output")
        try SwiftUnusedDepsCommand.validateNonEmpty(reportOutput, option: "--report-output")
        try SwiftUnusedDepsCommand.validateNonEmpty(exitCodeOutput, option: "--exit-code-output")
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
        try SwiftUnusedDepsCommand.validateLowConfidenceFixOptions(
            includeLowConfidenceFixes: includeLowConfidenceFixes,
            minFixConfidence: minFixConfidence,
            legacyFixPlanMinConfidence: legacyFixPlanMinConfidence
        )
    }

    public func run() throws {
        let reportConfidence = try SwiftUnusedDepsCommand.confidence(
            minReportConfidence ?? legacyMinConfidence ?? "low",
            option: "--min-report-confidence"
        )
        let fixConfidence = try SwiftUnusedDepsCommand.fixConfidence(
            includeLowConfidenceFixes: includeLowConfidenceFixes,
            minFixConfidence: minFixConfidence,
            legacyFixPlanMinConfidence: legacyFixPlanMinConfidence
        )
        let resolvedFixOutput = fixOutput ?? legacyFixPlanOutput

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
        if let resolvedFixOutput {
            let plan = FixPlan.from(results: run.output.results, minConfidence: fixConfidence)
            try SwiftUnusedDepsCommand.write(FixPlan.formatJSON(plan), to: resolvedFixOutput)
        }
        if let reportOutput {
            try SwiftUnusedDepsCommand.write(jsonReport, to: reportOutput)
        }

        let rendered = json
            ? jsonReport
            : Report.formatText(
                results: run.output.results,
                minConfidence: reportConfidence,
                includesFixPlanHint: resolvedFixOutput == nil
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

public struct SwiftUnusedDepsFixCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "fix",
        abstract: "Analyze and apply swift_unused_deps fixes to the workspace."
    )

    @Argument(help: "Bazel target pattern to analyze and fix.")
    var targetPattern: String?

    @Option(name: .customLong("fix-output"), help: "Write the structured JSON fix file before applying it.")
    var fixOutput: String?

    @Flag(
        name: .customLong("include-low-confidence-fixes"),
        help: "Include low-confidence fixes when applying changes."
    )
    var includeLowConfidenceFixes = false

    @Option(
        name: .customLong("report-output"),
        help: "Write a JSON analysis report to a file before applying fixes."
    )
    var reportOutput: String?

    @Option(name: .customLong("min-report-confidence"), help: .hidden)
    var minReportConfidence: String?

    @Option(name: .customLong("min-fix-confidence"), help: .hidden)
    var minFixConfidence: String?

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

    public init() {}

    public func validate() throws {
        try SwiftUnusedDepsCommand.validateNonEmpty(targetPattern, option: "TARGET_PATTERN")
        try SwiftUnusedDepsCommand.validateNonEmpty(filter, option: "--filter")
        try SwiftUnusedDepsCommand.validateNonEmpty(workspaceDirectory, option: "--workspace-directory")
        try SwiftUnusedDepsCommand.validateNonEmpty(fixOutput, option: "--fix-output")
        try SwiftUnusedDepsCommand.validateNonEmpty(legacyFixPlanOutput, option: "--fix-plan-output")
        try SwiftUnusedDepsCommand.validateNonEmpty(reportOutput, option: "--report-output")
        if let targetPattern, let filter, targetPattern != filter {
            throw ValidationError("Provide either TARGET_PATTERN or --filter, not both.")
        }
        if let fixOutput, let legacyFixPlanOutput, fixOutput != legacyFixPlanOutput {
            throw ValidationError("Provide either --fix-output or --fix-plan-output, not both.")
        }
        if let minFixConfidence, let legacyFixPlanMinConfidence, minFixConfidence != legacyFixPlanMinConfidence {
            throw ValidationError("Provide either --min-fix-confidence or --fix-plan-min-confidence, not both.")
        }
        try SwiftUnusedDepsCommand.validateLowConfidenceFixOptions(
            includeLowConfidenceFixes: includeLowConfidenceFixes,
            minFixConfidence: minFixConfidence,
            legacyFixPlanMinConfidence: legacyFixPlanMinConfidence
        )
    }

    public func run() throws {
        let reportConfidence = try SwiftUnusedDepsCommand.confidence(
            minReportConfidence ?? "low",
            option: "--min-report-confidence"
        )
        let fixConfidence = try SwiftUnusedDepsCommand.fixConfidence(
            includeLowConfidenceFixes: includeLowConfidenceFixes,
            minFixConfidence: minFixConfidence,
            legacyFixPlanMinConfidence: legacyFixPlanMinConfidence
        )
        let resolvedFixOutput = fixOutput ?? legacyFixPlanOutput

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
        if let resolvedFixOutput {
            try SwiftUnusedDepsCommand.write(FixPlan.formatJSON(plan), to: resolvedFixOutput)
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

public struct SwiftUnusedDepsCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "swift_unused_deps",
        abstract: "Detect unused and missing direct Bazel deps for Swift targets.",
        subcommands: [
            SwiftUnusedDepsAnalyzeCommand.self,
            SwiftUnusedDepsFixCommand.self,
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

    static func runAnalysis(_ invocation: AnalysisInvocation) throws -> AnalysisRun {
        let workspace = resolvedWorkspaceDirectory(invocation.workspaceDirectory)
        let metadataRoot = try resolvedMetadataRoot(invocation.metadataRoot, workspace: workspace)
        let filter = invocation.targetPattern ?? invocation.filter
        let labelConverter = LabelConverter.loadFromBazel(workspaceDirectory: workspace?.path) ?? .identity
        let includedLabels = topLevelDependencyLabels(
            for: filter,
            workspace: workspace,
            labelConverter: labelConverter
        )

        let output = BatchAnalyzer.analyze(options: .init(
            bazelBin: metadataRoot,
            indexStorePath: invocation.indexStorePath,
            extraSystemModules: parseExtraSystemModules(invocation.extraSystemModules),
            filter: filter,
            includedLabels: includedLabels,
            labelConverter: labelConverter,
            workspaceDirectory: workspace
        ))

        return AnalysisRun(
            output: output,
            workspaceDirectory: workspace,
            metadataRoot: metadataRoot
        )
    }

    private static func topLevelDependencyLabels(
        for targetPattern: String?,
        workspace: URL?,
        labelConverter: LabelConverter,
        bazelQuery: BazelQueryProvider = .process
    ) -> Set<String>? {
        guard let targetPattern, let workspace else { return nil }
        let trimmedPattern = targetPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPattern.isEmpty else { return nil }
        guard let labels = bazelQuery.deps(of: trimmedPattern, currentDirectory: workspace) else {
            return nil
        }

        let includesExternalTargets = trimmedPattern.hasPrefix("@")
        return Set(labels.compactMap { label in
            let converted = labelConverter.convert(label)
            if !includesExternalTargets && converted.hasPrefix("@") {
                return nil
            }
            return converted
        })
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
            throw ValidationError("Invalid confidence level '\(rawValue)' for \(option). Use: low, medium, high")
        }
        return confidence
    }

    static func fixConfidence(
        includeLowConfidenceFixes: Bool,
        minFixConfidence: String?,
        legacyFixPlanMinConfidence: String?
    ) throws -> Confidence {
        let rawValue = includeLowConfidenceFixes
            ? "low"
            : minFixConfidence ?? legacyFixPlanMinConfidence ?? "high"
        return try confidence(rawValue, option: "--min-fix-confidence")
    }

    static func validateLowConfidenceFixOptions(
        includeLowConfidenceFixes: Bool,
        minFixConfidence: String?,
        legacyFixPlanMinConfidence: String?
    ) throws {
        guard includeLowConfidenceFixes else { return }
        if let minFixConfidence, minFixConfidence != Confidence.low.rawValue {
            throw ValidationError("Provide either --include-low-confidence-fixes or --min-fix-confidence, not both.")
        }
        if let legacyFixPlanMinConfidence, legacyFixPlanMinConfidence != Confidence.low.rawValue {
            throw ValidationError(
                "Provide either --include-low-confidence-fixes or --fix-plan-min-confidence, not both."
            )
        }
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

    private static func resolvedWorkspaceDirectory(_ workspaceDirectory: String?) -> URL? {
        if let workspaceDirectory {
            return URL(fileURLWithPath: workspaceDirectory, isDirectory: true)
        }
        return SwiftUnusedDepsCommand.workspaceDirectory()
    }

    private static func resolvedMetadataRoot(_ metadataRoot: String?, workspace: URL?) throws -> String {
        if let metadataRoot {
            return metadataRoot
        }

        let currentDirectory = bazelInfoCurrentDirectory(workspace: workspace)
        if let bazelBin = BazelInfoProvider.process.lookup("bazel-bin", currentDirectory: currentDirectory) {
            return bazelBin
        }

        throw ValidationError("Could not infer metadata root with 'bazel info bazel-bin'. Pass --metadata-root <path>.")
    }

    private static func bazelInfoCurrentDirectory(workspace: URL?) -> URL {
        if let workingDirectory = ProcessInfo.processInfo.environment["BUILD_WORKING_DIRECTORY"] {
            return URL(fileURLWithPath: workingDirectory, isDirectory: true)
        }
        if let workspace {
            return workspace
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    }
}
