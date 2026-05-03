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

    func testDoesNotMatchDifferentSubtree() {
        let filter = TargetFilter("//App/Features/Login...")

        XCTAssertFalse(filter.matches(label: "//App/Features/Profile:Profile"))
    }

    func testNormalizeTrimsWhitespaceAndRepoMarker() {
        XCTAssertEqual(
            TargetFilter.normalize("  @@//App/Features/Login...  "),
            "//App/Features/Login"
        )
    }
}
