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

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
