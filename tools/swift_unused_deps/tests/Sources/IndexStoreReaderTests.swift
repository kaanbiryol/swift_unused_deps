import XCTest
@testable import SwiftUnusedDepsLib

final class IndexStoreReaderTests: XCTestCase {

    func testReadModuleUsageWithInvalidPath() {
        XCTAssertThrowsError(
            try IndexStoreReader.readModuleUsage(storePath: "/nonexistent/path")
        )
    }

    func testReadModuleUsageWithFilterReturnsEmpty() throws {
        // An empty directory won't have any units, so filtering should return empty.
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let results = try IndexStoreReader.readModuleUsage(
            storePath: tmpDir.path,
            filterModules: ["SomeModule"]
        )
        XCTAssertTrue(results.isEmpty)
    }
}
