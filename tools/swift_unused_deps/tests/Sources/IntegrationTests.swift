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
