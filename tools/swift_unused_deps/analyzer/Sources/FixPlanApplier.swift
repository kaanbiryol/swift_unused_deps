import ArgumentParser
import Foundation

enum FixPlanApplier {
    struct Result {
        let applied: Bool
        let buildFixCount: Int
        let sourceImportRemovalCount: Int
    }

    static func apply(
        _ plan: FixPlan,
        workspaceDirectory: URL? = nil
    ) throws -> Result {
        guard !plan.isEmpty else {
            printErr("No fixes to apply.")
            return Result(applied: false, buildFixCount: 0, sourceImportRemovalCount: 0)
        }
        try plan.validate()

        let sourceImportEdits = try SourceImportEditor.plan(
            removals: plan.sourceImportRemovals,
            workspaceDirectory: workspaceDirectory,
            skipMissingImports: true
        )
        let effectiveSourceImportRemovals = sourceImportEdits.flatMap { edit in
            edit.removedModuleNames.sorted().map {
                SourceImportRemoval(filePath: edit.displayFilePath, moduleName: $0)
            }
        }
        let effectivePlan = FixPlan(
            sourceImportRemovals: effectiveSourceImportRemovals,
            buildEdits: plan.buildEdits
        )

        guard !effectivePlan.isEmpty else {
            printErr("No fixes to apply. The fix plan is already applied.")
            return Result(applied: false, buildFixCount: 0, sourceImportRemovalCount: 0)
        }

        printErr(FixPlan.formatSummary(effectivePlan))
        printErr("Applying \(plan.buildEdits.count) BUILD fix(es) and \(effectiveSourceImportRemovals.count) source import removal(s)...")

        if effectivePlan.buildozerCommands.isEmpty {
            try SourceImportEditor.apply(edits: sourceImportEdits)
            return Result(
                applied: !sourceImportEdits.isEmpty,
                buildFixCount: 0,
                sourceImportRemovalCount: effectiveSourceImportRemovals.count
            )
        }

        let result = Buildozer.runBatch(
            commands: effectivePlan.buildozerCommands,
            workingDirectory: workspaceDirectory
        )
        if result.success {
            try SourceImportEditor.apply(edits: sourceImportEdits)
            return Result(
                applied: true,
                buildFixCount: plan.buildEdits.count,
                sourceImportRemovalCount: effectiveSourceImportRemovals.count
            )
        } else if result.noChanges {
            printErr("WARNING: buildozer made no changes (\(plan.buildEdits.count) command(s) attempted).")
            printErr("The BUILD fixes may already be applied, or their targets may not be editable.")
            try SourceImportEditor.apply(edits: sourceImportEdits)
            return Result(
                applied: !sourceImportEdits.isEmpty,
                buildFixCount: 0,
                sourceImportRemovalCount: effectiveSourceImportRemovals.count
            )
        } else {
            printErr("FAILED: \(result.output)")
            throw ExitCode(1)
        }
    }
}
