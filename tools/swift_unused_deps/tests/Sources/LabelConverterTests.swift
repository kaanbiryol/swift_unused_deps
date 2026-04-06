import XCTest
@testable import SwiftUnusedDepsLib

final class LabelConverterTests: XCTestCase {

    // MARK: - Identity converter

    func testIdentityPassesLabelsThrough() {
        let converter = LabelConverter.identity
        XCTAssertEqual(converter.convert("//Lib:A"), "//Lib:A")
        XCTAssertEqual(converter.convert("@repo//:Foo"), "@repo//:Foo")
        XCTAssertEqual(converter.convert("@@canonical+//:Bar"), "@@canonical+//:Bar")
    }

    // MARK: - Canonical label conversion

    func testMainRepoLabelStripsDoubleAt() {
        let converter = LabelConverter(canonicalToApparent: [:])
        XCTAssertEqual(converter.convert("@@//App:Main"), "//App:Main")
        XCTAssertEqual(converter.convert("@@//libraries/Core:Lib"), "//libraries/Core:Lib")
    }

    func testExternalRepoLabelConvertsToApparent() {
        let converter = LabelConverter(canonicalToApparent: [
            "swift-syntax+": ["swiftpkg_swift_syntax"],
            "rules_swift+": ["rules_swift"],
        ])
        XCTAssertEqual(
            converter.convert("@@swift-syntax+//:SwiftCompilerPlugin"),
            "@swiftpkg_swift_syntax//:SwiftCompilerPlugin"
        )
        XCTAssertEqual(
            converter.convert("@@swift-syntax+//:SwiftSyntax"),
            "@swiftpkg_swift_syntax//:SwiftSyntax"
        )
        XCTAssertEqual(
            converter.convert("@@rules_swift+//swift:swift.bzl"),
            "@rules_swift//swift:swift.bzl"
        )
    }

    func testUnknownCanonicalRepoFallsBackToSingleAt() {
        let converter = LabelConverter(canonicalToApparent: ["known+": ["known"]])
        XCTAssertEqual(
            converter.convert("@@unknown+//:Target"),
            "@unknown+//:Target"
        )
    }

    func testWorkspaceLabelsPassThrough() {
        let converter = LabelConverter(canonicalToApparent: [
            "swift-syntax+": ["swiftpkg_swift_syntax"],
        ])
        XCTAssertEqual(converter.convert("//Lib:A"), "//Lib:A")
        XCTAssertEqual(converter.convert("@swiftpkg_swift_syntax//:SwiftSyntax"), "@swiftpkg_swift_syntax//:SwiftSyntax")
    }

    func testMalformedCanonicalLabelPassesThrough() {
        let converter = LabelConverter(canonicalToApparent: [:])
        XCTAssertEqual(converter.convert("@@no-double-slash"), "@@no-double-slash")
    }

    // MARK: - Multiple apparent names disambiguation

    func testMultipleApparentNamesUsesFirstByDefault() {
        let converter = LabelConverter(canonicalToApparent: [
            "swift-syntax+": ["SwiftSyntax", "swiftpkg_swift_syntax"],
        ])
        XCTAssertEqual(
            converter.convert("@@swift-syntax+//:SwiftSyntax"),
            "@SwiftSyntax//:SwiftSyntax"
        )
    }

    func testMultipleApparentNamesDisambiguatesViaBuildFile() {
        let converter = LabelConverter(canonicalToApparent: [
            "swift-syntax+": ["SwiftSyntax", "swiftpkg_swift_syntax"],
        ])
        let buildFile = """
        swift_library(
            name = "Lib",
            deps = [
                "@swiftpkg_swift_syntax//:SwiftCompilerPlugin",
                "@swiftpkg_swift_syntax//:SwiftSyntax",
            ],
        )
        """
        XCTAssertEqual(
            converter.convert("@@swift-syntax+//:SwiftSyntax", buildFileContent: buildFile),
            "@swiftpkg_swift_syntax//:SwiftSyntax"
        )
    }

    func testMultipleApparentNamesFallsBackWhenBuildFileHasNoMatch() {
        let converter = LabelConverter(canonicalToApparent: [
            "swift-syntax+": ["SwiftSyntax", "swiftpkg_swift_syntax"],
        ])
        let buildFile = """
        swift_library(name = "Lib", deps = [])
        """
        XCTAssertEqual(
            converter.convert("@@swift-syntax+//:SwiftSyntax", buildFileContent: buildFile),
            "@SwiftSyntax//:SwiftSyntax"
        )
    }

    // MARK: - TargetMetadata label conversion

    func testMetadataConvertingLabels() {
        let converter = LabelConverter(canonicalToApparent: [
            "swift-syntax+": ["swiftpkg_swift_syntax"],
        ])

        let metadata = TargetMetadata(
            schemaVersion: 1,
            target: TargetInfo(label: "@@//Lib:A", moduleName: "A"),
            declaredDeps: [
                DeclaredDep(
                    label: "@@swift-syntax+//:SwiftSyntax",
                    moduleName: "SwiftSyntax",
                    kind: .dep
                ),
            ],
            transitiveModuleMap: [
                "SwiftSyntax": "@@swift-syntax+//:SwiftSyntax",
                "A": "@@//Lib:A",
            ],
            traceFile: ""
        )

        let converted = metadata.convertingLabels(with: converter)

        XCTAssertEqual(converted.target.label, "//Lib:A")
        XCTAssertEqual(converted.declaredDeps[0].label, "@swiftpkg_swift_syntax//:SwiftSyntax")
        XCTAssertEqual(converted.declaredDeps[0].moduleName, "SwiftSyntax")
        XCTAssertEqual(converted.declaredDeps[0].kind, .dep)
        XCTAssertEqual(converted.transitiveModuleMap["SwiftSyntax"], "@swiftpkg_swift_syntax//:SwiftSyntax")
        XCTAssertEqual(converted.transitiveModuleMap["A"], "//Lib:A")
        XCTAssertEqual(converted.traceFile, "")
    }

    func testMetadataConvertingLabelsWithBuildFileDisambiguation() {
        let converter = LabelConverter(canonicalToApparent: [
            "swift-syntax+": ["SwiftSyntax", "swiftpkg_swift_syntax"],
        ])
        let buildFile = """
        deps = ["@swiftpkg_swift_syntax//:SwiftSyntax"]
        """

        let metadata = TargetMetadata(
            schemaVersion: 1,
            target: TargetInfo(label: "@@//Lib:A", moduleName: "A"),
            declaredDeps: [
                DeclaredDep(label: "@@swift-syntax+//:SwiftSyntax", moduleName: "SwiftSyntax", kind: .dep),
            ],
            transitiveModuleMap: ["SwiftSyntax": "@@swift-syntax+//:SwiftSyntax"],
            traceFile: ""
        )

        let converted = metadata.convertingLabels(with: converter, buildFileContent: buildFile)

        XCTAssertEqual(converted.declaredDeps[0].label, "@swiftpkg_swift_syntax//:SwiftSyntax")
        XCTAssertEqual(converted.transitiveModuleMap["SwiftSyntax"], "@swiftpkg_swift_syntax//:SwiftSyntax")
    }

    func testMetadataConvertingLabelsPreservesNonLabelFields() {
        let converter = LabelConverter(canonicalToApparent: [:])

        let metadata = TargetMetadata(
            schemaVersion: 2,
            target: TargetInfo(label: "@@//Lib:A", moduleName: "MyModule", isMixedSource: true, srcs: ["File.swift"]),
            declaredDeps: [],
            transitiveModuleMap: [:],
            traceFile: "some/path.trace.json"
        )

        let converted = metadata.convertingLabels(with: converter)

        XCTAssertEqual(converted.schemaVersion, 2)
        XCTAssertEqual(converted.target.moduleName, "MyModule")
        XCTAssertTrue(converted.target.isMixedSource)
        XCTAssertEqual(converted.target.srcs, ["File.swift"])
        XCTAssertEqual(converted.traceFile, "some/path.trace.json")
    }

    // MARK: - End-to-end: canonical labels produce correct buildozer commands

    func testCanonicalLabelsProduceCorrectBuildozerCommands() {
        let converter = LabelConverter(canonicalToApparent: [
            "swift-syntax+": ["swiftpkg_swift_syntax"],
        ])

        let metadata = TargetMetadata(
            schemaVersion: 1,
            target: TargetInfo(label: "@@//Lib:A", moduleName: "A"),
            declaredDeps: [
                DeclaredDep(label: "@@swift-syntax+//:SwiftSyntax", moduleName: "SwiftSyntax", kind: .dep),
            ],
            transitiveModuleMap: ["SwiftSyntax": "@@swift-syntax+//:SwiftSyntax"],
            traceFile: ""
        )
        let converted = metadata.convertingLabels(with: converter)

        let resolver = ModuleResolver(transitiveModuleMap: converted.transitiveModuleMap)
        let result = Analyzer.analyze(metadata: converted, loadedModules: [], resolver: resolver)

        let unused = result.issues.filter { $0.kind == .unusedDep }
        XCTAssertEqual(unused.count, 1)
        XCTAssertEqual(
            unused[0].buildozerCommand?.displayString,
            "buildozer 'remove deps @swiftpkg_swift_syntax//:SwiftSyntax' //Lib:A"
        )
    }
}
