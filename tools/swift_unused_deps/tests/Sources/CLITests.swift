import XCTest
@testable import SwiftUnusedDepsLib

final class CLITests: XCTestCase {

    func testParseAnalyzeTargetSubcommand() throws {
        let command = try XCTUnwrap(
            try SwiftUnusedDepsCommand.parseAsRoot([
                "analyze-target",
                "--metadata-file", "/tmp/target.metadata.json",
                "--dependency-metadata-file", "/tmp/dep.metadata.json",
                "--bazel-bin", "/tmp/bazel-bin",
                "--index-store-path", "/tmp/index-store",
                "--dependency-index-store-path", "/tmp/dependency-index-store",
                "--report-output", "/tmp/report.json",
                "--fix-output", "/tmp/fix.json",
                "--fix-low-output", "/tmp/fix-low.json",
            ]) as? SwiftUnusedDepsAnalyzeTargetCommand
        )

        XCTAssertEqual(command.metadataFile, "/tmp/target.metadata.json")
        XCTAssertEqual(command.dependencyMetadataFiles, ["/tmp/dep.metadata.json"])
        XCTAssertEqual(command.bazelBin, "/tmp/bazel-bin")
        XCTAssertEqual(command.indexStorePath, "/tmp/index-store")
        XCTAssertEqual(command.dependencyIndexStorePaths, ["/tmp/dependency-index-store"])
        XCTAssertEqual(command.reportOutput, "/tmp/report.json")
        XCTAssertEqual(command.fixOutput, "/tmp/fix.json")
        XCTAssertEqual(command.fixLowOutput, "/tmp/fix-low.json")
    }

    func testParseAnalyzeTargetRejectsEmptyMetadataFile() {
        XCTAssertThrowsError(try SwiftUnusedDepsCommand.parseAsRoot([
            "analyze-target",
            "--metadata-file", "",
        ])) { error in
            XCTAssertTrue("\(error)".contains("--metadata-file cannot be empty."))
        }
    }

    func testRejectsMediumReportConfidence() {
        XCTAssertThrowsError(try SwiftUnusedDepsCommand.confidence("medium", option: "--min-report-confidence")) { error in
            XCTAssertTrue("\(error)".contains("Use: low, high"))
        }
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
                "/tmp/first_fix_plan.json",
                "/tmp/second_fix_plan.json",
            ]) as? SwiftUnusedDepsApplyCommand
        )

        XCTAssertEqual(command.workspaceDirectory, "/tmp/workspace")
        XCTAssertEqual(command.fixPlanPaths, [
            "/tmp/first_fix_plan.json",
            "/tmp/second_fix_plan.json",
        ])
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
