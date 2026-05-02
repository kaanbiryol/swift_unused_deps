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

        let result = SwiftUnusedDepsCommand.resolveMetadataRoot(
            workspaceDirectory: workspace,
            currentDirectory: directory,
            fileManager: .default,
            bazelInfo: BazelInfoProvider { key, _ in
                key == "bazel-bin" ? bazelBin.path : nil
            }
        )

        XCTAssertEqual(result, bazelBin.path)
    }

    func testResolveMetadataRootScansBazelInfoOutputPathWhenBazelBinHasNoMetadata() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let workspace = directory.appendingPathComponent("workspace", isDirectory: true)
        let emptyBin = directory.appendingPathComponent("empty-bin", isDirectory: true)
        let outputPath = directory.appendingPathComponent("custom-bazel-out", isDirectory: true)
        let configBin = outputPath
            .appendingPathComponent("ios-sim_arm64-fastbuild", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyBin, withIntermediateDirectories: true)
        try writeMetadataFile(under: configBin)

        let result = SwiftUnusedDepsCommand.resolveMetadataRoot(
            workspaceDirectory: workspace,
            currentDirectory: directory,
            fileManager: .default,
            bazelInfo: BazelInfoProvider { key, _ in
                switch key {
                case "bazel-bin":
                    return emptyBin.path
                case "output_path":
                    return outputPath.path
                default:
                    return nil
                }
            }
        )

        XCTAssertEqual(result, configBin.path)
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

    private func writeMetadataFile(under root: URL) throws {
        let packageDirectory = root.appendingPathComponent("pkg", isDirectory: true)
        try FileManager.default.createDirectory(at: packageDirectory, withIntermediateDirectories: true)
        try "{}".write(
            to: packageDirectory.appendingPathComponent("target.swift_deps_info.json"),
            atomically: true,
            encoding: .utf8
        )
    }
}
