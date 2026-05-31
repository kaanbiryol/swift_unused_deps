import TestSupportLibrary
import XCTest

final class TestSupportLibraryTests: XCTestCase {
    func testTitle() {
        XCTAssertEqual(TestRenderer().title(), "Profile")
    }
}
