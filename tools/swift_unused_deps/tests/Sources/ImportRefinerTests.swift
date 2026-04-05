import XCTest
@testable import SwiftUnusedDepsLib

final class ImportRefinerTests: XCTestCase {

    func testUnusedImportFiltered() {
        let loaded = [
            LoadedModule(name: "UsedModule", isImportedDirectly: true),
            LoadedModule(name: "UnusedModule", isImportedDirectly: true),
        ]
        let usage = [
            SourceFileModuleUsage(
                sourceFile: "/src/MyView.swift",
                moduleName: "MyTarget",
                referencedModules: ["UsedModule"]
            ),
        ]

        let result = ImportRefiner.refine(
            loadedModules: loaded,
            targetModuleName: "MyTarget",
            indexStoreUsage: usage
        )

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].name, "UsedModule")
    }

    func testIndirectModulesPreserved() {
        let loaded = [
            LoadedModule(name: "DirectUsed", isImportedDirectly: true),
            LoadedModule(name: "IndirectLoaded", isImportedDirectly: false),
        ]
        let usage = [
            SourceFileModuleUsage(
                sourceFile: "/src/File.swift",
                moduleName: "Target",
                referencedModules: ["DirectUsed"]
            ),
        ]

        let result = ImportRefiner.refine(
            loadedModules: loaded,
            targetModuleName: "Target",
            indexStoreUsage: usage
        )

        XCTAssertEqual(result.count, 2)
    }

    func testEmptyIndexStorePreservesAll() {
        let loaded = [
            LoadedModule(name: "A", isImportedDirectly: true),
            LoadedModule(name: "B", isImportedDirectly: true),
        ]

        let result = ImportRefiner.refine(
            loadedModules: loaded,
            targetModuleName: "Target",
            indexStoreUsage: []
        )

        XCTAssertEqual(result.count, 2)
    }

    func testNoMatchingModulePreservesAll() {
        let loaded = [
            LoadedModule(name: "A", isImportedDirectly: true),
        ]
        let usage = [
            SourceFileModuleUsage(
                sourceFile: "/src/Other.swift",
                moduleName: "DifferentModule",
                referencedModules: ["X"]
            ),
        ]

        let result = ImportRefiner.refine(
            loadedModules: loaded,
            targetModuleName: "Target",
            indexStoreUsage: usage
        )

        XCTAssertEqual(result.count, 1)
    }

    func testAllModulesUsed() {
        let loaded = [
            LoadedModule(name: "A", isImportedDirectly: true),
            LoadedModule(name: "B", isImportedDirectly: true),
        ]
        let usage = [
            SourceFileModuleUsage(
                sourceFile: "/src/File.swift",
                moduleName: "Target",
                referencedModules: ["A", "B"]
            ),
        ]

        let result = ImportRefiner.refine(
            loadedModules: loaded,
            targetModuleName: "Target",
            indexStoreUsage: usage
        )

        XCTAssertEqual(result.count, 2)
    }

    func testMultipleSourceFiles() {
        let loaded = [
            LoadedModule(name: "A", isImportedDirectly: true),
            LoadedModule(name: "B", isImportedDirectly: true),
        ]
        let usage = [
            SourceFileModuleUsage(
                sourceFile: "/src/File1.swift",
                moduleName: "Target",
                referencedModules: ["A"]
            ),
            SourceFileModuleUsage(
                sourceFile: "/src/File2.swift",
                moduleName: "Target",
                referencedModules: ["B"]
            ),
        ]

        let result = ImportRefiner.refine(
            loadedModules: loaded,
            targetModuleName: "Target",
            indexStoreUsage: usage
        )

        XCTAssertEqual(result.count, 2)
    }
}
