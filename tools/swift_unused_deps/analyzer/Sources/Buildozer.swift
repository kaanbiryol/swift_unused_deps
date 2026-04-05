import Foundation

public enum Buildozer {

    public struct FixResult {
        public let command: String
        public let success: Bool
        public let output: String
    }

    /// Resolve the buildozer binary from Bazel runfiles.
    public static var binaryPath: String {
        if let path = findInRunfiles() {
            return path
        }
        fatalError("buildozer not found in runfiles. This binary must be run via 'bazel run'.")
    }

    /// Run all commands, printing progress to stderr. Returns (succeeded, failed) counts.
    /// Commands should be full strings like "buildozer 'remove deps //X' //Y".
    /// The "buildozer" prefix is replaced with the resolved binary path.
    public static func runAll(
        commands: [String],
        workingDirectory: URL? = nil
    ) -> (succeeded: Int, failed: Int) {
        let path = binaryPath
        var succeeded = 0
        var failed = 0
        for (index, cmd) in commands.enumerated() {
            printErr("[\(index + 1)/\(commands.count)] \(cmd)")
            let result = run(buildozerPath: path, command: cmd, workingDirectory: workingDirectory)
            if result.success {
                succeeded += 1
                printErr("  OK")
            } else {
                failed += 1
                printErr("  FAILED: \(result.output)")
            }
        }
        return (succeeded, failed)
    }

    private static let apparentRepoName = "buildozer_binary"
    private static let binaryName = "buildozer.exe"

    /// Execute a single buildozer command string via `/bin/sh -c`.
    /// Replaces the leading "buildozer" with the resolved binary path.
    private static func run(
        buildozerPath: String,
        command: String,
        workingDirectory: URL? = nil
    ) -> FixResult {
        let shellCommand: String
        if command.hasPrefix("buildozer ") {
            shellCommand = buildozerPath + command.dropFirst("buildozer".count)
        } else {
            shellCommand = buildozerPath + " " + command
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", shellCommand]
        if let dir = workingDirectory {
            proc.currentDirectoryURL = dir
        }
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return FixResult(command: command, success: false, output: error.localizedDescription)
        }
        let combinedOutput = [
            String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
        ].joined().trimmingCharacters(in: .whitespacesAndNewlines)
        // Exit code 3 means "no changes made" - treat as success.
        let success = proc.terminationStatus == 0 || proc.terminationStatus == 3
        return FixResult(command: command, success: success, output: combinedOutput)
    }

    private static func findInRunfiles() -> String? {
        let fm = FileManager.default

        let runfilesDir: String
        if let envDir = ProcessInfo.processInfo.environment["RUNFILES_DIR"] {
            runfilesDir = envDir
        } else {
            let execPath = ProcessInfo.processInfo.arguments[0]
            let candidate = execPath + ".runfiles"
            guard fm.fileExists(atPath: candidate) else { return nil }
            runfilesDir = candidate
        }

        let canonicalRepo = resolveRepoName(apparentRepoName, runfilesDir: runfilesDir)
        let path = (runfilesDir as NSString)
            .appendingPathComponent(canonicalRepo)
            .appending("/\(binaryName)")
        if fm.isExecutableFile(atPath: path) { return path }

        return nil
    }

    /// Parse _repo_mapping to resolve an apparent repo name to its canonical name.
    /// Format: `<source_repo>,<apparent_name>,<canonical_name>` (one per line).
    /// We look for entries from the main repo (empty source_repo).
    private static func resolveRepoName(_ apparent: String, runfilesDir: String) -> String {
        let mappingPath = (runfilesDir as NSString).appendingPathComponent("_repo_mapping")
        guard let content = try? String(contentsOfFile: mappingPath, encoding: .utf8) else {
            return apparent
        }
        for line in content.components(separatedBy: "\n") {
            let parts = line.components(separatedBy: ",")
            guard parts.count == 3 else { continue }
            // Empty first field = main repo's mapping.
            if parts[0].isEmpty && parts[1] == apparent {
                return parts[2]
            }
        }
        return apparent
    }
}

private func printErr(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}
