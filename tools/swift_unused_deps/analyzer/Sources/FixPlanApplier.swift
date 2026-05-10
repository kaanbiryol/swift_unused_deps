import ArgumentParser
import Foundation

public enum FixPlanApplier {
    public struct Result {
        public let applied: Bool
        public let buildFixCount: Int
        public let sourceImportRemovalCount: Int
    }

    public static func apply(
        _ plan: FixPlan,
        workspaceDirectory: URL? = nil
    ) throws -> Result {
        guard !plan.isEmpty else {
            printErr("No fixes to apply.")
            return Result(applied: false, buildFixCount: 0, sourceImportRemovalCount: 0)
        }

        let sourceImportEdits = try SourceImportEditor.plan(
            removals: plan.sourceImportRemovals,
            workspaceDirectory: workspaceDirectory
        )

        printErr(FixPlan.formatSummary(plan))
        printErr("Applying \(plan.buildEdits.count) BUILD fix(es) and \(plan.sourceImportRemovals.count) source import removal(s)...")

        if plan.buildozerCommands.isEmpty {
            try SourceImportEditor.apply(edits: sourceImportEdits)
            return Result(
                applied: !sourceImportEdits.isEmpty,
                buildFixCount: 0,
                sourceImportRemovalCount: plan.sourceImportRemovals.count
            )
        }

        let result = Buildozer.runBatch(
            commands: plan.buildozerCommands,
            workingDirectory: workspaceDirectory
        )
        if result.success {
            try SourceImportEditor.apply(edits: sourceImportEdits)
            return Result(
                applied: true,
                buildFixCount: plan.buildEdits.count,
                sourceImportRemovalCount: plan.sourceImportRemovals.count
            )
        } else if result.noChanges {
            printErr("WARNING: buildozer made no changes (\(plan.buildEdits.count) command(s) attempted).")
            printErr("The labels in the commands may not match the label format in BUILD files.")
            return Result(applied: false, buildFixCount: 0, sourceImportRemovalCount: 0)
        } else {
            printErr("FAILED: \(result.output)")
            throw ExitCode(1)
        }
    }
}
