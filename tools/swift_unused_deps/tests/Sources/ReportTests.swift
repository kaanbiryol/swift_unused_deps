import Foundation
import XCTest
@testable import SwiftUnusedDepsLib

final class ReportTests: XCTestCase {

    func testFormatJSONIncludesTypedIssueAndSkippedModuleFields() throws {
        let dep = DeclaredDep(label: "//Lib:B", moduleName: "B", kind: .dep)
        let result = AnalysisResult(
            target: "//Lib:A",
            moduleName: "A",
            issues: [
                Issue.unusedDep(dep, targetLabel: "//Lib:A"),
            ],
            cleanDeps: [dep],
            skippedModules: [
                SkippedModule(name: "Foundation", reason: .systemModule),
            ]
        )

        let json = Report.formatJSON(results: [result], minConfidence: .low)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        let results = try XCTUnwrap(object["results"] as? [[String: Any]])
        let firstResult = try XCTUnwrap(results.first)
        let issues = try XCTUnwrap(firstResult["issues"] as? [[String: Any]])
        let firstIssue = try XCTUnwrap(issues.first)
        let skippedModules = try XCTUnwrap(firstResult["skipped_modules"] as? [[String: Any]])
        let firstSkipped = try XCTUnwrap(skippedModules.first)

        XCTAssertEqual(object["schema_version"] as? Int, 1)
        XCTAssertEqual(firstResult["module_name"] as? String, "A")
        XCTAssertEqual(firstIssue["kind"] as? String, IssueKind.unusedDep.rawValue)
        XCTAssertEqual(firstIssue["dep_label"] as? String, "//Lib:B")
        XCTAssertEqual(firstIssue["dep_kind"] as? String, DepKind.dep.rawValue)
        XCTAssertEqual(firstSkipped["module_name"] as? String, "Foundation")
        XCTAssertEqual(firstSkipped["reason"] as? String, SkippedModuleReason.systemModule.rawValue)
    }

    func testFormatTextCanSuppressFixPlanHint() {
        let dep = DeclaredDep(label: "//Lib:B", moduleName: "B", kind: .dep)
        let result = AnalysisResult(
            target: "//Lib:A",
            moduleName: "A",
            issues: [
                Issue.unusedDep(dep, targetLabel: "//Lib:A"),
            ],
            cleanDeps: [],
            skippedModules: []
        )

        let report = Report.formatText(
            results: [result],
            minConfidence: .low,
            includesFixPlanHint: false
        )

        XCTAssertFalse(report.contains("Run with --fix-output"))
    }
}
