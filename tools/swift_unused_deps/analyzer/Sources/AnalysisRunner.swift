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
            "--notool_deps",
            "--noimplicit_deps",
            "kind(\".* rule\", deps(\(targetPattern)))",
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

enum AnalysisRunner {
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

    static func run(_ invocation: AnalysisInvocation) throws -> AnalysisRun {
        let workspace = resolvedWorkspaceDirectory(invocation.workspaceDirectory)
        let metadataRoot = try resolvedMetadataRoot(invocation.metadataRoot)
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
            extraSystemModules: SwiftUnusedDepsCommand.parseExtraSystemModules(invocation.extraSystemModules),
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

    private static func resolvedWorkspaceDirectory(_ workspaceDirectory: String?) -> URL? {
        if let workspaceDirectory {
            return URL(fileURLWithPath: workspaceDirectory, isDirectory: true)
        }
        return Self.workspaceDirectory()
    }

    private static func resolvedMetadataRoot(_ metadataRoot: String?) throws -> String {
        if let metadataRoot {
            return metadataRoot
        }

        throw ValidationError("--metadata-root is required for debug metadata analysis. Prefer swift_unused_deps_test or swift_unused_deps_report for normal Bazel usage.")
    }
}
