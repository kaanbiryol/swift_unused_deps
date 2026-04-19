import Foundation

public enum SourceImportEditor {

    public enum Error: Swift.Error, CustomStringConvertible {
        case fileNotUTF8(path: String)
        case importNotFound(path: String, moduleName: String)

        public var description: String {
            switch self {
            case .fileNotUTF8(let path):
                return "Failed to read source file as UTF-8: \(path)"
            case .importNotFound(let path, let moduleName):
                return "Did not find an import for module '\(moduleName)' in \(path)"
            }
        }
    }

    public static func apply(
        removals: [SourceImportRemoval],
        workspaceDirectory: URL? = nil
    ) throws {
        let grouped = Dictionary(grouping: Set(removals), by: \.filePath)

        for (rawPath, fileRemovals) in grouped {
            let filePath = resolvePath(rawPath, workspaceDirectory: workspaceDirectory)
            let original = try readFile(at: filePath)
            let moduleNames = Set(fileRemovals.map(\.moduleName))
            let updated = try removeImports(
                in: original,
                filePath: filePath,
                moduleNames: moduleNames
            )
            if updated != original {
                try updated.write(toFile: filePath, atomically: true, encoding: .utf8)
            }
        }
    }

    static func removeImports(
        in source: String,
        filePath: String,
        moduleNames: Set<String>
    ) throws -> String {
        var foundModules = Set<String>()
        let hadTrailingNewline = source.hasSuffix("\n")
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)

        let filteredLines = lines.filter { rawLine in
            let line = String(rawLine)
            for moduleName in moduleNames where matchesImport(line: line, moduleName: moduleName) {
                foundModules.insert(moduleName)
                return false
            }
            return true
        }

        for moduleName in moduleNames where !foundModules.contains(moduleName) {
            throw Error.importNotFound(path: filePath, moduleName: moduleName)
        }

        let updated = filteredLines.joined(separator: "\n")
        if hadTrailingNewline {
            return updated + "\n"
        }
        return updated
    }

    static func importedModuleNames(in source: String) -> Set<String> {
        Set(
            importStatements(in: source).map(\.moduleName)
        )
    }

    static func importLineNumbers(in source: String) -> Set<Int> {
        Set(importStatements(in: source).map(\.lineNumber))
    }

    private static func readFile(at path: String) throws -> String {
        guard let source = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw Error.fileNotUTF8(path: path)
        }
        return source
    }

    private static func resolvePath(_ path: String, workspaceDirectory: URL?) -> String {
        guard !path.hasPrefix("/") else { return path }
        guard let workspaceDirectory else { return path }
        return workspaceDirectory.appendingPathComponent(path).path
    }

    private static func matchesImport(line: String, moduleName: String) -> Bool {
        importedModuleName(in: line) == moduleName
    }

    private static func importStatements(in source: String) -> [(lineNumber: Int, moduleName: String)] {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .compactMap { offset, rawLine in
                importedModuleName(in: String(rawLine)).map { (offset + 1, $0) }
            }
    }

    private static func importedModuleName(in line: String) -> String? {
        let pattern =
            #"^\s*(?:@[A-Za-z_][A-Za-z0-9_]*(?:\([^)]*\))?\s+)*import\s+(?:(?:typealias|struct|class|enum|protocol|let|var|func)\s+)?([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*)\s*(?://.*)?$"#
        guard
            let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(
                in: line,
                range: NSRange(line.startIndex..<line.endIndex, in: line)
            ),
            let range = Range(match.range(at: 1), in: line)
        else {
            return nil
        }

        return line[range].split(separator: ".").first.map(String.init)
    }
}
