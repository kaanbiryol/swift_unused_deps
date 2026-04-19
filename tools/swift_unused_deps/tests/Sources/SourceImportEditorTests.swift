import XCTest
@testable import SwiftUnusedDepsLib

final class SourceImportEditorTests: XCTestCase {

    func testRemoveImportsDeletesMatchingImportLinesOnly() throws {
        let source = """
        import Foundation
        import LibA // comment
        @_implementationOnly import LibB
        import LibC

        struct Demo {}
        """

        let updated = try SourceImportEditor.removeImports(
            in: source,
            filePath: "/tmp/Demo.swift",
            moduleNames: ["LibA", "LibB"]
        )

        XCTAssertEqual(updated, """
        import Foundation
        import LibC

        struct Demo {}
        """)
    }

    func testRemoveImportsDeletesTestableAndScopedImportLines() throws {
        let source = """
        @testable import LibA
        import struct LibB.Button
        import LibC

        struct Demo {}
        """

        let updated = try SourceImportEditor.removeImports(
            in: source,
            filePath: "/tmp/Demo.swift",
            moduleNames: ["LibA", "LibB"]
        )

        XCTAssertEqual(updated, """
        import LibC

        struct Demo {}
        """)
    }

    func testImportedModuleNamesParsesAttributedAndScopedImports() {
        let source = """
        @_spi(Testing) import LibA
        import struct LibB.Button
        import class LibC.ImageLoader
        import Foundation
        """

        XCTAssertEqual(
            SourceImportEditor.importedModuleNames(in: source),
            ["Foundation", "LibA", "LibB", "LibC"]
        )
    }

    func testImportLineNumbersTrackAttributedAndScopedImports() {
        let source = """
        import Foundation

        @testable import LibA
        let value = 1
        import struct LibB.Button
        """

        XCTAssertEqual(SourceImportEditor.importLineNumbers(in: source), [1, 3, 5])
    }

    func testRemoveImportsPreservesBlankLinesAndCommentsAroundRemovedImport() throws {
        let source = """
        import Foundation

        // Keep this comment with the surrounding declaration.
        import struct LibA.Tracker // remove me

        import LibB

        struct Demo {}
        """

        let updated = try SourceImportEditor.removeImports(
            in: source,
            filePath: "/tmp/Demo.swift",
            moduleNames: ["LibA"]
        )

        XCTAssertEqual(updated, """
        import Foundation

        // Keep this comment with the surrounding declaration.

        import LibB

        struct Demo {}
        """)
    }

    func testRemoveImportsFailsWhenImportMissing() {
        XCTAssertThrowsError(
            try SourceImportEditor.removeImports(
                in: "import Foundation\n",
                filePath: "/tmp/Demo.swift",
                moduleNames: ["LibA"]
            )
        ) { error in
            XCTAssertTrue("\(error)".contains("Did not find an import for module 'LibA'"))
        }
    }

    func testApplyResolvesRelativePathsAgainstWorkspaceDirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = directory.appendingPathComponent("Demo.swift")
        try """
        import LibA
        import LibB
        """.write(to: sourceURL, atomically: true, encoding: .utf8)

        try SourceImportEditor.apply(
            removals: [SourceImportRemoval(filePath: "Demo.swift", moduleName: "LibA")],
            workspaceDirectory: directory
        )

        XCTAssertEqual(try String(contentsOf: sourceURL, encoding: .utf8), "import LibB")
    }
}
