import XCTest
@testable import SwiftUnusedDepsLib

final class TargetFilterTests: XCTestCase {

    func testMatchesCanonicalRepoLabelPrefix() {
        let filter = TargetFilter("@@//App/Features/Login...")

        XCTAssertTrue(filter.matches(label: "@@//App/Features/Login:Login"))
        XCTAssertTrue(filter.matches(label: "//App/Features/Login/Subfeature:Child"))
    }

    func testExactTargetDoesNotMatchPrefixSibling() {
        let filter = TargetFilter("//App:App")

        XCTAssertTrue(filter.matches(label: "@@//App:App"))
        XCTAssertFalse(filter.matches(label: "//App:AppTests"))
    }

    func testExactShorthandTargetMatchesExplicitTargetName() {
        let filter = TargetFilter("//cases/Targets/CleanTarget")

        XCTAssertTrue(filter.matches(label: "//cases/Targets/CleanTarget:CleanTarget"))
        XCTAssertFalse(filter.matches(label: "//cases/Targets/CleanTarget:Other"))
    }

    func testExactExternalShorthandTargetMatchesExplicitTargetName() {
        let filter = TargetFilter("@repo//pkg/Lib")

        XCTAssertTrue(filter.matches(label: "@@repo//pkg/Lib:Lib"))
    }

    func testDoesNotMatchDifferentSubtree() {
        let filter = TargetFilter("//App/Features/Login...")

        XCTAssertFalse(filter.matches(label: "//App/Features/Profile:Profile"))
    }

    func testRecursivePatternMatchesRootPackageTarget() {
        let filter = TargetFilter("//App/...")

        XCTAssertTrue(filter.matches(label: "//App:App"))
        XCTAssertTrue(filter.matches(label: "//App/Features/Login:Login"))
    }

    func testRecursivePatternDoesNotMatchPrefixSibling() {
        let filter = TargetFilter("//App/...")

        XCTAssertFalse(filter.matches(label: "//Application:Application"))
    }

    func testRootRecursivePatternMatchesWorkspaceTargets() {
        let filter = TargetFilter("//...")

        XCTAssertTrue(filter.matches(label: "//:root"))
        XCTAssertTrue(filter.matches(label: "//App:App"))
        XCTAssertTrue(filter.matches(label: "//App/Features:Features"))
    }

    func testNormalizeTrimsWhitespaceAndRepoMarker() {
        XCTAssertEqual(
            TargetFilter.normalize("  @@//App/Features/Login...  "),
            "//App/Features/Login"
        )
    }
}
