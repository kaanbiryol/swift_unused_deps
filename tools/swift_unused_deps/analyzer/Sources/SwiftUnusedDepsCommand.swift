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

    @Option(help: "Minimum confidence level to report: low, medium, high.")
    var minConfidence: String = "low"

    @Option(help: "Comma-separated extra module names to treat as system modules.")
    var extraSystemModules: String?

    @Option(help: "Root containing .swift_deps_info.json files.")
    var metadataRoot: String

    @Option(help: "Path to the Swift index store.")
    var indexStorePath: String?

    @Option(help: "Bazel target pattern to filter analysis results.")
    var filter: String?

    @Option(help: "Workspace directory used for source paths and label conversion.")
    var workspaceDirectory: String?

    @Option(help: "Write a structured JSON fix plan for high-confidence issues.")
    var fixPlanOutput: String?

    @Option(help: "Write the rendered report to this file instead of stdout.")
    var reportOutput: String?

    @Option(help: "Write the analyzer exit code to this file and exit 0.")
    var exitCodeOutput: String?

    public init() {}

    public func validate() throws {
        if metadataRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ValidationError("--metadata-root cannot be empty.")
        }
        if let workspaceDirectory,
           workspaceDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ValidationError("--workspace-directory cannot be empty.")
        }
    }

    public func run() throws {
        guard let confidence = Confidence(rawValue: minConfidence) else {
            throw ValidationError("Invalid confidence level '\(minConfidence)'. Use: low, medium, high")
        }

        let workspace = resolvedWorkspaceDirectory()
        let labelConverter = LabelConverter.loadFromBazel(workspaceDirectory: workspace?.path) ?? .identity

        let output = BatchAnalyzer.analyze(options: .init(
            bazelBin: metadataRoot,
            indexStorePath: indexStorePath,
            extraSystemModules: SwiftUnusedDepsCommand.parseExtraSystemModules(extraSystemModules),
            filter: filter,
            labelConverter: labelConverter,
            workspaceDirectory: workspace
        ))

        for warning in output.warnings {
            printErr("WARNING: \(warning)")
        }

        if output.results.isEmpty && output.warnings.isEmpty {
            printErr("ERROR: No metadata files found under \(metadataRoot).")
            throw ExitCode(2)
        }

        if let fixPlanOutput {
            let plan = FixPlan.from(results: output.results)
            try SwiftUnusedDepsCommand.write(FixPlan.formatJSON(plan), to: fixPlanOutput)
        }

        let rendered = json
            ? Report.formatJSON(results: output.results, minConfidence: confidence)
            : Report.formatText(results: output.results, minConfidence: confidence)

        let exitCode = Self.exitCode(
            output: output,
            minConfidence: confidence
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
        abstract: "Apply a swift_unused_deps fix plan to the workspace."
    )

    @Option(help: "Workspace directory where source and BUILD edits should be applied.")
    var workspaceDirectory: String?

    @Argument(help: "One or more fix_plan.json files.")
    var fixPlanPaths: [String] = []

    public init() {}

    public func validate() throws {
        if fixPlanPaths.isEmpty {
            throw ValidationError("apply requires at least one fix plan path.")
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
