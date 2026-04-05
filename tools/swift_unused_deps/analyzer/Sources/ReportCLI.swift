import Foundation
import SwiftUnusedDepsLib

@main
enum ReportMain {
    static func main() throws {
        let bazelBin = resolveBazelBin()
        guard !bazelBin.isEmpty else {
            printErr("ERROR: Could not determine bazel-bin path.")
            exit(2)
        }

        var fixMode = false
        var filter: String? = nil
        var indexStorePath: String? = nil
        let args = Array(CommandLine.arguments.dropFirst())
        var i = 0
        while i < args.count {
            if args[i] == "--fix" {
                fixMode = true
            } else if args[i] == "--index-store-path" && i + 1 < args.count {
                i += 1
                indexStorePath = args[i]
            } else if args[i].hasPrefix("--index-store-path=") {
                indexStorePath = String(args[i].dropFirst("--index-store-path=".count))
            } else {
                filter = args[i]
            }
            i += 1
        }

        let defaultIndexStorePath = "/tmp/swift_unused_deps_index_store"
        let effectiveIndexStorePath = indexStorePath
            ?? (FileManager.default.fileExists(atPath: defaultIndexStorePath) ? defaultIndexStorePath : nil)

        let output = BatchAnalyzer.analyze(options: .init(
            bazelBin: bazelBin,
            indexStorePath: effectiveIndexStorePath,
            filter: filter
        ))

        for warning in output.warnings {
            printErr("WARNING: \(warning)")
        }

        if output.results.isEmpty {
            printErr("No targets found. Run 'bazel build <targets> --config=unused-deps' first.")
            exit(2)
        }

        var totalTargets = 0
        var totalIssues = 0
        var fixCommands: [BuildozerCommand] = []

        for result in output.results {
            totalTargets += 1
            let highIssues = result.issues.filter { $0.confidence >= .high }
            if highIssues.isEmpty { continue }

            print(result.target)
            for issue in highIssues {
                totalIssues += 1
                let dep = issue.depLabel ?? "?"
                let module = issue.depModule ?? ""
                let label: String
                switch issue.kind {
                case .unusedDep: label = "UNUSED"
                case .missingDirectDep: label = "MISSING DEP"
                default: label = issue.kind.rawValue.uppercased()
                }
                if !module.isEmpty && module != dep {
                    print("  \(label): \(dep) (module: \(module))")
                } else {
                    print("  \(label): \(dep)")
                }
                if let cmd = issue.buildozerCommand {
                    print("  Fix: \(cmd.displayString)")
                    fixCommands.append(cmd)
                }
            }
            print()
        }

        print("\(totalIssues) issue(s) found across \(totalTargets) targets.")

        if fixMode && !fixCommands.isEmpty {
            let workDir = ProcessInfo.processInfo.environment["BUILD_WORKSPACE_DIRECTORY"]
                .map { URL(fileURLWithPath: $0) }
            printErr("")
            printErr("Applying \(fixCommands.count) fix(es)...")
            printErr("")
            let batchResult = Buildozer.runBatch(commands: fixCommands, workingDirectory: workDir)
            if batchResult.success {
                printErr("Done: \(fixCommands.count) fix(es) applied.")
                exit(0)
            } else {
                printErr("FAILED: \(batchResult.output)")
                exit(1)
            }
        }

        if totalIssues > 0 {
            exit(1)
        }
    }

    private static func resolveBazelBin() -> String {
        // BUILD_WORKSPACE_DIRECTORY is set by `bazel run`.
        // bazel-bin is a symlink at the workspace root - resolve it so FileManager can enumerate.
        let workspace = ProcessInfo.processInfo.environment["BUILD_WORKSPACE_DIRECTORY"]
            ?? FileManager.default.currentDirectoryPath
        let bazelBin = URL(fileURLWithPath: workspace).appendingPathComponent("bazel-bin").path
        return (try? FileManager.default.destinationOfSymbolicLink(atPath: bazelBin)) ?? bazelBin
    }
}
