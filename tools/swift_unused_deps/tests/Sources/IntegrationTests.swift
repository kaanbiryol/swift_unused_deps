import Foundation
import XCTest

final class IntegrationTests: XCTestCase {
    private let integrationTarget = "//example/Targets/UnusedImport:UnusedImport"

    func testPublicCliFlowAnalyzeAndFix() throws {
        let bazelPath = try XCTUnwrap(resolveBazelPath(), "bazel binary not found for integration test")
        let repoDirectory = try makeWorkspaceCopy()

        let analyze = try runBazel(
            bazelPath: bazelPath,
            in: repoDirectory,
            arguments: ["run", "//:swift_unused_deps", "--", integrationTarget, "--json"]
        )
        XCTAssertEqual(analyze.exitCode, 1)
        XCTAssertTrue(analyze.stdout.contains("\"kind\" : \"unused_import\""))
        XCTAssertTrue(analyze.stdout.contains("\"module_name\" : \"LibA\""))
        XCTAssertTrue(analyze.stdout.contains("\"module_name\" : \"LibB\""))
        XCTAssertTrue(analyze.stdout.contains("\"classification\" : \"correctly_declared_dep\""))
        XCTAssertFalse(analyze.stdout.contains("\"dep_module\" : \"LibB\""))
        XCTAssertTrue(analyze.stdout.contains("\"source_import_removals\""))
        XCTAssertEqual(countOccurrences(of: "\"kind\" : \"unused_import\"", in: analyze.stdout), 1)

        let fix = try runBazel(
            bazelPath: bazelPath,
            in: repoDirectory,
            arguments: [
                "run", "//:swift_unused_deps", "--",
                integrationTarget, "--fix", "--min-confidence", "high",
            ]
        )
        XCTAssertEqual(fix.exitCode, 0, "stdout:\n\(fix.stdout)\n\nstderr:\n\(fix.stderr)")
        XCTAssertTrue(fix.stdout.contains("Summary: 1 target analyzed, 0 issues found."))

        let source = try String(
            contentsOf: repoDirectory
                .appendingPathComponent("example/Targets/UnusedImport/UnusedImport.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("import LibB"))
        XCTAssertFalse(source.contains("import LibA"))

        let buildFile = try String(
            contentsOf: repoDirectory
                .appendingPathComponent("example/Targets/UnusedImport/BUILD.bazel"),
            encoding: .utf8
        )
        XCTAssertFalse(buildFile.contains("//example/Deps/LibA"))
    }

    func testExternalConsumerViaLocalPathOverride() throws {
        let bazelPath = try XCTUnwrap(resolveBazelPath(), "bazel binary not found for integration test")
        let repoDirectory = try makeWorkspaceCopy()
        let consumerDirectory = try makeConsumerWorkspace(swiftUnusedDepsPath: repoDirectory.path)

        let result = try runBazel(
            bazelPath: bazelPath,
            in: consumerDirectory,
            arguments: [
                "run", "@swift_unused_deps//:swift_unused_deps", "--",
                "//App:App", "--json",
            ]
        )

        XCTAssertEqual(result.exitCode, 0, "stdout:\n\(result.stdout)\n\nstderr:\n\(result.stderr)")
        XCTAssertTrue(result.stdout.contains("\"status\" : \"clean\""))
        XCTAssertTrue(result.stdout.contains("\"target\" : \"\\/\\/App:App\""))
    }

    private func makeWorkspaceCopy() throws -> URL {
        let testSrcDir = try XCTUnwrap(ProcessInfo.processInfo.environment["TEST_SRCDIR"])
        let runfilesRoot = URL(fileURLWithPath: testSrcDir).appendingPathComponent("_main")
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let repoDirectory = tempRoot.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repoDirectory, withIntermediateDirectories: true)
        try copyDirectoryContentsDereferencingSymlinks(from: runfilesRoot, to: repoDirectory)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        return repoDirectory
    }

    private func makeConsumerWorkspace(swiftUnusedDepsPath: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }

        try "9.0.2\n".write(
            to: directory.appendingPathComponent(".bazelversion"),
            atomically: true,
            encoding: .utf8
        )
        try """
        build:unused-deps --features=swift.index_while_building
        build:unused-deps --features=swift.use_global_index_store
        build:unused-deps --aspects=@swift_unused_deps//tools/swift_unused_deps/aspect:deps_info.bzl%swift_deps_aspect
        build:unused-deps --output_groups=swift_deps_info,swift_index_store
        build:unused-deps --spawn_strategy=local
        """.write(
            to: directory.appendingPathComponent(".bazelrc"),
            atomically: true,
            encoding: .utf8
        )
        try """
        module(name = "swift_unused_deps_consumer")

        bazel_dep(name = "rules_swift", version = "3.6.0", repo_name = "build_bazel_rules_swift")
        bazel_dep(name = "swift_unused_deps", version = "0.1.0")

        local_path_override(
            module_name = "swift_unused_deps",
            path = "\(swiftUnusedDepsPath)",
        )
        """.write(
            to: directory.appendingPathComponent("MODULE.bazel"),
            atomically: true,
            encoding: .utf8
        )
        try "# External consumer smoke workspace.\n".write(
            to: directory.appendingPathComponent("BUILD.bazel"),
            atomically: true,
            encoding: .utf8
        )

        let libDirectory = directory.appendingPathComponent("Lib", isDirectory: true)
        try FileManager.default.createDirectory(at: libDirectory, withIntermediateDirectories: true)
        try """
        load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

        swift_library(
            name = "Lib",
            srcs = ["Lib.swift"],
            module_name = "Lib",
            visibility = ["//visibility:public"],
        )
        """.write(
            to: libDirectory.appendingPathComponent("BUILD.bazel"),
            atomically: true,
            encoding: .utf8
        )
        try """
        public struct LibValue {
            public init() {}
        }
        """.write(
            to: libDirectory.appendingPathComponent("Lib.swift"),
            atomically: true,
            encoding: .utf8
        )

        let appDirectory = directory.appendingPathComponent("App", isDirectory: true)
        try FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        try """
        load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

        swift_library(
            name = "App",
            srcs = ["App.swift"],
            module_name = "App",
            deps = ["//Lib:Lib"],
        )
        """.write(
            to: appDirectory.appendingPathComponent("BUILD.bazel"),
            atomically: true,
            encoding: .utf8
        )
        try """
        import Lib

        public func makeValue() -> LibValue {
            LibValue()
        }
        """.write(
            to: appDirectory.appendingPathComponent("App.swift"),
            atomically: true,
            encoding: .utf8
        )

        return directory
    }

    private func runBazel(
        bazelPath: String,
        in directory: URL,
        arguments: [String]
    ) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: bazelPath)
        process.arguments = arguments
        process.currentDirectoryURL = directory

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        return CommandResult(
            exitCode: Int(process.terminationStatus),
            stdout: String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            stderr: String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )
    }

    private struct CommandResult {
        let exitCode: Int
        let stdout: String
        let stderr: String
    }

    private func countOccurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    private func copyDirectoryContentsDereferencingSymlinks(from source: URL, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/cp")
        process.arguments = ["-R", "-L", source.appendingPathComponent(".").path, destination.path]

        let stderr = Pipe()
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let output = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(
                domain: "IntegrationTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: output]
            )
        }
    }

    private func resolveBazelPath() -> String? {
        let environmentPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let searchPaths = environmentPath.split(separator: ":").map(String.init) + [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
        ]

        for directory in searchPaths {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent("bazel").path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        return nil
    }
}
