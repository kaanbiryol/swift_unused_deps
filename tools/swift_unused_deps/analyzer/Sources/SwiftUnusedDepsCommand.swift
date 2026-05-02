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

public struct SwiftUnusedDepsCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "swift_unused_deps",
        abstract: "Detect unused and missing direct Bazel deps for Swift targets."
    )

    @Flag(help: "Output JSON.")
    var json = false

    @Option(help: "Minimum confidence level to report: low, medium, high.")
    var minConfidence: String = "low"

    @Flag(help: "Run buildozer to fix high-confidence issues.")
    var fix = false

    @Option(help: "Comma-separated extra module names to treat as system modules.")
    var extraSystemModules: String?

    @Option(help: "Override path to Swift index store instead of using rules_swift outputs.")
    var indexStorePath: String?

    @Option(help: "Bazel config to use for the automatic build step in batch mode.")
    var buildConfig: String = "unused-deps"

    @Argument(help: "Bazel target pattern to analyze (e.g. //libraries/...).")
    var filter: String?

    public init() {}

    public func validate() throws {
        if fix && json {
            throw ValidationError("--fix cannot be combined with --json.")
        }
        if filter == nil {
            throw ValidationError("Batch mode requires a Bazel target pattern.")
        }
        if buildConfig.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ValidationError("--build-config cannot be empty.")
        }
    }

    public func run() throws {
        guard let confidence = Confidence(rawValue: minConfidence) else {
            throw ValidationError("Invalid confidence level '\(minConfidence)'. Use: low, medium, high")
        }

        let extraSystem = parseExtraSystemModules(extraSystemModules)
        try runBatch(confidence: confidence, extraSystem: extraSystem)
    }

    private func runBatch(confidence: Confidence, extraSystem: Set<String>) throws {
        guard let pattern = filter else {
            throw ValidationError("Batch mode requires a Bazel target pattern.")
        }
        let initialOutput = try analyzeBatch(pattern: pattern, extraSystem: extraSystem)
        let output: BatchAnalyzer.Output

        if fix && !json {
            let didApplyFixes = try runFixes(results: initialOutput.results)
            if didApplyFixes {
                printErr("")
                printErr("Re-running analysis after fixes...")
                printErr("")
                output = try analyzeBatch(pattern: pattern, extraSystem: extraSystem)
            } else {
                output = initialOutput
            }
        } else {
            output = initialOutput
        }

        print(render(results: output.results, minConfidence: confidence))

        let hasIssues = output.results.contains { result in
            result.issues.contains { $0.confidence >= confidence }
        }
        if !output.warnings.isEmpty {
            throw ExitCode(2)
        }
        if hasIssues {
            throw ExitCode(1)
        }
    }

    private func analyzeBatch(
        pattern: String,
        extraSystem: Set<String>
    ) throws -> BatchAnalyzer.Output {
        let workspace = Self.workspaceDirectory()
        try runBazelBuild(pattern: pattern, workspaceDirectory: workspace)

        let metadataRoot = Self.resolveDefaultMetadataRoot(
            targetPattern: pattern,
            buildConfig: buildConfig,
            workspaceDirectory: workspace
        )
        guard !metadataRoot.isEmpty else {
            printErr("ERROR: Could not determine metadata root.")
            throw ExitCode(2)
        }

        let labelConverter = LabelConverter.loadFromBazel(workspaceDirectory: workspace?.path) ?? .identity

        let output = BatchAnalyzer.analyze(options: .init(
            bazelBin: metadataRoot,
            indexStorePath: resolvedIndexStorePath(workspaceDirectory: workspace),
            extraSystemModules: extraSystem,
            filter: pattern,
            labelConverter: labelConverter,
            workspaceDirectory: workspace
        ))

        for warning in output.warnings {
            printErr("WARNING: \(warning)")
        }

        if output.results.isEmpty && output.warnings.isEmpty {
            printErr("ERROR: No metadata files found.")
            printErr("Hint: verify your .bazelrc config named '\(buildConfig)' writes aspect outputs.")
            throw ExitCode(2)
        }

        if output.results.isEmpty {
            printErr("ERROR: No analysis results found for \(pattern).")
            throw ExitCode(2)
        }

        return output
    }

    private func render(results: [AnalysisResult], minConfidence: Confidence) -> String {
        if json {
            return Report.formatJSON(results: results, minConfidence: minConfidence)
        }
        return Report.formatText(results: results, minConfidence: minConfidence)
    }

    private func runFixes(results: [AnalysisResult]) throws -> Bool {
        let workspace = Self.workspaceDirectory()
        let fixableIssues = results
            .flatMap(\.issues)
            .filter { $0.confidence >= .high }
        let sourceImportRemovals = Array(Set(fixableIssues.flatMap(\.sourceImportRemovals))).sorted {
            if $0.filePath == $1.filePath {
                return $0.moduleName < $1.moduleName
            }
            return $0.filePath < $1.filePath
        }
        let commands = fixableIssues.compactMap(\.buildozerCommand)

        guard !commands.isEmpty || !sourceImportRemovals.isEmpty else {
            printErr("No high-confidence fixes to apply.")
            return false
        }

        printErr("")
        printErr("Applying \(commands.count) BUILD fix(es) and \(sourceImportRemovals.count) source import removal(s)...")
        printErr("")

        for removal in sourceImportRemovals {
            printErr("  remove import \(removal.moduleName) from \(removal.filePath)")
        }

        if !sourceImportRemovals.isEmpty {
            try SourceImportEditor.apply(
                removals: sourceImportRemovals,
                workspaceDirectory: workspace
            )
        }

        if commands.isEmpty {
            printErr("Done: source import removal(s) applied.")
            return true
        }

        let result = Buildozer.runBatch(
            commands: commands,
            workingDirectory: workspace
        )
        if result.success {
            printErr("Done: \(commands.count) BUILD fix(es) and \(sourceImportRemovals.count) source import removal(s) applied.")
            return true
        } else if result.noChanges {
            printErr("WARNING: buildozer made no changes (\(commands.count) command(s) attempted).")
            printErr("The labels in the commands may not match the label format in BUILD files.")
            return false
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

    private func resolvedIndexStorePath(workspaceDirectory: URL?) -> String? {
        if let indexStorePath {
            return indexStorePath
        }
        return Self.defaultIndexStorePath(workspaceDirectory: workspaceDirectory)
    }

    static func defaultIndexStorePath(
        workspaceDirectory: URL?,
        bazelInfo: BazelInfoProvider = .process
    ) -> String? {
        guard let workspaceDirectory else { return nil }
        if let outputPath = bazelInfo.lookup("output_path", currentDirectory: workspaceDirectory) {
            return URL(fileURLWithPath: outputPath, isDirectory: true)
                .appendingPathComponent("_global_index_store", isDirectory: true)
                .path
        }
        return workspaceDirectory
            .appendingPathComponent("bazel-out/_global_index_store", isDirectory: true)
            .path
    }

    static func bazelBuildArguments(pattern: String, config: String) -> [String] {
        [
            "bazel", "build", pattern, "--config=\(config)",
            "--features=swift.index_while_building",
            "--features=swift.use_global_index_store",
        ]
    }

    private func runBazelBuild(pattern: String, workspaceDirectory: URL?) throws {
        guard let workspace = workspaceDirectory else {
            printErr("WARNING: BUILD_WORKSPACE_DIRECTORY not set, skipping automatic build.")
            return
        }

        printErr("Building \(pattern) with --config=\(buildConfig) ...")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = Self.bazelBuildArguments(pattern: pattern, config: buildConfig)
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

    private static func resolveDefaultMetadataRoot(
        targetPattern: String,
        buildConfig: String,
        workspaceDirectory: URL?
    ) -> String {
        resolveMetadataRoot(
            workspaceDirectory: workspaceDirectory,
            currentDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
            fileManager: .default,
            bazelInfo: .process,
            targetPattern: targetPattern,
            bazelInfoOptions: ["--config=\(buildConfig)"]
        )
    }

    static func resolveMetadataRoot(
        workspaceDirectory: URL?,
        currentDirectory: URL,
        fileManager fm: FileManager,
        bazelInfo: BazelInfoProvider,
        targetPattern: String? = nil,
        bazelInfoOptions: [String] = []
    ) -> String {
        let wsURL = workspaceDirectory ?? currentDirectory
        let targetFilter = targetPattern.map(TargetFilter.init)
        let bazelOut = wsURL.appendingPathComponent("bazel-out").path
        let outPath = bazelInfo.lookup("output_path", currentDirectory: wsURL)
            ?? (try? fm.destinationOfSymbolicLink(atPath: bazelOut))
            ?? bazelOut

        // Ask Bazel first. Some workspaces use a custom output base and do not
        // create the usual bazel-bin/bazel-out convenience symlinks.
        if let bazelBin = bazelInfo.lookup(
            "bazel-bin",
            currentDirectory: wsURL,
            options: bazelInfoOptions
        ),
           hasMetadataFiles(in: bazelBin, matching: targetFilter, fileManager: fm) {
            return bazelBin
        }

        // If Bazel cannot report a configured bazel-bin path, search the real
        // output path for a config directory containing this run's target.
        if let targetFilter,
           let best = bestConfigBin(in: outPath, matching: targetFilter, fileManager: fm) {
            printErr("Auto-detected metadata in: \(best)")
            return best
        }

        // Try bazel-bin symlink next.
        let bazelBin = wsURL.appendingPathComponent("bazel-bin").path
        if let resolved = try? fm.destinationOfSymbolicLink(atPath: bazelBin),
           hasMetadataFiles(in: resolved, matching: targetFilter, fileManager: fm) {
            return resolved
        }

        // bazel-bin points to a config with no metadata (common when
        // `bazel run` changes the symlink). Scan bazel-out for the config
        // that has aspect outputs from --config=unused-deps.
        if let best = bestConfigBin(in: outPath, matching: targetFilter, fileManager: fm) {
            printErr("Auto-detected metadata in: \(best)")
            return best
        }

        return (try? fm.destinationOfSymbolicLink(atPath: bazelBin)) ?? bazelBin
    }

    /// Check if a directory contains any `.swift_deps_info.json` files.
    private static func hasMetadataFiles(
        in path: String,
        matching targetFilter: TargetFilter?,
        fileManager: FileManager
    ) -> Bool {
        metadataStats(in: path, matching: targetFilter, fileManager: fileManager).count > 0
    }

    private static func metadataStats(
        in path: String,
        matching targetFilter: TargetFilter?,
        fileManager: FileManager
    ) -> (count: Int, latestModificationDate: Date) {
        guard let enumerator = fileManager.enumerator(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return (0, .distantPast) }

        var count = 0
        var latestModificationDate = Date.distantPast
        for case let url as URL in enumerator {
            guard url.lastPathComponent.hasSuffix(".swift_deps_info.json") else {
                continue
            }

            if let targetFilter {
                guard
                    let data = try? Data(contentsOf: url),
                    let metadata = try? JSONDecoder().decode(TargetMetadata.self, from: data),
                    targetFilter.matches(label: metadata.target.label)
                else {
                    continue
                }
            }

            count += 1
            if let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
               let modificationDate = values.contentModificationDate,
               modificationDate > latestModificationDate {
                latestModificationDate = modificationDate
            }
        }

        return (count, latestModificationDate)
    }

    /// Find the `<config>/bin/` directory under `bazel-out` that contains
    /// aspect metadata files. Returns nil if none found.
    private static func bestConfigBin(
        in bazelOut: String,
        matching targetFilter: TargetFilter?,
        fileManager fm: FileManager
    ) -> String? {
        guard let configs = try? fm.contentsOfDirectory(atPath: bazelOut) else { return nil }

        var best: (path: String, count: Int, latestModificationDate: Date)?
        for config in configs {
            let binDir = URL(fileURLWithPath: bazelOut)
                .appendingPathComponent(config)
                .appendingPathComponent("bin")
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: binDir.path, isDirectory: &isDir),
                  isDir.boolValue else { continue }

            let stats = metadataStats(in: binDir.path, matching: targetFilter, fileManager: fm)
            if stats.count == 0 {
                continue
            }

            if best == nil
                || stats.count > best!.count
                || (stats.count == best!.count && stats.latestModificationDate > best!.latestModificationDate) {
                best = (binDir.path, stats.count, stats.latestModificationDate)
            }
        }
        return best?.path
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
