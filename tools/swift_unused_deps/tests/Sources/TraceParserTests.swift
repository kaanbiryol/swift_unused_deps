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

    func testDetectsSystemModulePaths() {
        let sdkUIKitPath = "/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform"
            + "/Developer/SDKs/iPhoneOS.sdk/System/Library/Frameworks/UIKit.framework"
            + "/Modules/UIKit.swiftmodule/arm64-apple-ios.swiftmodule"
        let bazelModulePath = "/private/var/tmp/bazel-out/ios-arm64/bin/App"
            + "/LibA.swiftmodule/arm64-apple-ios.swiftmodule"

        XCTAssertTrue(TraceParser.isSystemModulePath(
            "/usr/lib/swift/Foundation.swiftmodule/arm64-apple-ios.swiftmodule"
        ))
        XCTAssertTrue(TraceParser.isSystemModulePath(sdkUIKitPath))
        XCTAssertFalse(TraceParser.isSystemModulePath(bazelModulePath))
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
        XCTAssertFalse(modules[0].isSystem)
        XCTAssertEqual(modules[1].name, "Dep2")
        XCTAssertFalse(modules[1].isImportedDirectly)
        XCTAssertFalse(modules[1].isSystem)
    }

    func testVersion2MarksSystemModulesFromPath() throws {
        let sdkUIKitPath = "/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform"
            + "/Developer/SDKs/iPhoneSimulator.sdk/System/Library/Frameworks/UIKit.framework"
            + "/Modules/UIKit.swiftmodule/arm64-apple-ios.swiftmodule"
        let json = """
        {
            "version": 2,
            "name": "MyLib",
            "arch": "arm64-apple-ios16.0",
            "swiftmodules": [
                {"path": "\(sdkUIKitPath)", "isImportedDirectly": true}
            ]
        }
        """.data(using: .utf8)!

        let modules = try TraceParser.parseTraceData(json)

        XCTAssertEqual(modules, [
            LoadedModule(name: "UIKit", isImportedDirectly: true, isSystem: true),
        ])
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

    func testInvalidSingleTraceThrows() {
        let json = """
        {"name":"Broken"
        """.data(using: .utf8)!

        XCTAssertThrowsError(try TraceParser.parseTraceData(json)) { error in
            XCTAssertTrue("\(error)".contains("not valid loaded-module trace JSON"))
        }
    }

    // MARK: - JSONL (multi-trace) tests

    func testJSONLFiltersByModuleName() throws {
        let line1 = """
        {"version":2,"name":"TargetA","arch":"arm64","swiftmodulesDetailedInfo":[{"name":"DepA","path":"/a.swiftmodule","isImportedDirectly":true}]}
        """
        let line2 = """
        {"version":2,"name":"TargetB","arch":"arm64","swiftmodulesDetailedInfo":[{"name":"DepB","path":"/b.swiftmodule","isImportedDirectly":true}]}
        """
        let url = try writeTempFile(content: line1 + "\n" + line2)
        defer { try? FileManager.default.removeItem(at: url) }

        let modules = try TraceParser.parseTraceFile(at: url, forModule: "TargetA")

        XCTAssertEqual(modules.count, 1)
        XCTAssertEqual(modules[0].name, "DepA")
    }

    func testJSONLMissingRequestedModuleThrows() throws {
        let line1 = """
        {"version":2,"name":"TargetA","arch":"arm64","swiftmodulesDetailedInfo":[{"name":"DepA","path":"/a.swiftmodule","isImportedDirectly":true}]}
        """
        let line2 = """
        {"version":2,"name":"TargetB","arch":"arm64","swiftmodulesDetailedInfo":[{"name":"DepB","path":"/b.swiftmodule","isImportedDirectly":false}]}
        """
        let url = try writeTempFile(content: line1 + "\n" + line2)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try TraceParser.parseTraceFile(at: url, forModule: "NonExistent")) { error in
            XCTAssertTrue("\(error)".contains("does not contain an entry for module 'NonExistent'"))
        }
    }

    private func writeTempFile(content: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".trace.json")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
