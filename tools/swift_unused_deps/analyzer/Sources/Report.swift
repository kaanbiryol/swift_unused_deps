import Foundation

public enum Report {

    public static func formatText(results: [AnalysisResult], minConfidence: Confidence) -> String {
        var lines: [String] = []
        lines.append("swift_unused_deps v0.1.0")
        lines.append("Analyzing \(results.count) target\(results.count == 1 ? "" : "s")...")
        lines.append("")

        var totalHigh = 0, totalMedium = 0, totalLow = 0

        for result in results {
            let filtered = result.issues.filter { $0.confidence >= minConfidence }

            if filtered.isEmpty {
                lines.append(result.target)
                lines.append("  Status: CLEAN")
                let depCount = result.cleanDeps.count
                if depCount > 0 {
                    lines.append("  Declared deps: \(depCount)")
                }
                let systemSkipped = result.skippedModules
                    .filter { $0.reason == "system_module" }
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
        var output: [String: Any] = [
            "schema_version": 1,
            "analyzed_at": ISO8601DateFormatter().string(from: Date()),
        ]

        var resultDicts: [[String: Any]] = []
        for result in results {
            let filtered = result.issues.filter { $0.confidence >= minConfidence }

            let dict: [String: Any] = [
                "target": result.target,
                "module_name": result.moduleName,
                "status": filtered.isEmpty ? "clean" : "issues_found",
                "issues": filtered.map(issueToDict),
                "clean_deps": result.cleanDeps.map { dep in
                    [
                        "label": dep.label,
                        "module_name": dep.moduleName,
                        "classification": "correctly_declared_\(dep.kind.rawValue)",
                    ] as [String: String]
                },
                "skipped_modules": result.skippedModules.map { mod in
                    ["module_name": mod.name, "reason": mod.reason] as [String: String]
                },
            ]
            resultDicts.append(dict)
        }

        output["results"] = resultDicts

        guard let data = try? JSONSerialization.data(
            withJSONObject: output,
            options: [.prettyPrinted, .sortedKeys]
        ) else {
            return "{}"
        }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func issueToDict(_ issue: Issue) -> [String: Any] {
        var dict: [String: Any] = [
            "kind": issue.kind.rawValue,
            "confidence": issue.confidence.rawValue,
            "reason": issue.reason,
            "suggested_action": issue.suggestedAction.rawValue,
        ]
        if let v = issue.depLabel { dict["dep_label"] = v }
        if let v = issue.depModule { dict["dep_module"] = v }
        if let v = issue.depKind { dict["dep_kind"] = v.rawValue }
        if !issue.currentlyReachableVia.isEmpty {
            dict["currently_reachable_via"] = issue.currentlyReachableVia
        }
        if let v = issue.buildozerCommand { dict["buildozer_command"] = v.displayString }
        return dict
    }
}
