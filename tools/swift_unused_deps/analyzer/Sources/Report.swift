import Foundation

public enum Report {

    public static func formatText(results: [AnalysisResult], minConfidence: Confidence) -> String {
        var lines: [String] = []
        lines.append("swift_unused_deps v0.1.0")
        lines.append("Analyzing \(results.count) target\(results.count == 1 ? "" : "s")...")
        lines.append("")

        var totalHigh = 0, totalMedium = 0, totalLow = 0

        for result in results {
            let filtered = filteredIssues(in: result, minConfidence: minConfidence)

            if filtered.isEmpty {
                lines.append(result.target)
                lines.append("  Status: CLEAN")
                let depCount = result.cleanDeps.count
                if depCount > 0 {
                    lines.append("  Declared deps: \(depCount)")
                }
                let systemSkipped = result.skippedModules
                    .filter { $0.reason == .systemModule }
                    .map(\.name)
                    .sorted()
                if !systemSkipped.isEmpty {
                    lines.append("  Skipped \(systemSkipped.count) system modules: \(systemSkipped.joined(separator: ", "))")
                }
                lines.append("  No issues found.")
                lines.append("")
                continue
            }

            let high = filtered.filter { $0.confidence == .high }.count
            let medium = filtered.filter { $0.confidence == .medium }.count
            let low = filtered.filter { $0.confidence == .low }.count
            totalHigh += high
            totalMedium += medium
            totalLow += low

            lines.append(result.target)
            lines.append("  Status: \(filtered.count) issue\(filtered.count == 1 ? "" : "s") found")
            lines.append("")

            for issue in filtered {
                lines.append(contentsOf: formatIssue(issue))
                lines.append("")
            }
        }

        let totalIssues = totalHigh + totalMedium + totalLow
        lines.append("Summary: \(results.count) target\(results.count == 1 ? "" : "s") analyzed, \(totalIssues) issue\(totalIssues == 1 ? "" : "s") found.")

        if totalIssues > 0 {
            var parts: [String] = []
            if totalHigh > 0 { parts.append("\(totalHigh) high") }
            if totalMedium > 0 { parts.append("\(totalMedium) medium") }
            if totalLow > 0 { parts.append("\(totalLow) low") }
            lines.append("  \(parts.joined(separator: ", ")).")
        }

        if totalHigh > 0 {
            lines.append("")
            lines.append("Run with --fix to automatically apply fixes.")
        }

        return lines.joined(separator: "\n")
    }

    private static func filteredIssues(
        in result: AnalysisResult,
        minConfidence: Confidence
    ) -> [Issue] {
        result.issues.filter { $0.confidence >= minConfidence }
    }

    private static func formatIssue(_ issue: Issue) -> [String] {
        var lines: [String] = []
        let conf = issue.confidence.rawValue.uppercased()
        let kind = issue.kind.rawValue.uppercased()

        if let depLabel = issue.depLabel {
            var header = "  [\(conf)] \(kind): \(depLabel)"
            if let depModule = issue.depModule {
                header += " (module: \(depModule))"
            }
            lines.append(header)
        } else if let depModule = issue.depModule {
            lines.append("  [\(conf)] \(kind): \(depModule)")
        } else {
            lines.append("  [\(conf)] \(kind)")
        }

        lines.append("         \(issue.reason)")

        if !issue.currentlyReachableVia.isEmpty {
            lines.append("         Currently reachable transitively via: \(issue.currentlyReachableVia.joined(separator: ", "))")
        }

        if !issue.sourceImportRemovals.isEmpty {
            let files = issue.sourceImportRemovals.map(\.filePath).sorted()
            let summary = files.count == 1
                ? files[0]
                : "\(files.count) source files"
            lines.append("         Source fix: remove import from \(summary)")
        }

        switch issue.suggestedAction {
        case .remove, .addDep:
            if let cmd = issue.buildozerCommand {
                lines.append("         Fix: \(cmd.displayString)")
            }
        case .moveToPrivateDeps:
            if let cmd = issue.buildozerCommand {
                lines.append("         Suggestion: \(cmd.displayString)")
            }
        case .investigate:
            lines.append("         Action: investigate manually.")
        }

        return lines
    }

    public static func formatJSON(results: [AnalysisResult], minConfidence: Confidence) -> String {
        let jsonResults = results.map { result -> JSONResult in
            let filtered = filteredIssues(in: result, minConfidence: minConfidence)
            let issues = filtered.map { JSONIssue(issue: $0) }
            let cleanDeps = result.cleanDeps.map { JSONCleanDep(dep: $0) }
            let skippedModules = result.skippedModules.map { JSONSkippedModule(skippedModule: $0) }

            return JSONResult(
                target: result.target,
                moduleName: result.moduleName,
                status: filtered.isEmpty ? "clean" : "issues_found",
                issues: issues,
                cleanDeps: cleanDeps,
                skippedModules: skippedModules
            )
        }

        let output = JSONReport(
            analyzedAt: ISO8601DateFormatter().string(from: Date()),
            results: jsonResults
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        guard let data = try? encoder.encode(output) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }

    private struct JSONReport: Encodable {
        let schemaVersion = 1
        let analyzedAt: String
        let results: [JSONResult]

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case analyzedAt = "analyzed_at"
            case results
        }
    }

    private struct JSONResult: Encodable {
        let target: String
        let moduleName: String
        let status: String
        let issues: [JSONIssue]
        let cleanDeps: [JSONCleanDep]
        let skippedModules: [JSONSkippedModule]

        enum CodingKeys: String, CodingKey {
            case target
            case moduleName = "module_name"
            case status
            case issues
            case cleanDeps = "clean_deps"
            case skippedModules = "skipped_modules"
        }
    }

    private struct JSONCleanDep: Encodable {
        let label: String
        let moduleName: String
        let classification: String

        init(dep: DeclaredDep) {
            label = dep.label
            moduleName = dep.moduleName
            classification = "correctly_declared_\(dep.kind.rawValue)"
        }

        enum CodingKeys: String, CodingKey {
            case label
            case moduleName = "module_name"
            case classification
        }
    }

    private struct JSONSkippedModule: Encodable {
        let moduleName: String
        let reason: String

        init(skippedModule: SkippedModule) {
            moduleName = skippedModule.name
            reason = skippedModule.reason.rawValue
        }

        enum CodingKeys: String, CodingKey {
            case moduleName = "module_name"
            case reason
        }
    }

    private struct JSONIssue: Encodable {
        let kind: String
        let confidence: String
        let reason: String
        let suggestedAction: String
        let depLabel: String?
        let depModule: String?
        let depKind: String?
        let currentlyReachableVia: [String]?
        let buildozerCommand: String?
        let sourceImportRemovals: [JSONSourceImportRemoval]?

        init(issue: Issue) {
            kind = issue.kind.rawValue
            confidence = issue.confidence.rawValue
            reason = issue.reason
            suggestedAction = issue.suggestedAction.rawValue
            depLabel = issue.depLabel
            depModule = issue.depModule
            depKind = issue.depKind?.rawValue
            currentlyReachableVia = issue.currentlyReachableVia.isEmpty
                ? nil
                : issue.currentlyReachableVia
            buildozerCommand = issue.buildozerCommand?.displayString
            sourceImportRemovals = issue.sourceImportRemovals.isEmpty
                ? nil
                : issue.sourceImportRemovals.map { JSONSourceImportRemoval(removal: $0) }
        }

        enum CodingKeys: String, CodingKey {
            case kind
            case confidence
            case reason
            case suggestedAction = "suggested_action"
            case depLabel = "dep_label"
            case depModule = "dep_module"
            case depKind = "dep_kind"
            case currentlyReachableVia = "currently_reachable_via"
            case buildozerCommand = "buildozer_command"
            case sourceImportRemovals = "source_import_removals"
        }
    }

    private struct JSONSourceImportRemoval: Encodable {
        let filePath: String
        let moduleName: String

        init(removal: SourceImportRemoval) {
            filePath = removal.filePath
            moduleName = removal.moduleName
        }

        enum CodingKeys: String, CodingKey {
            case filePath = "file_path"
            case moduleName = "module_name"
        }
    }
}
