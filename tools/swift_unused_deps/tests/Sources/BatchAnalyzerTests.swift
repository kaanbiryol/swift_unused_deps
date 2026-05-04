import Foundation
import XCTest
@testable import SwiftUnusedDepsLib

final class BatchAnalyzerTests: XCTestCase {

    func testDeriveLoadedModulesKeepsDirectImportsWithoutReferencedSymbols() {
        let modules = BatchAnalyzer.deriveLoadedModules(
            from: [
                SourceFileModuleUsage(
                    sourceFile: "A.swift",
                    moduleName: "A",
                    referencedModules: [],
                    loadedModules: ["LibA", "LibB"],
                    directImports: ["LibA", "LibB"]
                ),
            ]
        )

        XCTAssertEqual(modules, [
            LoadedModule(name: "LibA", isImportedDirectly: true),
            LoadedModule(name: "LibB", isImportedDirectly: true),
        ])
    }

    func testDeriveLoadedModulesMarksSystemModules() {
        let modules = BatchAnalyzer.deriveLoadedModules(
            from: [
                SourceFileModuleUsage(
                    sourceFile: "A.swift",
                    moduleName: "A",
                    referencedModules: ["LibA"],
                    loadedModules: ["Foundation", "LibA"],
                    systemModules: ["Foundation"],
                    directImports: ["Foundation", "LibA"]
                ),
            ]
        )

        XCTAssertEqual(modules, [
            LoadedModule(name: "Foundation", isImportedDirectly: true, isSystem: true),
            LoadedModule(name: "LibA", isImportedDirectly: true),
        ])
    }

    func testUnusedImportIssuesRequireRemovingSourceAndDep() {
        let metadata = makeMetadata(
            label: "//Lib:A",
            moduleName: "A",
            deps: [DeclaredDep(label: "//Lib:LibA", moduleName: "LibA", kind: .dep)]
        )

        let issues = BatchAnalyzer.unusedImportIssues(
            metadata: metadata,
            sourceFileUsage: [
                SourceFileModuleUsage(
                    sourceFile: "/tmp/A.swift",
                    moduleName: "A",
                    referencedModules: [],
                    loadedModules: ["LibA"],
                    directImports: ["LibA"]
                ),
            ]
        )

        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues[0].kind, .unusedImport)
        XCTAssertEqual(issues[0].depLabel, "//Lib:LibA")
        XCTAssertEqual(issues[0].sourceImportRemovals, [
            SourceImportRemoval(filePath: "/tmp/A.swift", moduleName: "LibA"),
        ])
    }

    func testUnusedImportIssuesSkipReexportedImports() {
        let metadata = makeMetadata(
            label: "//Lib:A",
            moduleName: "A",
            deps: [DeclaredDep(label: "//Lib:LibA", moduleName: "LibA", kind: .dep)]
        )

        let issues = BatchAnalyzer.unusedImportIssues(
            metadata: metadata,
            sourceFileUsage: [
                SourceFileModuleUsage(
                    sourceFile: "/tmp/A.swift",
                    moduleName: "A",
                    referencedModules: [],
                    loadedModules: ["LibA"],
                    directImports: ["LibA"],
                    reexportedImports: ["LibA"]
                ),
            ]
        )

        XCTAssertTrue(issues.isEmpty)
    }

    func testAnalyzeWarnsOnInvalidIndexStorePathAndSkipsTarget() throws {
        try withTemporaryDirectory { directory in
            try writeMetadata(
                to: directory,
                metadata: makeMetadata(label: "//Lib:A", moduleName: "A")
            )

            let output = BatchAnalyzer.analyze(options: .init(
                bazelBin: directory.path,
                indexStorePath: "/nonexistent/index-store"
            ))

            XCTAssertTrue(output.results.isEmpty)
            XCTAssertTrue(output.warnings.contains { $0.contains("Failed to read index store") })
            XCTAssertTrue(output.warnings.contains { $0.contains("No index-store data found") })
        }
    }

    func testAnalyzeWarnsAndSkipsTargetWhenIndexStoreDataIsMissing() throws {
        try withTemporaryDirectory { directory in
            try writeMetadata(
                to: directory,
                metadata: makeMetadata(
                    label: "//Lib:A",
                    moduleName: "A",
                    deps: [DeclaredDep(label: "//Lib:B", moduleName: "B", kind: .dep)],
                    transitiveModuleMap: ["B": "//Lib:B"]
                )
            )

            let output = BatchAnalyzer.analyze(options: .init(bazelBin: directory.path))

            XCTAssertTrue(output.results.isEmpty)
            XCTAssertEqual(output.warnings.count, 1)
            XCTAssertTrue(output.warnings[0].contains("No index-store data found"))
        }
    }

    private func makeMetadata(
        label: String,
        moduleName: String,
        deps: [DeclaredDep] = [],
        transitiveModuleMap: [String: String] = [:],
        srcs: [String] = ["A.swift"]
    ) -> TargetMetadata {
        TargetMetadata(
            schemaVersion: 1,
            target: TargetInfo(label: label, moduleName: moduleName, srcs: srcs),
            declaredDeps: deps,
            transitiveModuleMap: transitiveModuleMap
        )
    }

    private func writeMetadata(
        to directory: URL,
        metadata: TargetMetadata
    ) throws {
        let metadataURL = directory.appendingPathComponent("\(metadata.target.moduleName).swift_deps_info.json")
        try JSONEncoder().encode(metadata).write(to: metadataURL)
    }

    private func withTemporaryDirectory(
        _ body: (URL) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }
}
