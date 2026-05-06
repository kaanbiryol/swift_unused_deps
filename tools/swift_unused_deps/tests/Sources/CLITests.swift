import XCTest
@testable import SwiftUnusedDepsLib

final class CLITests: XCTestCase {

    func testParseAnalyzeSubcommand() throws {
        let command = try XCTUnwrap(
            try SwiftUnusedDepsCommand.parseAsRoot([
                "analyze",
                "--metadata-root", "/tmp/bazel-bin",
                "--index-store-path", "/tmp/index-store",
                "--filter", "//App/...",
                "--fix-plan-output", "/tmp/fix_plan.json",
                "--report-output", "/tmp/report.out",
                "--exit-code-output", "/tmp/report.exit_code",
            ]) as? SwiftUnusedDepsAnalyzeCommand
        )

        XCTAssertEqual(command.metadataRoot, "/tmp/bazel-bin")
        XCTAssertEqual(command.indexStorePath, "/tmp/index-store")
        XCTAssertEqual(command.filter, "//App/...")
        XCTAssertEqual(command.fixPlanOutput, "/tmp/fix_plan.json")
        XCTAssertEqual(command.reportOutput, "/tmp/report.out")
        XCTAssertEqual(command.exitCodeOutput, "/tmp/report.exit_code")
    }

    func testParseAnalyzeRejectsEmptyMetadataRoot() {
        XCTAssertThrowsError(try SwiftUnusedDepsCommand.parseAsRoot([
            "analyze",
            "--metadata-root", "",
        ])) { error in
            XCTAssertTrue("\(error)".contains("--metadata-root cannot be empty."))
        }
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
            XCTAssertTrue("\(error)".contains("apply requires at least one fix plan path."))
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
