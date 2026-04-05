import Foundation
import SwiftUnusedDepsLib

@main
enum ReportMain {
    static func main() throws {
        let bazelBin: String
        if let env = ProcessInfo.processInfo.environment["BUILD_WORKSPACE_DIRECTORY"] {
            // Running via `bazel run` - resolve bazel-bin relative to workspace.
            let pipe = Process()
            pipe.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            pipe.arguments = ["bazel", "info", "bazel-bin"]
            pipe.currentDirectoryURL = URL(fileURLWithPath: env)
            let out = Pipe()
            pipe.standardOutput = out
            pipe.standardError = FileHandle.nullDevice
            try pipe.run()
            pipe.waitUntilExit()
            bazelBin = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        } else {
            // Running directly - try bazel info from cwd.
            let pipe = Process()
            pipe.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            pipe.arguments = ["bazel", "info", "bazel-bin"]
            let out = Pipe()
            pipe.standardOutput = out
            pipe.standardError = FileHandle.nullDevice
            try pipe.run()
            pipe.waitUntilExit()
            bazelBin = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }

        guard !bazelBin.isEmpty else {
            printErr("ERROR: Could not determine bazel-bin path.")
            exit(2)
        }

        var fixMode = false
        var filter: String? = nil
        for arg in CommandLine.arguments.dropFirst() {
            if arg == "--fix" {
                fixMode = true
            } else {
                filter = arg
            }
        }

        let baseURL = URL(fileURLWithPath: bazelBin, isDirectory: true)
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: baseURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else {
            printErr("ERROR: Cannot read \(bazelBin)")
            exit(2)
        }

        var reportFiles: [URL] = []
        for case let url as URL in enumerator {
            if url.lastPathComponent.hasSuffix(".swift_deps_report.json") {
                reportFiles.append(url)
            }
        }
        reportFiles.sort { $0.path < $1.path }

        if reportFiles.isEmpty {
            printErr("No reports found. Run 'bazel build <targets> --config=unused-deps' first.")
            exit(2)
        }

        var totalTargets = 0
        var totalIssues = 0
        var fixCommands: [BuildozerCommand] = []

        for file in reportFiles {
            let data = try Data(contentsOf: file)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]] else {
                continue
            }

            for result in results {
                guard let target = result["target"] as? String,
                      let issues = result["issues"] as? [[String: Any]] else {
                    continue
                }

                if let pattern = filter {
                    let prefix = pattern.replacingOccurrences(of: "...", with: "")
                        .replacingOccurrences(of: "@@", with: "")
                    let targetClean = target.replacingOccurrences(of: "@@", with: "")
                    if !targetClean.hasPrefix(prefix) {
                        continue
                    }
                }

                totalTargets += 1

                // Only show high confidence issues.
                let highIssues = issues.filter { ($0["confidence"] as? String) == "high" }
                if highIssues.isEmpty { continue }

                print(target)
                for issue in highIssues {
                    totalIssues += 1
                    let dep = issue["dep_label"] as? String ?? "?"
                    let module = issue["dep_module"] as? String ?? ""
                    let label: String
                    switch issue["kind"] as? String {
                    case "unused_dep": label = "UNUSED"
                    case "missing_direct_dep": label = "MISSING DEP"
                    default: label = (issue["kind"] as? String ?? "ISSUE").uppercased()
                    }
                    if !module.isEmpty && module != dep {
                        print("  \(label): \(dep) (module: \(module))")
                    } else {
                        print("  \(label): \(dep)")
                    }
                    if let cmdStr = issue["buildozer_command"] as? String {
                        print("  Fix: \(cmdStr)")
                        if let cmd = BuildozerCommand.parse(cmdStr) {
                            fixCommands.append(cmd)
                        }
                    }
                }
                print()
            }
        }

        print("\(totalIssues) issue(s) found across \(totalTargets) targets.")

        if fixMode && !fixCommands.isEmpty {
            let workDir: URL?
            if let env = ProcessInfo.processInfo.environment["BUILD_WORKSPACE_DIRECTORY"] {
                workDir = URL(fileURLWithPath: env)
            } else {
                workDir = nil
            }

            printErr("")
            printErr("Applying \(fixCommands.count) fix(es)...")
            printErr("")
            let result = Buildozer.runBatch(commands: fixCommands, workingDirectory: workDir)
            if result.success {
                printErr("Done: \(fixCommands.count) fix(es) applied.")
                exit(0)
            } else {
                printErr("FAILED: \(result.output)")
                exit(1)
            }
        }

        if totalIssues > 0 {
            exit(1)
        }
    }
}

private func printErr(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}
