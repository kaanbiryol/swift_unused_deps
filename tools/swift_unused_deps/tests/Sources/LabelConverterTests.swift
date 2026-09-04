import Foundation
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

    func testRepoMappingDumpDisablesLockfileUpdates() {
        XCTAssertEqual(
            LabelConverter.repoMappingDumpArguments,
            ["bazel", "mod", "--lockfile_mode=off", "dump_repo_mapping", ""]
        )
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

    // MARK: - RSPM suffix stripping

    func testExternalRSPMSuffixStripped() {
        let converter = LabelConverter(canonicalToApparent: [
            "swiftpkg_swift_http_types+": ["swiftpkg_swift_http_types"],
        ])
        XCTAssertEqual(
            converter.convert("@@swiftpkg_swift_http_types+//:HTTPTypes.rspm"),
            "@swiftpkg_swift_http_types//:HTTPTypes"
        )
    }

    func testLocalLabelEndingInRSPMNotStripped() {
        let converter = LabelConverter(canonicalToApparent: [:])
        XCTAssertEqual(converter.convert("@@//pkg:Foo.rspm"), "//pkg:Foo.rspm")
    }

    func testIdentityConverterStillStripsRSPM() {
        let converter = LabelConverter.identity
        XCTAssertEqual(
            converter.convert("@swiftpkg_swift_http_types//:HTTPTypes.rspm"),
            "@swiftpkg_swift_http_types//:HTTPTypes"
        )
    }

    func testIdentityConverterNormalizesRSPMCanonicalRepo() {
        let converter = LabelConverter.identity
        XCTAssertEqual(
            converter.convert("@@rules_swift_package_manager++_swift_deps+++swift_deps+swiftpkg_swift_http_types//:HTTPTypes"),
            "@swiftpkg_swift_http_types//:HTTPTypes"
        )
        XCTAssertEqual(
            converter.convert("@rules_swift_package_manager++_swift_deps+++swift_deps+swiftpkg_swift_http_types//:HTTPTypes"),
            "@swiftpkg_swift_http_types//:HTTPTypes"
        )
    }

    func testUnknownRSPMCanonicalRepoNormalizesBeforeFallback() {
        let converter = LabelConverter(canonicalToApparent: [:])
        XCTAssertEqual(
            converter.convert("@@rules_swift_package_manager++_swift_deps+++swift_deps+swiftpkg_grpc_swift_nio_transport//:GRPCNIOTransportHTTP2TransportServices"),
            "@swiftpkg_grpc_swift_nio_transport//:GRPCNIOTransportHTTP2TransportServices"
        )
    }

    func testNonRSPMExternalLabelUnchanged() {
        let converter = LabelConverter(canonicalToApparent: [
            "swift-syntax+": ["swiftpkg_swift_syntax"],
        ])
        XCTAssertEqual(
            converter.convert("@@swift-syntax+//:SwiftSyntax"),
            "@swiftpkg_swift_syntax//:SwiftSyntax"
        )
    }

    func testRSPMSuffixOnlyStrippedAtEnd() {
        let converter = LabelConverter(canonicalToApparent: [
            "swiftpkg_foo+": ["swiftpkg_foo"],
        ])
        XCTAssertEqual(
            converter.convert("@@swiftpkg_foo+//:rspm_helper"),
            "@swiftpkg_foo//:rspm_helper"
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
            pluginDeps: [
                DeclaredDep(
                    label: "@@swift-syntax+//:SwiftCompilerPlugin",
                    moduleName: "SwiftCompilerPlugin",
                    kind: .plugin
                ),
            ],
            transitiveModuleMap: [
                "SwiftSyntax": "@@swift-syntax+//:SwiftSyntax",
                "A": "@@//Lib:A",
            ],
            moduleReachableVia: [
                "SwiftSyntax": ["@@//Lib:Wrapper"],
            ]
        )

        let converted = metadata.convertingLabels(with: converter)

        XCTAssertEqual(converted.target.label, "//Lib:A")
        XCTAssertEqual(converted.target.buildEdit.target, "//Lib:A")
        XCTAssertEqual(converted.target.buildEdit.depsAttribute, "deps")
        XCTAssertEqual(converted.declaredDeps[0].label, "@swiftpkg_swift_syntax//:SwiftSyntax")
        XCTAssertEqual(converted.declaredDeps[0].moduleName, "SwiftSyntax")
        XCTAssertEqual(converted.declaredDeps[0].kind, .dep)
        XCTAssertEqual(converted.pluginDeps[0].label, "@swiftpkg_swift_syntax//:SwiftCompilerPlugin")
        XCTAssertEqual(converted.pluginDeps[0].moduleName, "SwiftCompilerPlugin")
        XCTAssertEqual(converted.pluginDeps[0].kind, .plugin)
        XCTAssertEqual(converted.transitiveModuleMap["SwiftSyntax"], "@swiftpkg_swift_syntax//:SwiftSyntax")
        XCTAssertEqual(converted.transitiveModuleMap["A"], "//Lib:A")
        XCTAssertEqual(converted.moduleReachableVia["SwiftSyntax"], ["//Lib:Wrapper"])
    }

    func testMetadataConvertingLabelsConvertsBuildEditTarget() {
        let converter = LabelConverter(canonicalToApparent: [:])
        let metadata = TargetMetadata(
            schemaVersion: 1,
            target: TargetInfo(
                label: "@@//Lib:Generated",
                moduleName: "Generated",
                buildEdit: BuildEditMetadata(
                    target: "@@//Lib:Owner",
                    depsAttribute: "test_deps",
                    nonRemovableDeps: ["@@//Lib:Owner"]
                )
            ),
            declaredDeps: [],
            transitiveModuleMap: [:]
        )

        let converted = metadata.convertingLabels(with: converter)

        XCTAssertEqual(converted.target.label, "//Lib:Generated")
        XCTAssertEqual(converted.target.buildEdit.target, "//Lib:Owner")
        XCTAssertEqual(converted.target.buildEdit.depsAttribute, "test_deps")
        XCTAssertEqual(converted.target.buildEdit.nonRemovableDeps, ["//Lib:Owner"])
    }

    func testMetadataDecodingDefaultsBuildEdit() throws {
        let json = """
        {
          "schema_version": 1,
          "target": {
            "label": "//Lib:A",
            "module_name": "A"
          },
          "declared_deps": [],
          "plugin_deps": [],
          "transitive_module_map": {}
        }
        """

        let metadata = try JSONDecoder().decode(TargetMetadata.self, from: Data(json.utf8))

        XCTAssertEqual(metadata.target.buildEdit.target, "//Lib:A")
        XCTAssertEqual(metadata.target.buildEdit.depsAttribute, "deps")
        XCTAssertTrue(metadata.target.buildEdit.nonRemovableDeps.isEmpty)
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
            transitiveModuleMap: ["SwiftSyntax": "@@swift-syntax+//:SwiftSyntax"]
        )

        let converted = metadata.convertingLabels(with: converter, buildFileContent: buildFile)

        XCTAssertEqual(converted.declaredDeps[0].label, "@swiftpkg_swift_syntax//:SwiftSyntax")
        XCTAssertEqual(converted.transitiveModuleMap["SwiftSyntax"], "@swiftpkg_swift_syntax//:SwiftSyntax")
    }

    func testMetadataConvertingLabelsPreservesNonLabelFields() {
        let converter = LabelConverter(canonicalToApparent: [:])

        let metadata = TargetMetadata(
            schemaVersion: 2,
            target: TargetInfo(label: "@@//Lib:A", moduleName: "MyModule", isMixedSource: true),
            declaredDeps: [],
            transitiveModuleMap: [:]
        )

        let converted = metadata.convertingLabels(with: converter)

        XCTAssertEqual(converted.schemaVersion, 2)
        XCTAssertEqual(converted.target.moduleName, "MyModule")
        XCTAssertTrue(converted.target.isMixedSource)
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
            transitiveModuleMap: ["SwiftSyntax": "@@swift-syntax+//:SwiftSyntax"]
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

    func testRSPMLabelsProduceCorrectBuildozerCommands() {
        let converter = LabelConverter(canonicalToApparent: [
            "swiftpkg_swift_http_types+": ["swiftpkg_swift_http_types"],
        ])

        // Test unused dep with .rspm label
        let metadata = TargetMetadata(
            schemaVersion: 1,
            target: TargetInfo(label: "@@//Lib:A", moduleName: "A"),
            declaredDeps: [
                DeclaredDep(
                    label: "@@swiftpkg_swift_http_types+//:HTTPTypes.rspm",
                    moduleName: "HTTPTypes",
                    kind: .dep
                ),
            ],
            transitiveModuleMap: [
                "HTTPTypes": "@@swiftpkg_swift_http_types+//:HTTPTypes.rspm",
            ]
        )
        let converted = metadata.convertingLabels(with: converter)

        XCTAssertEqual(converted.declaredDeps[0].label, "@swiftpkg_swift_http_types//:HTTPTypes")
        XCTAssertEqual(converted.transitiveModuleMap["HTTPTypes"], "@swiftpkg_swift_http_types//:HTTPTypes")

        let resolver = ModuleResolver(transitiveModuleMap: converted.transitiveModuleMap)
        let result = Analyzer.analyze(metadata: converted, loadedModules: [], resolver: resolver)

        let unused = result.issues.filter { $0.kind == .unusedDep }
        XCTAssertEqual(unused.count, 1)
        XCTAssertEqual(
            unused[0].buildozerCommand?.displayString,
            "buildozer 'remove deps @swiftpkg_swift_http_types//:HTTPTypes' //Lib:A"
        )

        // Test missing dep with .rspm label
        let missingMetadata = TargetMetadata(
            schemaVersion: 1,
            target: TargetInfo(label: "@@//Lib:A", moduleName: "A"),
            declaredDeps: [],
            transitiveModuleMap: [
                "HTTPTypes": "@@swiftpkg_swift_http_types+//:HTTPTypes.rspm",
            ]
        ).convertingLabels(with: converter)
        let missingResolver = ModuleResolver(transitiveModuleMap: missingMetadata.transitiveModuleMap)
        let missingResult = Analyzer.analyze(
            metadata: missingMetadata,
            loadedModules: [LoadedModule(name: "HTTPTypes", isImportedDirectly: true)],
            resolver: missingResolver
        )
        let missing = missingResult.issues.filter { $0.kind == .missingDirectDep }
        XCTAssertEqual(missing.count, 1)
        XCTAssertEqual(
            missing[0].buildozerCommand?.displayString,
            "buildozer 'add deps @swiftpkg_swift_http_types//:HTTPTypes' //Lib:A"
        )
    }
}
