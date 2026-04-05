import XCTest
@testable import SwiftUnusedDepsLib

final class CLITests: XCTestCase {

    func testParseBatchModeWithoutArguments() throws {
        let command = try XCTUnwrap(
            try SwiftUnusedDepsCommand.parseAsRoot([]) as? SwiftUnusedDepsCommand
        )

        XCTAssertNil(command.metadataFile)
        XCTAssertNil(command.traceFile)
        XCTAssertNil(command.output)
        XCTAssertNil(command.filter)
    }

    func testParseBatchModeWithFilter() throws {
        let command = try XCTUnwrap(
            try SwiftUnusedDepsCommand.parseAsRoot([
                "//App/Features/Login...",
            ]) as? SwiftUnusedDepsCommand
        )

        XCTAssertEqual(command.filter, "//App/Features/Login...")
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

    func testRejectsConflictingBatchInputs() {
        XCTAssertThrowsError(try SwiftUnusedDepsCommand.parseAsRoot([
            "--bazel-bin", "bazel-bin",
            "--metadata-dir", "tmp/outputs",
        ])) { error in
            XCTAssertTrue("\(error)".contains("Cannot combine --bazel-bin with --metadata-dir."))
        }
    }
}
