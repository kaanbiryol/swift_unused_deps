import XCTest
@testable import SwiftUnusedDepsLib

final class ConformanceImportPreserverTests: XCTestCase {

    func testConformanceDeclarationsParseMultilineExtensions() {
        let declarations = ConformanceImportPreserver.conformanceDeclarations(in: """
        extension Namespace.SemanticToken:
            SemanticRenderable,
            AnotherProtocol
        where Namespace.SemanticToken: Sendable {
        }
        """)

        XCTAssertEqual(declarations.map(\.typeName), [
            "Namespace.SemanticToken",
            "Namespace.SemanticToken",
        ])
        XCTAssertEqual(declarations.map(\.protocolName), [
            "SemanticRenderable",
            "AnotherProtocol",
        ])
    }
}
