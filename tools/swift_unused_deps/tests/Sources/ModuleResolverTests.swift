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
        XCTAssertEqual(
            resolver.resolve("Networking"),
            .resolved(label: "//App/Core/Networking:Networking")
        )
    }

    func testResolveModuleWithDifferentName() {
        XCTAssertEqual(
            resolver.resolve("AppLogger"),
            .resolved(label: "//App/Core/Logger:Logger")
        )
    }

    func testResolveUnknownModule() {
        XCTAssertEqual(resolver.resolve("SomeUnknownModule"), .unresolved)
    }

    func testExtraSystemModules() {
        let r = ModuleResolver(
            transitiveModuleMap: [:],
            extraSystemModules: ["CustomSDKModule"]
        )
        XCTAssertEqual(r.resolve("CustomSDKModule"), .system)
    }

    func testUserModuleNotConfusedWithSystem() {
        let r = ModuleResolver(transitiveModuleMap: [
            "SwiftProtobuf": "//ThirdParty:SwiftProtobuf",
        ])
        XCTAssertEqual(r.resolve("SwiftProtobuf"), .resolved(label: "//ThirdParty:SwiftProtobuf"))
    }
}
