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

    @Flag(help: "Skip the automatic 'bazel build --config=unused-deps' step.")
    var noBuild = false

    @Argument(help: "Bazel target pattern to analyze (e.g. //libraries/...).")
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
        let labelConverter = LabelConverter.loadFromBazel() ?? .identity
        var metadata = try JSONDecoder().decode(TargetMetadata.self, from: data)
        metadata = metadata.convertingLabels(with: labelConverter)
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
        // When a target pattern is provided and no explicit path is set,
        // run `bazel build --config=unused-deps` automatically.
        if let pattern = filter, !noBuild, bazelBin == nil, metadataDir == nil {
            try runBazelBuild(pattern: pattern)
        }

        let metadataRoot = bazelBin ?? metadataDir ?? Self.resolveDefaultMetadataRoot()
        guard !metadataRoot.isEmpty else {
            printErr("ERROR: Could not determine metadata root.")
            throw ExitCode(2)
        }

        let labelConverter = LabelConverter.loadFromBazel() ?? .identity

        let output = BatchAnalyzer.analyze(options: .init(
            bazelBin: metadataRoot,
            indexStorePath: resolvedIndexStorePath(),
            extraSystemModules: extraSystem,
            filter: filter,
            labelConverter: labelConverter
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
        if hasIssues && !fix {
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
        } else if result.noChanges {
            printErr("WARNING: buildozer made no changes (\(commands.count) command(s) attempted).")
            printErr("The labels in the commands may not match the label format in BUILD files.")
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

    private func runBazelBuild(pattern: String) throws {
        guard let workspace = Self.workspaceDirectory() else {
            printErr("WARNING: BUILD_WORKSPACE_DIRECTORY not set, skipping automatic build.")
            return
        }

        printErr("Building \(pattern) with --config=unused-deps ...")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["bazel", "build", pattern, "--config=unused-deps"]
        process.currentDirectoryURL = workspace
        // Inherit stderr so the user sees build progress.
        process.standardError = FileHandle.standardError
        // Suppress stdout (build info lines).
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            printErr("ERROR: bazel build failed (exit \(process.terminationStatus)).")
            throw ExitCode(2)
        }
    }

    private static func resolveDefaultMetadataRoot() -> String {
        let workspace = ProcessInfo.processInfo.environment["BUILD_WORKSPACE_DIRECTORY"]
            ?? FileManager.default.currentDirectoryPath
        let wsURL = URL(fileURLWithPath: workspace)
        let fm = FileManager.default

        // Try bazel-bin symlink first.
        let bazelBin = wsURL.appendingPathComponent("bazel-bin").path
        if let resolved = try? fm.destinationOfSymbolicLink(atPath: bazelBin),
           hasMetadataFiles(in: resolved, fileManager: fm) {
            return resolved
        }

        // bazel-bin points to a config with no metadata (common when
        // `bazel run` changes the symlink). Scan bazel-out for the config
        // that has aspect outputs from --config=unused-deps.
        let bazelOut = wsURL.appendingPathComponent("bazel-out").path
        let outPath = (try? fm.destinationOfSymbolicLink(atPath: bazelOut)) ?? bazelOut
        if let best = bestConfigBin(in: outPath, fileManager: fm) {
            printErr("Auto-detected metadata in: \(best)")
            return best
        }

        return (try? fm.destinationOfSymbolicLink(atPath: bazelBin)) ?? bazelBin
    }

    /// Check if a directory contains any `.swift_deps_info.json` files.
    private static func hasMetadataFiles(in path: String, fileManager: FileManager) -> Bool {
        guard let enumerator = fileManager.enumerator(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return false }
        for case let url as URL in enumerator {
            if url.lastPathComponent.hasSuffix(".swift_deps_info.json") {
                return true
            }
        }
        return false
    }

    /// Find the `<config>/bin/` directory under `bazel-out` that contains
    /// aspect metadata files. Returns nil if none found.
    private static func bestConfigBin(
        in bazelOut: String,
        fileManager fm: FileManager
    ) -> String? {
        guard let configs = try? fm.contentsOfDirectory(atPath: bazelOut) else { return nil }

        var best: (path: String, count: Int)?
        for config in configs {
            let binDir = URL(fileURLWithPath: bazelOut)
                .appendingPathComponent(config)
                .appendingPathComponent("bin")
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: binDir.path, isDirectory: &isDir),
                  isDir.boolValue else { continue }

            var count = 0
            if let enumerator = fm.enumerator(
                at: binDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) {
                for case let url as URL in enumerator {
                    if url.lastPathComponent.hasSuffix(".swift_deps_info.json") {
                        count += 1
                    }
                }
            }
            if count > 0 && (best == nil || count > best!.count) {
                best = (binDir.path, count)
            }
        }
        return best?.path
    }

    private static func workspaceDirectory() -> URL? {
        ProcessInfo.processInfo.environment["BUILD_WORKSPACE_DIRECTORY"]
            .map { URL(fileURLWithPath: $0) }
    }
}
