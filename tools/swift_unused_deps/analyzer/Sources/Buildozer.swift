import Foundation

public enum Buildozer {

    public struct FixResult {
        public let command: String
        public let success: Bool
        public let output: String
    }

    public static func runBatch(
        commands: [BuildozerCommand],
        workingDirectory: URL? = nil
    ) -> FixResult {
        for command in commands {
            do {
                try command.validateForBatchExecution()
            } catch {
                return FixResult(
                    command: "buildozer -f -",
                    success: false,
                    output: "Refusing to execute invalid buildozer command '\(command.displayString)': \(error)"
                )
            }
        }

        guard let path = findInRunfiles() else {
            return FixResult(
                command: "buildozer -f -",
                success: false,
                output: "buildozer not found in runfiles. Run this binary via 'bazel run' or ensure buildozer is available in runfiles."
            )
        }

        for cmd in commands {
            printErr("  \(cmd.displayString)")
        }

        let stdinContent = commands.map(\.batchLine).joined(separator: "\n") + "\n"

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = ["-f", "-"]
        if let dir = workingDirectory {
            proc.currentDirectoryURL = dir
        }
        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        do {
            try proc.run()
            inPipe.fileHandleForWriting.write(Data(stdinContent.utf8))
            inPipe.fileHandleForWriting.closeFile()
            proc.waitUntilExit()
        } catch {
            return FixResult(command: "buildozer -f -", success: false, output: error.localizedDescription)
        }

        let combinedOutput = [
            String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
        ].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        // Exit code 3 means "no changes made" - treat as success.
        let success = proc.terminationStatus == 0 || proc.terminationStatus == 3
        return FixResult(command: "buildozer -f -", success: success, output: combinedOutput)
    }

    private static let apparentRepoName = "buildozer_binary"
    private static let binaryName = "buildozer.exe"

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

    private static func resolveRepoName(_ apparent: String, runfilesDir: String) -> String {
        let mappingPath = (runfilesDir as NSString).appendingPathComponent("_repo_mapping")
        guard let content = try? String(contentsOfFile: mappingPath, encoding: .utf8) else {
            return apparent
        }
        var fallback: String?
        for line in content.components(separatedBy: "\n") {
            let parts = line.components(separatedBy: ",")
            guard parts.count == 3, parts[1] == apparent else { continue }
            // Prefer main repo's mapping (empty first field).
            if parts[0].isEmpty { return parts[2] }
            // Otherwise remember the first match from any repo.
            if fallback == nil { fallback = parts[2] }
        }
        return fallback ?? apparent
    }
}

public func printErr(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}
