import CandidatePrivateDep
import XCTest

final class TraversalRootTests: XCTestCase {
    func testLoadsFeed() {
        CandidatePrivateDep().loadFeed()
    }
}
