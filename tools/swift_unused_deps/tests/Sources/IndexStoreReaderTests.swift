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

        let result = try IndexStoreReader.readModuleUsage(
            storePath: tmpDir.path,
            filterModules: ["SomeModule"]
        )
        XCTAssertTrue(result.usage.isEmpty)
        XCTAssertTrue(result.indexedModules.isEmpty)
    }

    func testModuleNameFromSwiftUSRReadsModulePayload() {
        XCTAssertEqual(
            IndexStoreReader.moduleName(
                fromUSR: "s:14ArgumentParser8ExitCodeVyACs5Int32Vcfc"
            ),
            "ArgumentParser"
        )
    }

    func testModuleNameFromClangModuleUSRReadsModuleName() {
        XCTAssertEqual(
            IndexStoreReader.moduleName(
                fromUSR: "c:@M@Foundation"
            ),
            "Foundation"
        )
    }

    func testModuleNameFromSwiftExtensionUSRScansForModulePayload() {
        XCTAssertEqual(
            IndexStoreReader.moduleName(
                fromUSR: "s:e:s:13TransitiveDep4UserV"
            ),
            "TransitiveDep"
        )
    }

    func testModuleNameFromUSRRejectsUnknownFormat() {
        XCTAssertNil(
            IndexStoreReader.moduleName(
                fromUSR: "not-a-swift-or-clang-module-usr"
            )
        )
    }
}
