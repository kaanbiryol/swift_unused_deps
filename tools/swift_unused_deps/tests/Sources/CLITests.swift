import XCTest
@testable import SwiftUnusedDepsLib

final class CLITests: XCTestCase {

    func testRejectsBatchModeWithoutPattern() {
        XCTAssertThrowsError(try SwiftUnusedDepsCommand.parseAsRoot([])) { error in
            XCTAssertTrue("\(error)".contains("Batch mode requires a Bazel target pattern."))
        }
    }

    func testParseBatchModeWithFilter() throws {
        let command = try XCTUnwrap(
            try SwiftUnusedDepsCommand.parseAsRoot([
                "//App/Features/Login...",
            ]) as? SwiftUnusedDepsCommand
        )

        XCTAssertEqual(command.filter, "//App/Features/Login...")
    }

    func testParseBatchModeWithCustomBuildConfig() throws {
        let command = try XCTUnwrap(
            try SwiftUnusedDepsCommand.parseAsRoot([
                "--build-config", "unused-deps-ios",
                "//App:App",
            ]) as? SwiftUnusedDepsCommand
        )

        XCTAssertEqual(command.buildConfig, "unused-deps-ios")
    }

    func testBuildArgumentsUseSelectedConfig() {
        XCTAssertEqual(
            SwiftUnusedDepsCommand.bazelBuildArguments(
                pattern: "//App:App",
                config: "unused-deps-ios"
            ),
            [
                "bazel", "build", "//App:App", "--config=unused-deps-ios",
                "--features=swift.index_while_building",
                "--features=swift.use_global_index_store",
            ]
        )
    }

    func testBuildArgumentsCanWriteBuildEventJSON() {
        XCTAssertEqual(
            SwiftUnusedDepsCommand.bazelBuildArguments(
                pattern: "//App:App",
                config: "unused-deps",
                buildEventJSONFile: "/tmp/events.json"
            ),
            [
                "bazel", "build", "//App:App", "--config=unused-deps",
                "--features=swift.index_while_building",
                "--features=swift.use_global_index_store",
                "--build_event_json_file=/tmp/events.json",
                "--build_event_json_file_path_conversion=false",
            ]
        )
    }

    func testDefaultIndexStorePathUsesGlobalBazelOutLocation() {
        let workspace = URL(fileURLWithPath: "/tmp/workspace-one", isDirectory: true)

        XCTAssertEqual(
            SwiftUnusedDepsCommand.defaultIndexStorePath(
                workspaceDirectory: workspace,
                bazelInfo: BazelInfoProvider { _, _ in nil }
            ),
            "/tmp/workspace-one/bazel-out/_global_index_store"
        )
    }

    func testDefaultIndexStorePathUsesBazelInfoOutputPathWhenAvailable() {
        let workspace = URL(fileURLWithPath: "/tmp/workspace-one", isDirectory: true)
        let outputPath = "/tmp/custom-output/execroot/_main/bazel-out"

        let result = SwiftUnusedDepsCommand.defaultIndexStorePath(
            workspaceDirectory: workspace,
            bazelInfo: BazelInfoProvider { key, currentDirectory in
                XCTAssertEqual(key, "output_path")
                XCTAssertEqual(currentDirectory.path, workspace.path)
                return outputPath
            }
        )

        XCTAssertEqual(result, "/tmp/custom-output/execroot/_main/bazel-out/_global_index_store")
    }

    func testResolveMetadataRootUsesBazelInfoBazelBinWithoutSymlink() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let workspace = directory.appendingPathComponent("workspace", isDirectory: true)
        let bazelBin = directory.appendingPathComponent("custom-bin", isDirectory: true)
        try writeMetadataFile(under: bazelBin)
        var bazelBinOptions: [String]?

        let result = SwiftUnusedDepsCommand.resolveMetadataRoot(
            workspaceDirectory: workspace,
            currentDirectory: directory,
            fileManager: .default,
            bazelInfo: BazelInfoProvider { key, _, options in
                bazelBinOptions = options
                return key == "bazel-bin" ? bazelBin.path : nil
            },
            bazelInfoOptions: ["--config=unused-deps-ios"]
        )

        XCTAssertEqual(result, bazelBin.path)
        XCTAssertEqual(bazelBinOptions, ["--config=unused-deps-ios"])
    }

    func testResolveMetadataRootUsesBazelBinSymlinkWhenBazelInfoHasNoMetadata() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let workspace = directory.appendingPathComponent("workspace", isDirectory: true)
        let emptyBin = directory.appendingPathComponent("empty-bin", isDirectory: true)
        let configBin = directory.appendingPathComponent("configured-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: emptyBin, withIntermediateDirectories: true)
        try writeMetadataFile(under: configBin)
        try FileManager.default.createSymbolicLink(
            at: workspace.appendingPathComponent("bazel-bin"),
            withDestinationURL: configBin
        )

        let result = SwiftUnusedDepsCommand.resolveMetadataRoot(
            workspaceDirectory: workspace,
            currentDirectory: directory,
            fileManager: .default,
            bazelInfo: BazelInfoProvider { key, _ in
                switch key {
                case "bazel-bin":
                    return emptyBin.path
                default:
                    return nil
                }
            }
        )

        XCTAssertEqual(result, configBin.path)
    }

    func testMetadataRootFromBuildEventUsesReportedMetadataArtifact() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let root = directory
            .appendingPathComponent("execroot", isDirectory: true)
            .appendingPathComponent("bazel-out", isDirectory: true)
            .appendingPathComponent("ios-sim_arm64-fastbuild", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
        let metadata = root
            .appendingPathComponent("App", isDirectory: true)
            .appendingPathComponent("App.swift_deps_info.json")
        let buildEvent = directory.appendingPathComponent("events.json")
        try FileManager.default.createDirectory(
            at: metadata.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "{}".write(to: metadata, atomically: true, encoding: .utf8)
        try """
        {"id":{"namedSet":{"id":"0"}},"namedSetOfFiles":{"files":[{"name":"App/App.swift_deps_info.json","uri":"\(metadata.absoluteString)"}]}}
        """.write(to: buildEvent, atomically: true, encoding: .utf8)

        XCTAssertEqual(
            SwiftUnusedDepsCommand.metadataRootFromBuildEvent(
                at: buildEvent,
                fileManager: .default
            ),
            root.path
        )
    }

    func testWorkspaceDirectoryPrefersBazelWorkspaceFromBuildWorkingDirectory() {
        let workingDirectory = "/tmp/consumer/subdir"
        let consumerWorkspace = "/tmp/consumer"
        let runfilesWorkspace = "/tmp/tool.runfiles/_main"

        let result = SwiftUnusedDepsCommand.workspaceDirectory(
            environment: [
                "BUILD_WORKING_DIRECTORY": workingDirectory,
                "BUILD_WORKSPACE_DIRECTORY": runfilesWorkspace,
            ],
            bazelInfo: BazelInfoProvider { key, currentDirectory in
                XCTAssertEqual(key, "workspace")
                XCTAssertEqual(currentDirectory.path, workingDirectory)
                return consumerWorkspace
            }
        )

        XCTAssertEqual(result?.path, consumerWorkspace)
    }

    func testWorkspaceDirectoryFallsBackToBuildWorkspaceDirectory() {
        let workspace = "/tmp/tool.runfiles/_main"

        let result = SwiftUnusedDepsCommand.workspaceDirectory(
            environment: ["BUILD_WORKSPACE_DIRECTORY": workspace],
            bazelInfo: BazelInfoProvider { _, _ in nil }
        )

        XCTAssertEqual(result?.path, workspace)
    }

    func testRejectsFixWithJson() {
        XCTAssertThrowsError(try SwiftUnusedDepsCommand.parseAsRoot([
            "//App:App",
            "--fix",
            "--json",
        ])) { error in
            XCTAssertTrue("\(error)".contains("--fix cannot be combined with --json."))
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writeMetadataFile(
        under root: URL,
        label: String = "//pkg:target",
        moduleName: String = "Target"
    ) throws {
        let packageDirectory = root.appendingPathComponent("pkg", isDirectory: true)
        try FileManager.default.createDirectory(at: packageDirectory, withIntermediateDirectories: true)
        let metadata = TargetMetadata(
            schemaVersion: 1,
            target: TargetInfo(label: label, moduleName: moduleName),
            declaredDeps: [],
            transitiveModuleMap: [:],
            traceFile: ""
        )
        try JSONEncoder().encode(metadata).write(
            to: packageDirectory.appendingPathComponent("\(moduleName).swift_deps_info.json")
        )
    }
}
