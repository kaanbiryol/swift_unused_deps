import Foundation
import SwiftParser
import SwiftSyntax

public enum SourceImportEditor {

    private struct ImportStatement {
        let lineNumber: Int
        let moduleName: String
        let isReexported: Bool
    }

    public enum Error: Swift.Error, CustomStringConvertible {
        case fileNotUTF8(path: String)
        case importNotFound(path: String, moduleName: String)
        case reexportedImportNotRemovable(path: String, moduleName: String)

        public var description: String {
            switch self {
            case .fileNotUTF8(let path):
                return "Failed to read source file as UTF-8: \(path)"
            case .importNotFound(let path, let moduleName):
                return "Did not find an import for module '\(moduleName)' in \(path)"
            case .reexportedImportNotRemovable(let path, let moduleName):
                return "Refusing to remove re-exported import for module '\(moduleName)' in \(path)"
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
        var protectedModules = Set<String>()
        let hadTrailingNewline = source.hasSuffix("\n")
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        let importStatements = importStatements(in: source)
        let removedLineNumbers: Set<Int> = Set(
            importStatements.compactMap { statement in
                guard moduleNames.contains(statement.moduleName) else { return nil }
                if statement.isReexported {
                    protectedModules.insert(statement.moduleName)
                    return nil
                }
                foundModules.insert(statement.moduleName)
                return statement.lineNumber
            }
        )

        let filteredLines = lines.enumerated().filter { offset, _ in
            !removedLineNumbers.contains(offset + 1)
        }
        .map(\.element)

        for moduleName in moduleNames where !foundModules.contains(moduleName) {
            if protectedModules.contains(moduleName) {
                throw Error.reexportedImportNotRemovable(path: filePath, moduleName: moduleName)
            }
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

    static func reexportedImportModuleNames(in source: String) -> Set<String> {
        Set(importStatements(in: source).filter(\.isReexported).map(\.moduleName))
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

    private static func importStatements(in source: String) -> [ImportStatement] {
        let syntax = Parser.parse(source: source)
        let sourceLines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        return syntax.statements.compactMap { item in
            guard let importDecl = item.item.as(ImportDeclSyntax.self) else {
                return nil
            }

            let lineNumber = lineNumber(
                atUTF8Offset: importDecl.positionAfterSkippingLeadingTrivia.utf8Offset,
                in: source
            )
            guard sourceLines.indices.contains(lineNumber - 1) else {
                return nil
            }
            let text = sourceLines[lineNumber - 1]
            guard let moduleName = importedModuleName(in: text) else {
                return nil
            }

            return ImportStatement(
                lineNumber: lineNumber,
                moduleName: moduleName,
                isReexported: isReexportedImport(text)
            )
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

    private static func isReexportedImport(_ line: String) -> Bool {
        guard let importRange = line.range(of: #"\bimport\b"#, options: .regularExpression) else {
            return false
        }
        return line[..<importRange.lowerBound].contains("@_exported")
    }

    private static func lineNumber(atUTF8Offset offset: Int, in source: String) -> Int {
        let newlineCount = source.utf8.prefix(offset).reduce(into: 0) { count, byte in
            if byte == 0x0A {
                count += 1
            }
        }
        return newlineCount + 1
    }
}
