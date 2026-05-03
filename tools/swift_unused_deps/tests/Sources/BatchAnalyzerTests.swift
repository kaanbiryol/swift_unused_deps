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

    func testAnalyzeWarnsOnInvalidIndexStorePath() throws {
        try withTemporaryDirectory { directory in
            try writeTarget(
                to: directory,
                metadata: makeMetadata(
                    label: "//Lib:A",
                    moduleName: "A"
                ),
                traceContents: """
                {"version":2,"name":"A","arch":"arm64","swiftmodules":[]}
                """
            )

            let output = BatchAnalyzer.analyze(options: .init(
                bazelBin: directory.path,
                indexStorePath: "/nonexistent/index-store"
            ))

            XCTAssertEqual(output.results.count, 1)
            XCTAssertTrue(output.warnings.contains { $0.contains("Failed to read index store") })
        }
    }

    func testAnalyzeDoesNotSkipValidEmptyTrace() throws {
        try withTemporaryDirectory { directory in
            try writeTarget(
                to: directory,
                metadata: makeMetadata(
                    label: "//Lib:A",
                    moduleName: "A",
                    deps: [DeclaredDep(label: "//Lib:B", moduleName: "B", kind: .dep)],
                    transitiveModuleMap: ["B": "//Lib:B"]
                ),
                traceContents: """
                {"version":2,"name":"A","arch":"arm64","swiftmodules":[]}
                """
            )

            let output = BatchAnalyzer.analyze(options: .init(bazelBin: directory.path))

            XCTAssertEqual(output.warnings.count, 0)
            XCTAssertEqual(output.results.count, 1)
            let issues = output.results[0].issues.filter { $0.kind == .unusedDep }
            XCTAssertEqual(issues.count, 1)
            XCTAssertEqual(issues[0].depLabel, "//Lib:B")
        }
    }

    func testAnalyzeUsesTraceFilePathFromMetadata() throws {
        try withTemporaryDirectory { directory in
            try writeTarget(
                to: directory,
                metadata: makeMetadata(
                    label: "//Lib:A",
                    moduleName: "A",
                    deps: [DeclaredDep(label: "//Lib:B", moduleName: "B", kind: .dep)],
                    transitiveModuleMap: ["B": "//Lib:B"],
                    traceFile: "nested/custom.trace.json"
                ),
                traceContents: """
                {"version":2,"name":"A","arch":"arm64","swiftmodulesDetailedInfo":[{"name":"B","path":"/out/B.swiftmodule","isImportedDirectly":true}]}
                """
            )

            let output = BatchAnalyzer.analyze(options: .init(bazelBin: directory.path))

            XCTAssertEqual(output.warnings.count, 0)
            XCTAssertEqual(output.results.count, 1)
            XCTAssertTrue(output.results[0].issues.isEmpty)
        }
    }

    func testAnalyzeWarnsAndSkipsInvalidTrace() throws {
        try withTemporaryDirectory { directory in
            try writeTarget(
                to: directory,
                metadata: makeMetadata(
                    label: "//Lib:A",
                    moduleName: "A",
                    deps: [DeclaredDep(label: "//Lib:B", moduleName: "B", kind: .dep)],
                    transitiveModuleMap: ["B": "//Lib:B"]
                ),
                traceContents: "{invalid json"
            )

            let output = BatchAnalyzer.analyze(options: .init(bazelBin: directory.path))

            XCTAssertTrue(output.results.isEmpty)
            XCTAssertEqual(output.warnings.count, 1)
            XCTAssertTrue(output.warnings[0].contains("Failed to parse trace"))
        }
    }

    func testAnalyzeUsesProvidedWorkspaceToDisambiguateBuildFileLabels() throws {
        try withTemporaryDirectory { directory in
            let bazelBin = directory.appendingPathComponent("bazel-bin", isDirectory: true)
            let workspace = directory.appendingPathComponent("workspace", isDirectory: true)
            let packageDirectory = workspace.appendingPathComponent("Lib", isDirectory: true)
            try FileManager.default.createDirectory(at: bazelBin, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: packageDirectory, withIntermediateDirectories: true)
            try """
            swift_library(
                name = "A",
                deps = ["@right//:B"],
            )
            """.write(
                to: packageDirectory.appendingPathComponent("BUILD.bazel"),
                atomically: true,
                encoding: .utf8
            )

            try writeTarget(
                to: bazelBin,
                metadata: makeMetadata(
                    label: "//Lib:A",
                    moduleName: "A",
                    deps: [DeclaredDep(label: "@@repo+//:B", moduleName: "B", kind: .dep)],
                    transitiveModuleMap: ["B": "@@repo+//:B"]
                ),
                traceContents: """
                {"version":2,"name":"A","arch":"arm64","swiftmodules":[]}
                """
            )

            let output = BatchAnalyzer.analyze(options: .init(
                bazelBin: bazelBin.path,
                labelConverter: LabelConverter(canonicalToApparent: ["repo+": ["wrong", "right"]]),
                workspaceDirectory: workspace
            ))

            XCTAssertEqual(output.warnings.count, 0)
            XCTAssertEqual(output.results.count, 1)
            let issue = try XCTUnwrap(output.results[0].issues.first { $0.kind == .unusedDep })
            XCTAssertEqual(issue.depLabel, "@right//:B")
            XCTAssertEqual(issue.buildozerCommand?.displayString, "buildozer 'remove deps @right//:B' //Lib:A")
        }
    }

    private func makeMetadata(
        label: String,
        moduleName: String,
        deps: [DeclaredDep] = [],
        transitiveModuleMap: [String: String] = [:],
        srcs: [String] = ["A.swift"],
        traceFile: String? = nil
    ) -> TargetMetadata {
        TargetMetadata(
            schemaVersion: 1,
            target: TargetInfo(label: label, moduleName: moduleName, srcs: srcs),
            declaredDeps: deps,
            transitiveModuleMap: transitiveModuleMap,
            traceFile: traceFile ?? "\(moduleName).trace.json"
        )
    }

    private func writeTarget(
        to directory: URL,
        metadata: TargetMetadata,
        traceContents: String
    ) throws {
        let metadataURL = directory.appendingPathComponent("\(metadata.target.moduleName).swift_deps_info.json")
        let traceURL = directory.appendingPathComponent(metadata.traceFile)

        let encoder = JSONEncoder()
        try encoder.encode(metadata).write(to: metadataURL)
        try FileManager.default.createDirectory(
            at: traceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try traceContents.write(to: traceURL, atomically: true, encoding: .utf8)
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
