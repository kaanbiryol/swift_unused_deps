import ArgumentParser
import Foundation

public struct SwiftUnusedDepsCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "swift_unused_deps",
        abstract: "Detect unused and missing direct Bazel deps for Swift targets."
    )

    @Option(help: "Path to a single target metadata JSON file.")
    var metadataFile: String?

    @Option(help: "Path to a single target trace JSON file.")
    var traceFile: String?

    @Option(help: "Path to write the single-target analysis report.")
    var output: String?

    @Option(help: "Path to bazel-bin. Auto-discovers aspect outputs and trace files.")
    var bazelBin: String?

    @Option(help: "Directory containing aspect metadata JSON files and traces.")
    var metadataDir: String?

    @Flag(help: "Output JSON.")
    var json = false

    @Option(help: "Minimum confidence level to report: low, medium, high.")
    var minConfidence: String = "low"

    @Flag(help: "Run buildozer to fix high-confidence issues.")
    var fix = false

    @Option(help: "Comma-separated extra module names to treat as system modules.")
    var extraSystemModules: String?

    @Option(help: "Path to Swift index store for unused import detection (batch mode only).")
    var indexStorePath: String?

    @Argument(help: "Optional target filter when running in batch mode.")
    var filter: String?

    public init() {}

    public func validate() throws {
        if metadataFile == nil && traceFile != nil {
            throw ValidationError("--trace-file requires --metadata-file.")
        }
        if metadataFile == nil && output != nil {
            throw ValidationError("--output requires --metadata-file.")
        }
        if bazelBin != nil && metadataDir != nil {
            throw ValidationError("Cannot combine --bazel-bin with --metadata-dir.")
        }
        if fix && json {
            throw ValidationError("--fix cannot be combined with --json.")
        }
        if isSingleTargetMode && fix {
            throw ValidationError("--fix is only supported in batch mode.")
        }
        if isSingleTargetMode && filter != nil {
            throw ValidationError("Target filter is only supported in batch mode.")
        }
        if metadataFile != nil && hasExplicitBatchInput {
            throw ValidationError("Cannot combine --metadata-file with --bazel-bin or --metadata-dir.")
        }
        if metadataFile != nil && traceFile == nil {
            throw ValidationError("--trace-file is required with --metadata-file.")
        }
        if metadataFile != nil && output == nil {
            throw ValidationError("--output is required with --metadata-file.")
        }
    }

    public func run() throws {
        guard let confidence = Confidence(rawValue: minConfidence) else {
            throw ValidationError("Invalid confidence level '\(minConfidence)'. Use: low, medium, high")
        }

        let extraSystem = parseExtraSystemModules(extraSystemModules)

        if isSingleTargetMode {
            try runSingleTarget(confidence: confidence, extraSystem: extraSystem)
        } else {
            try runBatch(confidence: confidence, extraSystem: extraSystem)
        }
    }

    private var isSingleTargetMode: Bool {
        metadataFile != nil || traceFile != nil || output != nil
    }

    private var hasExplicitBatchInput: Bool {
        bazelBin != nil || metadataDir != nil
    }

    private func runSingleTarget(confidence: Confidence, extraSystem: Set<String>) throws {
        guard let metadataFile, let traceFile, let output else {
            throw ValidationError("Single-target analysis requires --metadata-file, --trace-file, and --output.")
        }

        let metaURL = URL(fileURLWithPath: metadataFile)
        let traceURL = URL(fileURLWithPath: traceFile)

        let data = try Data(contentsOf: metaURL)
        let metadata = try JSONDecoder().decode(TargetMetadata.self, from: data)
        let loadedModules = try TraceParser.parseTraceFile(
            at: traceURL,
            forModule: metadata.target.moduleName
        )

        let result = analyzeTarget(
            metadata: metadata,
            loadedModules: loadedModules,
            extraSystem: extraSystem
        )

        let content = render(results: [result], minConfidence: confidence)
        try content.write(toFile: output, atomically: true, encoding: .utf8)
    }

    private func runBatch(confidence: Confidence, extraSystem: Set<String>) throws {
        let metadataRoot = bazelBin ?? metadataDir ?? Self.resolveDefaultMetadataRoot()
        guard !metadataRoot.isEmpty else {
            printErr("ERROR: Could not determine metadata root.")
            throw ExitCode(2)
        }

        let output = BatchAnalyzer.analyze(options: .init(
            bazelBin: metadataRoot,
            indexStorePath: resolvedIndexStorePath(),
            extraSystemModules: extraSystem,
            filter: filter
        ))

        for warning in output.warnings {
            printErr("WARNING: \(warning)")
        }

        if output.results.isEmpty && output.warnings.isEmpty {
            printErr("ERROR: No metadata files found.")
            printErr("Hint: run 'bazel build <targets> --config=unused-deps' first.")
            throw ExitCode(2)
        }

        if output.results.isEmpty {
            printErr("No targets found. Run 'bazel build <targets> --config=unused-deps' first.")
            throw ExitCode(2)
        }

        print(render(results: output.results, minConfidence: confidence))

        if fix && !json {
            try runFixes(results: output.results)
        }

        let hasIssues = output.results.contains { result in
            result.issues.contains { $0.confidence >= confidence }
        }
        if hasIssues {
            throw ExitCode(1)
        }
        if !output.warnings.isEmpty {
            throw ExitCode(2)
        }
    }

    private func analyzeTarget(
        metadata: TargetMetadata,
        loadedModules: [LoadedModule],
        extraSystem: Set<String>
    ) -> AnalysisResult {
        let resolver = ModuleResolver(
            transitiveModuleMap: metadata.transitiveModuleMap,
            extraSystemModules: extraSystem
        )
        return Analyzer.analyze(
            metadata: metadata,
            loadedModules: loadedModules,
            resolver: resolver
        )
    }

    private func render(results: [AnalysisResult], minConfidence: Confidence) -> String {
        if json {
            return Report.formatJSON(results: results, minConfidence: minConfidence)
        }
        return Report.formatText(results: results, minConfidence: minConfidence)
    }

    private func runFixes(results: [AnalysisResult]) throws {
        let commands = results
            .flatMap(\.issues)
            .filter { $0.confidence >= .high }
            .compactMap(\.buildozerCommand)

        guard !commands.isEmpty else {
            printErr("No high-confidence fixes to apply.")
            return
        }

        printErr("")
        printErr("Applying \(commands.count) fix(es)...")
        printErr("")

        let result = Buildozer.runBatch(
            commands: commands,
            workingDirectory: Self.workspaceDirectory()
        )
        if result.success {
            printErr("Done: \(commands.count) fix(es) applied.")
        } else {
            printErr("FAILED: \(result.output)")
            throw ExitCode(1)
        }
    }

    private func parseExtraSystemModules(_ rawValue: String?) -> Set<String> {
        guard let rawValue else { return [] }
        return Set(rawValue.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty })
    }

    private func resolvedIndexStorePath() -> String? {
        if let indexStorePath {
            return indexStorePath
        }

        let defaultIndexStorePath = "/tmp/swift_unused_deps_index_store"
        if FileManager.default.fileExists(atPath: defaultIndexStorePath) {
            return defaultIndexStorePath
        }
        return nil
    }

    private static func resolveDefaultMetadataRoot() -> String {
        let workspace = ProcessInfo.processInfo.environment["BUILD_WORKSPACE_DIRECTORY"]
            ?? FileManager.default.currentDirectoryPath
        let bazelBin = URL(fileURLWithPath: workspace).appendingPathComponent("bazel-bin").path
        return (try? FileManager.default.destinationOfSymbolicLink(atPath: bazelBin)) ?? bazelBin
    }

    private static func workspaceDirectory() -> URL? {
        ProcessInfo.processInfo.environment["BUILD_WORKSPACE_DIRECTORY"]
            .map { URL(fileURLWithPath: $0) }
    }
}
