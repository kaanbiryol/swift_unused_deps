import ArgumentParser
import Foundation
import SwiftUnusedDepsLib

@main
struct SwiftUnusedDeps: ParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "swift_unused_deps",
        abstract: "Detect unused and missing direct Bazel deps for Swift targets."
    )

    // MARK: - Single-target mode (used by aspect action)

    @Option(help: "Path to a single target metadata JSON file.")
    var metadataFile: String?

    @Option(help: "Path to a single target trace JSON file.")
    var traceFile: String?

    @Option(help: "Path to write the analysis report.")
    var output: String?

    // MARK: - Batch mode (used by CLI)

    @Option(help: "Path to bazel-bin. Auto-discovers aspect outputs and trace files.")
    var bazelBin: String?

    @Option(help: "Directory containing aspect metadata JSON files.")
    var metadataDir: String?

    @Option(help: "Directory containing Swift loaded module trace JSON files.")
    var traceDir: String?

    // MARK: - Common options

    @Flag(help: "Output JSON.")
    var json = false

    @Option(help: "Minimum confidence level to report: low, medium, high.")
    var minConfidence: String = "low"

    @Flag(help: "Show buildozer fix commands.")
    var fix = false

    @Option(help: "Comma-separated extra module names to treat as system modules.")
    var extraSystemModules: String?

    func validate() throws {
        let hasSingleMode = metadataFile != nil
        let hasBatchMode = bazelBin != nil || metadataDir != nil

        if !hasSingleMode && !hasBatchMode {
            throw ValidationError(
                "Provide --metadata-file + --trace-file (single target) "
                + "or --bazel-bin / --metadata-dir (batch)."
            )
        }
        if hasSingleMode && hasBatchMode {
            throw ValidationError("Cannot combine --metadata-file with --bazel-bin or --metadata-dir.")
        }
        if hasSingleMode && traceFile == nil {
            throw ValidationError("--trace-file is required with --metadata-file.")
        }
        if hasSingleMode && output == nil {
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

    // MARK: - Single-target mode

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

        // In single-target mode (Bazel action), always exit 0.
        // The report file is the output - issues are findings, not errors.
    }

    // MARK: - Batch mode

    private func runBatch(confidence: Confidence, extraSystem: Set<String>) throws {
        let metadataFiles: [URL]
        let traceFiles: [String: URL]

        if let bazelBin = bazelBin {
            let baseURL = URL(fileURLWithPath: bazelBin, isDirectory: true)
            metadataFiles = discoverFiles(in: baseURL, suffix: ".swift_deps_info.json")
            traceFiles = discoverTraceFiles(in: baseURL)
        } else {
            let metaURL = URL(fileURLWithPath: metadataDir!, isDirectory: true)
            metadataFiles = discoverFiles(in: metaURL, suffix: ".json", excludeSuffix: ".trace.json")
            if let td = traceDir {
                traceFiles = discoverTraceFiles(in: URL(fileURLWithPath: td, isDirectory: true))
            } else {
                traceFiles = [:]
            }
        }

        if metadataFiles.isEmpty {
            printErr("ERROR: No metadata files found.")
            printErr("Hint: run 'bazel build <targets> --aspects=//tools/swift_unused_deps/aspect:deps_info.bzl%swift_deps_aspect --output_groups=swift_deps_info' first.")
            throw ExitCode(2)
        }

        var results: [AnalysisResult] = []
        var errors: [String] = []

        for metadataFile in metadataFiles {
            let metadata: TargetMetadata
            do {
                let data = try Data(contentsOf: metadataFile)
                metadata = try JSONDecoder().decode(TargetMetadata.self, from: data)
            } catch {
                errors.append("Failed to parse \(metadataFile.path): \(error)")
                continue
            }

            var traceFile = traceFiles[metadata.target.moduleName]
            if traceFile == nil && !metadata.traceFile.isEmpty {
                if let bb = bazelBin {
                    let candidate = URL(fileURLWithPath: bb).appendingPathComponent(metadata.traceFile)
                    if FileManager.default.fileExists(atPath: candidate.path) {
                        traceFile = candidate
                    }
                }
            }

            guard let traceURL = traceFile else {
                errors.append(
                    "No trace file for \(metadata.target.label) (module: \(metadata.target.moduleName)). "
                    + "Was --swiftcopt=-emit-loaded-module-trace passed during build?"
                )
                continue
            }

            let loadedModules: [LoadedModule]
            do {
                loadedModules = try TraceParser.parseTraceFile(at: traceURL, forModule: metadata.target.moduleName)
            } catch {
                errors.append("Failed to parse trace for \(metadata.target.label): \(error)")
                continue
            }

            let resolver = ModuleResolver(
                transitiveModuleMap: metadata.transitiveModuleMap,
                extraSystemModules: extraSystem
            )
            let result = Analyzer.analyze(
                metadata: metadata,
                loadedModules: loadedModules,
                resolver: resolver
            )
            results.append(result)
        }

        for err in errors {
            printErr("WARNING: \(err)")
        }

        if json {
            print(Report.formatJSON(results: results, minConfidence: confidence))
        } else {
            print(Report.formatText(results: results, minConfidence: confidence))
        }

        if fix && !json {
            printFixCommands(results: results)
        }

        let hasIssues = results.contains { result in
            result.issues.contains { $0.confidence >= confidence }
        }
        if !errors.isEmpty {
            throw ExitCode(2)
        }
        if hasIssues {
            throw ExitCode(1)
        }
    }

    // MARK: - Helpers

    private func printFixCommands(results: [AnalysisResult]) {
        var commands: [String] = []
        for result in results {
            for issue in result.issues {
                guard issue.confidence >= .high, let cmd = issue.buildozerCommand else { continue }
                commands.append(cmd)
            }
        }
        guard !commands.isEmpty else { return }

        printErr("")
        printErr("--- Suggested fixes (dry-run) ---")
        printErr("")
        for cmd in commands {
            printErr("  \(cmd)")
        }
    }

    private func discoverFiles(in directory: URL, suffix: String, excludeSuffix: String? = nil) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [URL] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if name.hasSuffix(suffix) {
                if let exclude = excludeSuffix, name.hasSuffix(exclude) { continue }
                files.append(url)
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    private func discoverTraceFiles(in directory: URL) -> [String: URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [:] }

        var traces: [String: URL] = [:]
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if name.hasSuffix(".trace.json") {
                let moduleName = String(name.dropLast(".trace.json".count))
                traces[moduleName] = url
            }
        }
        return traces
    }
}

private func printErr(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}
