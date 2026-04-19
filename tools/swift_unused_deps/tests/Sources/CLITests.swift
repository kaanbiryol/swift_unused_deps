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
                config: "unused-deps-ios",
                indexStorePath: "/tmp/store"
            ),
            [
                "bazel", "build", "//App:App", "--config=unused-deps-ios",
                "--@build_bazel_rules_swift//swift:copt=-index-store-path",
                "--@build_bazel_rules_swift//swift:copt=/tmp/store",
            ]
        )
    }

    func testDefaultIndexStorePathIsWorkspaceScoped() throws {
        let workspace = URL(fileURLWithPath: "/tmp/workspace-one")
        let otherWorkspace = URL(fileURLWithPath: "/tmp/workspace-two")

        let first = try XCTUnwrap(
            SwiftUnusedDepsCommand.defaultIndexStorePath(workspaceDirectory: workspace)
        )
        let second = try XCTUnwrap(
            SwiftUnusedDepsCommand.defaultIndexStorePath(workspaceDirectory: workspace)
        )
        let third = try XCTUnwrap(
            SwiftUnusedDepsCommand.defaultIndexStorePath(workspaceDirectory: otherWorkspace)
        )

        XCTAssertEqual(first, second)
        XCTAssertNotEqual(first, third)
        XCTAssertTrue(first.hasPrefix("/tmp/swift_unused_deps_index_store_"))
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
