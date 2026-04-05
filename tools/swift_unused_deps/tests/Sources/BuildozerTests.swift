import XCTest
@testable import SwiftUnusedDepsLib

final class BuildozerTests: XCTestCase {

    func testRunBatchFailsCleanlyWhenBinaryIsMissing() {
        let result = Buildozer.runBatch(commands: [
            BuildozerCommand(action: "remove deps //Lib:B", target: "//App:A"),
        ])

        XCTAssertFalse(result.success)
        XCTAssertTrue(result.output.contains("buildozer not found"))
    }

    func testRunBatchRejectsUnsafeBatchInput() {
        let result = Buildozer.runBatch(commands: [
            BuildozerCommand(action: "remove deps //Lib:B", target: "//App:A\n//Injected:Target"),
        ])

        XCTAssertFalse(result.success)
        XCTAssertTrue(result.output.contains("Refusing to execute invalid buildozer command"))
    }
}
