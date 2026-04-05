import Foundation
import XCTest
@testable import SwiftUnusedDepsLib

final class BatchAnalyzerTests: XCTestCase {

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
            transitiveModuleMap: transitiveModuleMap,
            traceFile: "\(moduleName).trace.json"
        )
    }

    private func writeTarget(
        to directory: URL,
        metadata: TargetMetadata,
        traceContents: String
    ) throws {
        let metadataURL = directory.appendingPathComponent("\(metadata.target.moduleName).swift_deps_info.json")
        let traceURL = directory.appendingPathComponent("\(metadata.target.moduleName).trace.json")

        let encoder = JSONEncoder()
        try encoder.encode(metadata).write(to: metadataURL)
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
