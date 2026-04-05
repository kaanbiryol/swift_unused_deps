import XCTest
@testable import SwiftUnusedDepsLib

final class TraceParserTests: XCTestCase {

    func testFlatSwiftmodule() {
        XCTAssertEqual(TraceParser.extractModuleName(from: "/path/to/Foo.swiftmodule"), "Foo")
    }

    func testDirectorySwiftmodule() {
        XCTAssertEqual(
            TraceParser.extractModuleName(from: "/path/to/Foo.swiftmodule/arm64-apple-ios.swiftmodule"),
            "Foo"
        )
    }

    func testProjectSubdirectory() {
        XCTAssertEqual(
            TraceParser.extractModuleName(from: "/path/to/Foo.swiftmodule/Project/arm64-apple-ios.swiftmodule"),
            "Foo"
        )
    }

    func testBazelOutPath() {
        XCTAssertEqual(
            TraceParser.extractModuleName(from: "/bazel-out/ios-arm64/bin/Lib/Networking.swiftmodule/arm64-apple-ios.swiftmodule"),
            "Networking"
        )
    }

    func testSystemModulePath() {
        XCTAssertEqual(
            TraceParser.extractModuleName(from: "/usr/lib/swift/Foundation.swiftmodule/arm64-apple-ios.swiftmodule"),
            "Foundation"
        )
    }

    func testPCMReturnsNil() {
        XCTAssertNil(TraceParser.extractModuleName(from: "/path/to/some.pcm"))
    }

    func testOnlyArchSlugReturnsNil() {
        XCTAssertNil(TraceParser.extractModuleName(from: "/arm64-apple-ios.swiftmodule"))
    }

    func testVersion2WithDirectImports() throws {
        let json = """
        {
            "version": 2,
            "name": "MyLib",
            "arch": "arm64-apple-ios16.0",
            "swiftmodules": [
                {"path": "/out/Dep1.swiftmodule/arm64-apple-ios.swiftmodule", "isImportedDirectly": true},
                {"path": "/out/Dep2.swiftmodule/arm64-apple-ios.swiftmodule", "isImportedDirectly": false}
            ]
        }
        """.data(using: .utf8)!

        let modules = try TraceParser.parseTraceData(json)

        XCTAssertEqual(modules.count, 2)
        XCTAssertEqual(modules[0].name, "Dep1")
        XCTAssertTrue(modules[0].isImportedDirectly)
        XCTAssertEqual(modules[1].name, "Dep2")
        XCTAssertFalse(modules[1].isImportedDirectly)
    }

    func testSkipsPCMFiles() throws {
        let json = """
        {
            "version": 2,
            "name": "MyLib",
            "arch": "arm64",
            "swiftmodules": [
                {"path": "/out/SomeClang.pcm", "isImportedDirectly": true},
                {"path": "/out/SwiftDep.swiftmodule/arm64-apple-ios.swiftmodule", "isImportedDirectly": true}
            ]
        }
        """.data(using: .utf8)!

        let modules = try TraceParser.parseTraceData(json)

        XCTAssertEqual(modules.count, 1)
        XCTAssertEqual(modules[0].name, "SwiftDep")
    }

    func testEmptySwiftmodules() throws {
        let json = """
        {"version": 2, "name": "Empty", "arch": "arm64", "swiftmodules": []}
        """.data(using: .utf8)!

        let modules = try TraceParser.parseTraceData(json)
        XCTAssertTrue(modules.isEmpty)
    }
}
