import XCTest
@testable import SwiftUnusedDepsLib

final class AnalyzerTests: XCTestCase {

    private func makeMetadata(
        label: String,
        moduleName: String,
        deps: [(label: String, moduleName: String, kind: DepKind)] = [],
        transitive: [String: String] = [:],
        isMixed: Bool = false
    ) -> TargetMetadata {
        let declaredDeps = deps.map { DeclaredDep(label: $0.label, moduleName: $0.moduleName, kind: $0.kind) }
        return TargetMetadata(
            schemaVersion: 1,
            target: TargetInfo(label: label, moduleName: moduleName, isMixedSource: isMixed),
            declaredDeps: declaredDeps,
            transitiveModuleMap: transitive,
            traceFile: ""
        )
    }

    private func makeModules(_ modules: [(name: String, direct: Bool)]) -> [LoadedModule] {
        modules.map { LoadedModule(name: $0.name, isImportedDirectly: $0.direct) }
    }

    private func makeSystemModules(_ modules: [(name: String, direct: Bool)]) -> [LoadedModule] {
        modules.map { LoadedModule(name: $0.name, isImportedDirectly: $0.direct, isSystem: true) }
    }

    func testCleanTarget() {
        let metadata = makeMetadata(
            label: "//Lib:A", moduleName: "A",
            deps: [("//Lib:B", "B", .dep)],
            transitive: ["B": "//Lib:B"]
        )
        let modules = makeModules([("B", true)])
            + makeSystemModules([("Foundation", true)])
        let resolver = ModuleResolver(transitiveModuleMap: metadata.transitiveModuleMap)

        let result = Analyzer.analyze(metadata: metadata, loadedModules: modules, resolver: resolver)

        XCTAssertTrue(result.isClean)
        XCTAssertEqual(result.cleanDeps.count, 1)
        XCTAssertEqual(result.cleanDeps[0].label, "//Lib:B")
    }

    func testUnusedDep() {
        let metadata = makeMetadata(
            label: "//Lib:A", moduleName: "A",
            deps: [("//Lib:B", "B", .dep), ("//Lib:C", "C", .dep)],
            transitive: ["B": "//Lib:B", "C": "//Lib:C"]
        )
        let modules = makeModules([("C", true)])
            + makeSystemModules([("Foundation", true)])
        let resolver = ModuleResolver(transitiveModuleMap: metadata.transitiveModuleMap)

        let result = Analyzer.analyze(metadata: metadata, loadedModules: modules, resolver: resolver)

        let unused = result.issues.filter { $0.kind == .unusedDep }
        XCTAssertEqual(unused.count, 1)
        XCTAssertEqual(unused[0].depLabel, "//Lib:B")
        XCTAssertEqual(unused[0].confidence, .high)
        XCTAssertEqual(unused[0].suggestedAction, .remove)
        XCTAssertNotNil(unused[0].buildozerCommand)
        XCTAssertEqual(unused[0].buildozerCommand?.batchLine, "remove deps //Lib:B|//Lib:A")
    }

    func testMissingDirectDep() {
        let metadata = makeMetadata(
            label: "//Lib:A", moduleName: "A",
            deps: [("//Lib:B", "B", .dep)],
            transitive: ["B": "//Lib:B", "C": "//Lib:C"]
        )
        let modules = makeModules([("B", true), ("C", true)])
        let resolver = ModuleResolver(transitiveModuleMap: metadata.transitiveModuleMap)

        let result = Analyzer.analyze(metadata: metadata, loadedModules: modules, resolver: resolver)

        let missing = result.issues.filter { $0.kind == .missingDirectDep }
        XCTAssertEqual(missing.count, 1)
        XCTAssertEqual(missing[0].depLabel, "//Lib:C")
        XCTAssertEqual(missing[0].confidence, .high)
        XCTAssertEqual(missing[0].suggestedAction, .addDep)
    }

    func testPrivateDepCandidate() {
        let metadata = makeMetadata(
            label: "//Lib:A", moduleName: "A",
            deps: [("//Lib:D", "D", .dep)],
            transitive: ["D": "//Lib:D"]
        )
        let modules = makeModules([("D", false)])
        let resolver = ModuleResolver(transitiveModuleMap: metadata.transitiveModuleMap)

        let result = Analyzer.analyze(metadata: metadata, loadedModules: modules, resolver: resolver)

        let candidates = result.issues.filter { $0.kind == .candidatePrivateDep }
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].depLabel, "//Lib:D")
        XCTAssertEqual(candidates[0].confidence, .low)
        XCTAssertEqual(candidates[0].suggestedAction, .moveToPrivateDeps)
    }

    func testSystemOnly() {
        let metadata = makeMetadata(label: "//Lib:A", moduleName: "A")
        let modules = makeSystemModules([("Foundation", true), ("UIKit", true), ("Swift", false)])
        let resolver = ModuleResolver(transitiveModuleMap: [:])

        let result = Analyzer.analyze(metadata: metadata, loadedModules: modules, resolver: resolver)

        XCTAssertTrue(result.isClean)
        let system = result.skippedModules.filter { $0.reason == .systemModule }
        XCTAssertEqual(system.map(\.name), ["Foundation", "UIKit"])
    }

    func testMultipleIssues() {
        let metadata = makeMetadata(
            label: "//App:Main", moduleName: "Main",
            deps: [("//Lib:A", "A", .dep), ("//Lib:B", "B", .dep), ("//Lib:C", "C", .dep)],
            transitive: ["A": "//Lib:A", "B": "//Lib:B", "C": "//Lib:C", "D": "//Lib:D"]
        )
        let modules = makeModules([("A", true), ("D", true)])
        let resolver = ModuleResolver(transitiveModuleMap: metadata.transitiveModuleMap)

        let result = Analyzer.analyze(metadata: metadata, loadedModules: modules, resolver: resolver)

        let unused = result.issues.filter { $0.kind == .unusedDep }
        let missing = result.issues.filter { $0.kind == .missingDirectDep }
        XCTAssertEqual(unused.count, 2)
        XCTAssertEqual(Set(unused.compactMap(\.depLabel)), Set(["//Lib:B", "//Lib:C"]))
        XCTAssertEqual(missing.count, 1)
        XCTAssertEqual(missing[0].depLabel, "//Lib:D")
    }

    func testUnresolvedModule() {
        let metadata = makeMetadata(
            label: "//Lib:A", moduleName: "A",
            deps: [("//Lib:B", "B", .dep)],
            transitive: ["B": "//Lib:B"]
        )
        let modules = makeModules([("B", true), ("SomeClangModule", true)])
        let resolver = ModuleResolver(transitiveModuleMap: metadata.transitiveModuleMap)

        let result = Analyzer.analyze(metadata: metadata, loadedModules: modules, resolver: resolver)

        let unresolved = result.issues.filter { $0.kind == .unresolvedModule }
        XCTAssertEqual(unresolved.count, 1)
        XCTAssertEqual(unresolved[0].depModule, "SomeClangModule")
        XCTAssertEqual(unresolved[0].confidence, .low)
    }

    func testMixedSourceWarning() {
        let metadata = makeMetadata(label: "//Lib:Mixed", moduleName: "Mixed", isMixed: true)
        let resolver = ModuleResolver(transitiveModuleMap: [:])

        let result = Analyzer.analyze(metadata: metadata, loadedModules: [], resolver: resolver)

        XCTAssertEqual(result.issues.count, 1)
        XCTAssertTrue(result.issues[0].reason.lowercased().contains("mixed"))
    }

    func testSelfModuleExcluded() {
        let metadata = makeMetadata(
            label: "//Lib:A", moduleName: "A",
            deps: [("//Lib:B", "B", .dep)],
            transitive: ["A": "//Lib:A", "B": "//Lib:B"]
        )
        let modules = makeModules([("A", false), ("B", true)])
        let resolver = ModuleResolver(transitiveModuleMap: metadata.transitiveModuleMap)

        let result = Analyzer.analyze(metadata: metadata, loadedModules: modules, resolver: resolver)

        XCTAssertTrue(result.isClean)
    }

    func testPrivateDepAlreadyPrivate() {
        let metadata = makeMetadata(
            label: "//Lib:A", moduleName: "A",
            deps: [("//Lib:B", "B", .privateDep)],
            transitive: ["B": "//Lib:B"]
        )
        let modules = makeModules([("B", false)])
        let resolver = ModuleResolver(transitiveModuleMap: metadata.transitiveModuleMap)

        let result = Analyzer.analyze(metadata: metadata, loadedModules: modules, resolver: resolver)

        let candidates = result.issues.filter { $0.kind == .candidatePrivateDep }
        XCTAssertEqual(candidates.count, 0)
    }

    // MARK: - BuildozerCommand

    func testBuildozerCommandParseRoundTrip() {
        let cmd = BuildozerCommand(action: "remove deps //Lib:B", target: "//App:Main")
        let parsed = BuildozerCommand.parse(cmd.displayString)
        XCTAssertEqual(parsed?.action, cmd.action)
        XCTAssertEqual(parsed?.target, cmd.target)
    }

    func testBuildozerCommandParseInvalidInput() {
        XCTAssertNil(BuildozerCommand.parse("not a buildozer command"))
        XCTAssertNil(BuildozerCommand.parse("buildozer missing quotes"))
        XCTAssertNil(BuildozerCommand.parse("buildozer '' //target"))
        XCTAssertNil(BuildozerCommand.parse(""))
    }

    func testMissingDepIndirectLowConfidence() {
        let metadata = makeMetadata(
            label: "//Lib:A", moduleName: "A",
            deps: [("//Lib:B", "B", .dep)],
            transitive: ["B": "//Lib:B", "C": "//Lib:C"]
        )
        let modules = makeModules([("B", true), ("C", false)])
        let resolver = ModuleResolver(transitiveModuleMap: metadata.transitiveModuleMap)

        let result = Analyzer.analyze(metadata: metadata, loadedModules: modules, resolver: resolver)

        let missing = result.issues.filter { $0.kind == .missingDirectDep }
        XCTAssertEqual(missing.count, 1)
        XCTAssertEqual(missing[0].confidence, .low)
        XCTAssertEqual(missing[0].suggestedAction, .investigate)
    }
}
