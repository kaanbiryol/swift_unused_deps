import XCTest
@testable import SwiftUnusedDepsLib

final class ModuleResolverTests: XCTestCase {

    var resolver: ModuleResolver!

    override func setUp() {
        resolver = ModuleResolver(transitiveModuleMap: [
            "Networking": "//App/Core/Networking:Networking",
            "Analytics": "//App/Core/Analytics:Analytics",
            "AppLogger": "//App/Core/Logger:Logger",
        ])
    }

    func testResolveKnownModule() {
        let result = resolver.resolve("Networking")
        XCTAssertEqual(result.status, .resolved(label: "//App/Core/Networking:Networking"))
    }

    func testResolveModuleWithDifferentName() {
        let result = resolver.resolve("AppLogger")
        XCTAssertEqual(result.status, .resolved(label: "//App/Core/Logger:Logger"))
    }

    func testResolveUnknownModule() {
        let result = resolver.resolve("SomeUnknownModule")
        XCTAssertEqual(result.status, .unresolved)
    }

    func testExtraSystemModules() {
        let r = ModuleResolver(
            transitiveModuleMap: [:],
            extraSystemModules: ["CustomSDKModule"]
        )
        XCTAssertEqual(r.resolve("CustomSDKModule").status, .system)
    }

    func testUserModuleNotConfusedWithSystem() {
        let r = ModuleResolver(transitiveModuleMap: [
            "SwiftProtobuf": "//ThirdParty:SwiftProtobuf",
        ])
        XCTAssertEqual(r.resolve("SwiftProtobuf").status, .resolved(label: "//ThirdParty:SwiftProtobuf"))
    }

    func testIsSystemModule() {
        let resolver = ModuleResolver(transitiveModuleMap: [:], extraSystemModules: ["Foundation"])
        XCTAssertTrue(resolver.isSystemModule("Foundation"))
        XCTAssertFalse(resolver.isSystemModule("Networking"))
    }
}
