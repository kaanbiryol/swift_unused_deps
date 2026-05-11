import XCTest
@testable import SwiftUnusedDepsLib

final class CLITests: XCTestCase {

    func testParseAnalyzeSubcommand() throws {
        let command = try XCTUnwrap(
            try SwiftUnusedDepsCommand.parseAsRoot([
                "analyze",
                "//App/...",
                "--metadata-root", "/tmp/bazel-bin",
                "--index-store-path", "/tmp/index-store",
                "--fix-output", "/tmp/fix.json",
                "--include-low-confidence-fixes",
                "--min-report-confidence", "medium",
                "--min-fix-confidence", "low",
                "--report-output", "/tmp/report.out",
                "--exit-code-output", "/tmp/report.exit_code",
            ]) as? SwiftUnusedDepsAnalyzeCommand
        )

        XCTAssertEqual(command.targetPattern, "//App/...")
        XCTAssertEqual(command.metadataRoot, "/tmp/bazel-bin")
        XCTAssertEqual(command.indexStorePath, "/tmp/index-store")
        XCTAssertNil(command.filter)
        XCTAssertEqual(command.fixOutput, "/tmp/fix.json")
        XCTAssertTrue(command.includeLowConfidenceFixes)
        XCTAssertEqual(command.minReportConfidence, "medium")
        XCTAssertEqual(command.minFixConfidence, "low")
        XCTAssertEqual(command.reportOutput, "/tmp/report.out")
        XCTAssertEqual(command.exitCodeOutput, "/tmp/report.exit_code")
    }

    func testParseAnalyzeLegacyOptions() throws {
        let command = try XCTUnwrap(
            try SwiftUnusedDepsCommand.parseAsRoot([
                "analyze",
                "--metadata-root", "/tmp/bazel-bin",
                "--filter", "//App/...",
                "--fix-plan-output", "/tmp/fix_plan.json",
                "--min-confidence", "high",
                "--fix-plan-min-confidence", "low",
            ]) as? SwiftUnusedDepsAnalyzeCommand
        )

        XCTAssertNil(command.targetPattern)
        XCTAssertEqual(command.filter, "//App/...")
        XCTAssertEqual(command.legacyFixPlanOutput, "/tmp/fix_plan.json")
        XCTAssertEqual(command.legacyMinConfidence, "high")
        XCTAssertEqual(command.legacyFixPlanMinConfidence, "low")
    }

    func testParseAnalyzeRejectsEmptyMetadataRoot() {
        XCTAssertThrowsError(try SwiftUnusedDepsCommand.parseAsRoot([
            "analyze",
            "--metadata-root", "",
        ])) { error in
            XCTAssertTrue("\(error)".contains("--metadata-root cannot be empty."))
        }
    }

    func testParseAnalyzeRejectsConflictingLowConfidenceFixOptions() {
        XCTAssertThrowsError(try SwiftUnusedDepsCommand.parseAsRoot([
            "analyze",
            "//App/...",
            "--include-low-confidence-fixes",
            "--min-fix-confidence", "high",
        ])) { error in
            XCTAssertTrue("\(error)".contains("--include-low-confidence-fixes"))
        }
    }

    func testParseFixSubcommand() throws {
        let command = try XCTUnwrap(
            try SwiftUnusedDepsCommand.parseAsRoot([
                "fix",
                "//App/...",
                "--metadata-root", "/tmp/bazel-bin",
                "--index-store-path", "/tmp/index-store",
                "--fix-output", "/tmp/fix.json",
                "--include-low-confidence-fixes",
                "--report-output", "/tmp/report.json",
                "--workspace-directory", "/tmp/workspace",
            ]) as? SwiftUnusedDepsFixCommand
        )

        XCTAssertEqual(command.targetPattern, "//App/...")
        XCTAssertEqual(command.metadataRoot, "/tmp/bazel-bin")
        XCTAssertEqual(command.indexStorePath, "/tmp/index-store")
        XCTAssertEqual(command.fixOutput, "/tmp/fix.json")
        XCTAssertTrue(command.includeLowConfidenceFixes)
        XCTAssertEqual(command.reportOutput, "/tmp/report.json")
        XCTAssertEqual(command.workspaceDirectory, "/tmp/workspace")
    }

    func testParseMergeReportsSubcommand() throws {
        let command = try XCTUnwrap(
            try SwiftUnusedDepsCommand.parseAsRoot([
                "merge-reports",
                "--report-input", "/tmp/a.report.json",
                "--fix-input", "/tmp/a.fix.json",
                "--min-report-confidence", "high",
                "--report-output", "/tmp/merged.report.json",
                "--text-output", "/tmp/merged.report.txt",
                "--fix-output", "/tmp/merged.fix.json",
                "--exit-code-output", "/tmp/merged.exit_code",
            ]) as? SwiftUnusedDepsMergeReportsCommand
        )

        XCTAssertEqual(command.reportInputs, ["/tmp/a.report.json"])
        XCTAssertEqual(command.fixInputs, ["/tmp/a.fix.json"])
        XCTAssertEqual(command.minReportConfidence, "high")
        XCTAssertEqual(command.reportOutput, "/tmp/merged.report.json")
        XCTAssertEqual(command.textOutput, "/tmp/merged.report.txt")
        XCTAssertEqual(command.fixOutput, "/tmp/merged.fix.json")
        XCTAssertEqual(command.exitCodeOutput, "/tmp/merged.exit_code")
    }

    func testParseApplySubcommand() throws {
        let command = try XCTUnwrap(
            try SwiftUnusedDepsCommand.parseAsRoot([
                "apply",
                "--workspace-directory", "/tmp/workspace",
                "/tmp/fix_plan.json",
            ]) as? SwiftUnusedDepsApplyCommand
        )

        XCTAssertEqual(command.workspaceDirectory, "/tmp/workspace")
        XCTAssertEqual(command.fixPlanPaths, ["/tmp/fix_plan.json"])
    }

    func testParseApplyRequiresFixPlanPath() {
        XCTAssertThrowsError(try SwiftUnusedDepsCommand.parseAsRoot([
            "apply",
        ])) { error in
            XCTAssertTrue("\(error)".contains("apply requires at least one fix file path."))
        }
    }

    func testParseExtraSystemModulesTrimsEmptyValues() {
        XCTAssertEqual(
            SwiftUnusedDepsCommand.parseExtraSystemModules(" Foundation,CustomKit, ,UIKit "),
            ["Foundation", "CustomKit", "UIKit"]
        )
    }

    func testWorkspaceDirectoryPrefersBazelWorkspaceFromBuildWorkingDirectory() {
        let workingDirectory = "/tmp/consumer/subdir"
        let consumerWorkspace = "/tmp/consumer"
        let runfilesWorkspace = "/tmp/tool.runfiles/_main"

        let result = SwiftUnusedDepsCommand.workspaceDirectory(
            environment: [
                "BUILD_WORKING_DIRECTORY": workingDirectory,
                "BUILD_WORKSPACE_DIRECTORY": runfilesWorkspace,
            ],
            bazelInfo: BazelInfoProvider { key, currentDirectory in
                XCTAssertEqual(key, "workspace")
                XCTAssertEqual(currentDirectory.path, workingDirectory)
                return consumerWorkspace
            }
        )

        XCTAssertEqual(result?.path, consumerWorkspace)
    }

    func testWorkspaceDirectoryFallsBackToBuildWorkspaceDirectory() {
        let workspace = "/tmp/tool.runfiles/_main"

        let result = SwiftUnusedDepsCommand.workspaceDirectory(
            environment: ["BUILD_WORKSPACE_DIRECTORY": workspace],
            bazelInfo: BazelInfoProvider { _, _ in nil }
        )

        XCTAssertEqual(result?.path, workspace)
    }
}
