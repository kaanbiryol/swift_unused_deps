import ArgumentParser
import Foundation
import SwiftUnusedDepsLib

@main
struct SwiftUnusedDeps: ParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "swift_unused_deps",
        abstract: "Detect unused and missing direct Bazel deps for Swift targets."
    )

    @Option(help: "Path to a single target metadata JSON file.")
    var metadataFile: String?

    @Option(help: "Path to a single target trace JSON file.")
    var traceFile: String?

    @Option(help: "Path to write the analysis report.")
    var output: String?

    @Option(help: "Path to bazel-bin. Auto-discovers aspect outputs and trace files.")
    var bazelBin: String?

    @Option(help: "Directory containing aspect metadata JSON files.")
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

    func validate() throws {
        let hasSingleMode = metadataFile != nil || traceFile != nil || output != nil
        let hasBatchMode = bazelBin != nil || metadataDir != nil

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
        if fix && metadataFile != nil {
            throw ValidationError("--fix is only supported in batch mode.")
        }
        if !hasSingleMode && !hasBatchMode {
            throw ValidationError(
                "Provide --metadata-file + --trace-file (single target) "
                + "or --bazel-bin / --metadata-dir (batch)."
            )
        }
        if metadataFile != nil && hasBatchMode {
            throw ValidationError("Cannot combine --metadata-file with --bazel-bin or --metadata-dir.")
        }
        if metadataFile != nil && traceFile == nil {
            throw ValidationError("--trace-file is required with --metadata-file.")
        }
        if metadataFile != nil && output == nil {
            throw ValidationError("--output is required with --metadata-file.")
        }
    }

    func run() throws {
        guard let confidence = Confidence(rawValue: minConfidence) else {
            throw ValidationError("Invalid confidence level '\(minConfidence)'. Use: low, medium, high")
        }

        let extraSystem: Set<String>
        if let extra = extraSystemModules {
            extraSystem = Set(extra.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        } else {
            extraSystem = []
        }

        if metadataFile != nil {
            try runSingleTarget(confidence: confidence, extraSystem: extraSystem)
        } else {
            try runBatch(confidence: confidence, extraSystem: extraSystem)
        }
    }

    private func runSingleTarget(confidence: Confidence, extraSystem: Set<String>) throws {
        let metaURL = URL(fileURLWithPath: metadataFile!)
        let traceURL = URL(fileURLWithPath: traceFile!)

        let data = try Data(contentsOf: metaURL)
        let metadata = try JSONDecoder().decode(TargetMetadata.self, from: data)

        let loadedModules = try TraceParser.parseTraceFile(
            at: traceURL,
            forModule: metadata.target.moduleName
        )

        let resolver = ModuleResolver(
            transitiveModuleMap: metadata.transitiveModuleMap,
            extraSystemModules: extraSystem
        )

        let result = Analyzer.analyze(
            metadata: metadata,
            loadedModules: loadedModules,
            resolver: resolver
        )

        let content: String
        if json {
            content = Report.formatJSON(results: [result], minConfidence: confidence)
        } else {
            content = Report.formatText(results: [result], minConfidence: confidence)
        }

        try content.write(toFile: output!, atomically: true, encoding: .utf8)

    }

    private func runBatch(confidence: Confidence, extraSystem: Set<String>) throws {
        guard let bb = bazelBin ?? metadataDir else {
            printErr("ERROR: No metadata source provided.")
            throw ExitCode(2)
        }

        let options = BatchAnalyzer.Options(
            bazelBin: bb,
            indexStorePath: indexStorePath,
            extraSystemModules: extraSystem
        )
        let output = BatchAnalyzer.analyze(options: options)

        for warning in output.warnings {
            printErr("WARNING: \(warning)")
        }

        let results = output.results
        if results.isEmpty && output.warnings.isEmpty {
            printErr("ERROR: No metadata files found.")
            printErr("Hint: run 'bazel build <targets> --config=unused-deps' first.")
            throw ExitCode(2)
        }

        if json {
            print(Report.formatJSON(results: results, minConfidence: confidence))
        } else {
            print(Report.formatText(results: results, minConfidence: confidence))
        }

        if fix && !json {
            try runFixes(results: results)
        }

        let hasIssues = results.contains { result in
            result.issues.contains { $0.confidence >= confidence }
        }
        if hasIssues {
            throw ExitCode(1)
        }
        if !output.warnings.isEmpty {
            throw ExitCode(2)
        }
    }

    private func runFixes(results: [AnalysisResult]) throws {
        var commands: [BuildozerCommand] = []
        for result in results {
            for issue in result.issues {
                guard issue.confidence >= .high, let cmd = issue.buildozerCommand else { continue }
                commands.append(cmd)
            }
        }
        guard !commands.isEmpty else {
            printErr("No high-confidence fixes to apply.")
            return
        }

        printErr("")
        printErr("Applying \(commands.count) fix(es)...")
        printErr("")
        let result = Buildozer.runBatch(commands: commands)
        if result.success {
            printErr("Done: \(commands.count) fix(es) applied.")
        } else {
            printErr("FAILED: \(result.output)")
            throw ExitCode(1)
        }
    }

}
