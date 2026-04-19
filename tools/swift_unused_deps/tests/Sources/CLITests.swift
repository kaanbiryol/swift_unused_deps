import XCTest
@testable import SwiftUnusedDepsLib

final class CLITests: XCTestCase {

    func testRejectsBatchModeWithoutPattern() {
        XCTAssertThrowsError(try SwiftUnusedDepsCommand.parseAsRoot([])) { error in
            XCTAssertTrue("\(error)".contains("Batch mode requires a Bazel target pattern."))
        }
    }

    func testParseBatchModeWithFilter() throws {
        let command = try XCTUnwrap(
            try SwiftUnusedDepsCommand.parseAsRoot([
                "//App/Features/Login...",
            ]) as? SwiftUnusedDepsCommand
        )

        XCTAssertEqual(command.filter, "//App/Features/Login...")
    }

    func testParseBatchModeWithCustomBuildConfig() throws {
        let command = try XCTUnwrap(
            try SwiftUnusedDepsCommand.parseAsRoot([
                "--build-config", "unused-deps-ios",
                "//App:App",
            ]) as? SwiftUnusedDepsCommand
        )

        XCTAssertEqual(command.buildConfig, "unused-deps-ios")
    }

    func testBuildArgumentsUseSelectedConfig() {
        XCTAssertEqual(
            SwiftUnusedDepsCommand.bazelBuildArguments(
                pattern: "//App:App",
                config: "unused-deps-ios"
            ),
            [
                "bazel", "build", "//App:App", "--config=unused-deps-ios",
                "--features=swift.index_while_building",
                "--features=swift.use_global_index_store",
            ]
        )
    }

    func testDefaultIndexStorePathUsesGlobalBazelOutLocation() {
        let workspace = URL(fileURLWithPath: "/tmp/workspace-one", isDirectory: true)

        XCTAssertEqual(
            SwiftUnusedDepsCommand.defaultIndexStorePath(workspaceDirectory: workspace),
            "/tmp/workspace-one/bazel-out/_global_index_store"
        )
    }

    func testRejectsFixWithJson() {
        XCTAssertThrowsError(try SwiftUnusedDepsCommand.parseAsRoot([
            "//App:App",
            "--fix",
            "--json",
        ])) { error in
            XCTAssertTrue("\(error)".contains("--fix cannot be combined with --json."))
        }
    }
}
