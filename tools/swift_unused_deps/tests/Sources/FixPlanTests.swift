import Foundation
import XCTest
@testable import SwiftUnusedDepsLib

final class FixPlanTests: XCTestCase {

    func testBuildEditParsesBuildozerCommands() {
        XCTAssertEqual(
            BuildEdit.from(command: BuildozerCommand(action: "remove deps //Lib:B", target: "//App:A")),
            BuildEdit(operation: .remove, attribute: "deps", label: "//Lib:B", target: "//App:A")
        )
        XCTAssertEqual(
            BuildEdit.from(command: BuildozerCommand(action: "add deps //Lib:B", target: "//App:A")),
            BuildEdit(operation: .add, attribute: "deps", label: "//Lib:B", target: "//App:A")
        )
        XCTAssertEqual(
            BuildEdit.from(command: BuildozerCommand(action: "move deps private_deps //Lib:B", target: "//App:A")),
            BuildEdit(
                operation: .move,
                attribute: "deps",
                label: "//Lib:B",
                target: "//App:A",
                destinationAttribute: "private_deps"
            )
        )
    }

    func testBuildEditSkipsExternalTargets() {
        XCTAssertNil(
            BuildEdit.from(command: BuildozerCommand(action: "add deps //Lib:B", target: "@repo//App:A"))
        )
        XCTAssertNil(
            BuildEdit.from(command: BuildozerCommand(action: "add deps //Lib:B", target: "@@repo+//App:A"))
        )
    }

    func testFixPlanContainsHighConfidenceBuildAndSourceEdits() throws {
        let unusedDep = DeclaredDep(label: "//Lib:Unused", moduleName: "Unused", kind: .dep)
        let importedDep = DeclaredDep(label: "//Lib:Imported", moduleName: "Imported", kind: .dep)
        let candidateDep = DeclaredDep(label: "//Lib:Candidate", moduleName: "Candidate", kind: .dep)
        let result = AnalysisResult(
            target: "//App:App",
            moduleName: "App",
            issues: [
                .unusedDep(unusedDep, targetLabel: "//App:App"),
                .unusedImport(
                    importedDep,
                    targetLabel: "//App:App",
                    sourceImportRemovals: [
                        SourceImportRemoval(filePath: "App/App.swift", moduleName: "Imported"),
                    ]
                ),
                .candidatePrivateDep(candidateDep, targetLabel: "//App:App"),
            ],
            cleanDeps: [],
            skippedModules: []
        )

        let plan = FixPlan.from(results: [result])

        XCTAssertEqual(plan.sourceImportRemovals, [
            SourceImportRemoval(filePath: "App/App.swift", moduleName: "Imported"),
        ])
        XCTAssertEqual(plan.buildEdits, [
            BuildEdit(operation: .remove, attribute: "deps", label: "//Lib:Imported", target: "//App:App"),
            BuildEdit(operation: .remove, attribute: "deps", label: "//Lib:Unused", target: "//App:App"),
        ])

        let json = try FixPlan.formatJSON(plan)
        let decoded = try JSONDecoder().decode(FixPlan.self, from: Data(json.utf8))
        XCTAssertEqual(decoded, plan)
    }

    func testFixPlanCanIncludeLowConfidenceBuildEdits() {
        let candidateDep = DeclaredDep(label: "//Lib:Candidate", moduleName: "Candidate", kind: .dep)
        let result = AnalysisResult(
            target: "//App:App",
            moduleName: "App",
            issues: [
                .candidatePrivateDep(candidateDep, targetLabel: "//App:App"),
            ],
            cleanDeps: [],
            skippedModules: []
        )

        let plan = FixPlan.from(results: [result], minConfidence: .low)

        XCTAssertEqual(plan.sourceImportRemovals, [])
        XCTAssertEqual(plan.buildEdits, [
            BuildEdit(
                operation: .move,
                attribute: "deps",
                label: "//Lib:Candidate",
                target: "//App:App",
                destinationAttribute: "private_deps"
            ),
        ])
    }

    func testFixPlanSkipsExternalTargetIssues() {
        let result = AnalysisResult(
            target: "@swiftpkg_package//:Package",
            moduleName: "Package",
            issues: [
                .missingDirectDep(
                    depLabel: "@swiftpkg_other//:Other",
                    moduleName: "Other",
                    currentlyReachableVia: [],
                    isImportedDirectly: true,
                    targetLabel: "@swiftpkg_package//:Package"
                ),
                .unusedImport(
                    DeclaredDep(label: "@swiftpkg_unused//:Unused", moduleName: "Unused", kind: .dep),
                    targetLabel: "@swiftpkg_package//:Package",
                    sourceImportRemovals: [
                        SourceImportRemoval(filePath: "external/package/File.swift", moduleName: "Unused"),
                    ]
                ),
            ],
            cleanDeps: [],
            skippedModules: []
        )

        let plan = FixPlan.from(results: [result])

        XCTAssertTrue(plan.buildEdits.isEmpty)
        XCTAssertTrue(plan.sourceImportRemovals.isEmpty)
    }

    func testFixPlanSummaryListsBuildAndSourceChanges() {
        let plan = FixPlan(
            sourceImportRemovals: [
                SourceImportRemoval(filePath: "App/App.swift", moduleName: "LibA"),
            ],
            buildEdits: [
                BuildEdit(operation: .remove, attribute: "deps", label: "//Lib:A", target: "//App:App"),
                BuildEdit(operation: .add, attribute: "deps", label: "//Lib:B", target: "//App:App"),
                BuildEdit(
                    operation: .move,
                    attribute: "deps",
                    label: "//Lib:C",
                    target: "//App:App",
                    destinationAttribute: "private_deps"
                ),
            ]
        )

        XCTAssertEqual(
            FixPlan.formatSummary(plan),
            """
            Planned fixes:
              BUILD edits:
                add //Lib:B to deps of //App:App
                move //Lib:C from deps to private_deps of //App:App
                remove //Lib:A from deps of //App:App
              Source import removals:
                remove import LibA from App/App.swift
            """
        )
    }

    func testApplierCanApplySourceOnlyPlan() throws {
        let workspace = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let sourceURL = workspace.appendingPathComponent("App.swift")
        try """
        import LibA
        import LibB

        public struct App {}
        """.write(to: sourceURL, atomically: true, encoding: .utf8)

        let plan = FixPlan(
            sourceImportRemovals: [
                SourceImportRemoval(filePath: "App.swift", moduleName: "LibA"),
            ],
            buildEdits: []
        )

        let result = try FixPlanApplier.apply(plan, workspaceDirectory: workspace)
        let updated = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(result.applied)
        XCTAssertFalse(updated.contains("import LibA"))
        XCTAssertTrue(updated.contains("import LibB"))
    }

    func testApplierSkipsAlreadyAppliedFixPlan() throws {
        let workspace = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let appDirectory = workspace.appendingPathComponent("App", isDirectory: true)
        try FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        try """
        load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

        swift_library(
            name = "App",
            srcs = ["App.swift"],
            deps = [
                "//Lib:Existing",
            ],
            private_deps = [
                "//Lib:Moved",
            ],
        )
        """.write(to: appDirectory.appendingPathComponent("BUILD.bazel"), atomically: true, encoding: .utf8)

        let sourceURL = appDirectory.appendingPathComponent("App.swift")
        let originalSource = """
        import Existing

        public struct App {}
        """
        try originalSource.write(to: sourceURL, atomically: true, encoding: .utf8)

        let plan = FixPlan(
            sourceImportRemovals: [
                SourceImportRemoval(filePath: "App/App.swift", moduleName: "AlreadyRemoved"),
            ],
            buildEdits: [
                BuildEdit(operation: .add, attribute: "deps", label: "//Lib:Existing", target: "//App:App"),
                BuildEdit(operation: .remove, attribute: "deps", label: "//Lib:AlreadyRemoved", target: "//App:App"),
                BuildEdit(
                    operation: .move,
                    attribute: "deps",
                    label: "//Lib:Moved",
                    target: "//App:App",
                    destinationAttribute: "private_deps"
                ),
            ]
        )

        let result = try FixPlanApplier.apply(plan, workspaceDirectory: workspace)
        let updatedSource = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertFalse(result.applied)
        XCTAssertEqual(result.buildFixCount, 0)
        XCTAssertEqual(result.sourceImportRemovalCount, 0)
        XCTAssertEqual(updatedSource, originalSource)
    }

    func testApplierCountsOnlyPresentSourceImports() throws {
        let workspace = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let sourceURL = workspace.appendingPathComponent("App.swift")
        try """
        import LibA
        import LibB

        public struct App {}
        """.write(to: sourceURL, atomically: true, encoding: .utf8)

        let plan = FixPlan(
            sourceImportRemovals: [
                SourceImportRemoval(filePath: "App.swift", moduleName: "AlreadyRemoved"),
                SourceImportRemoval(filePath: "App.swift", moduleName: "LibA"),
            ],
            buildEdits: []
        )

        let result = try FixPlanApplier.apply(plan, workspaceDirectory: workspace)
        let updated = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(result.applied)
        XCTAssertEqual(result.sourceImportRemovalCount, 1)
        XCTAssertFalse(updated.contains("import LibA"))
        XCTAssertTrue(updated.contains("import LibB"))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
