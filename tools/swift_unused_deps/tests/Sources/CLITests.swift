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
            ["bazel", "build", "//App:App", "--config=unused-deps-ios"]
        )
    }

    func testRejectsSingleTargetWithBatchFilter() {
        XCTAssertThrowsError(try SwiftUnusedDepsCommand.parseAsRoot([
            "--metadata-file", "meta.json",
            "--trace-file", "trace.json",
            "--output", "out.txt",
            "//App/Features/Login",
        ])) { error in
            XCTAssertTrue("\(error)".contains("Target filter is only supported in batch mode."))
        }
    }

    func testRejectsTraceWithoutMetadata() {
        XCTAssertThrowsError(try SwiftUnusedDepsCommand.parseAsRoot([
            "--trace-file", "trace.json",
        ])) { error in
            XCTAssertTrue("\(error)".contains("--trace-file requires --metadata-file."))
        }
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
