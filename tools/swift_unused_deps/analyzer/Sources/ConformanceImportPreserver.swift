import Foundation
import SwiftParser
import SwiftSyntax

struct ConformanceDeclaration {
    let typeName: String
    let protocolName: String
}

enum ConformanceImportPreserver {
    static func preserve(
        in sourceFileUsage: [SourceFileModuleUsage],
        metadata: TargetMetadata,
        allMetadataByLabel: [String: TargetMetadata],
        workspaceDirectory: URL?
    ) -> [SourceFileModuleUsage] {
        guard !sourceFileUsage.isEmpty else { return sourceFileUsage }

        var declarationsByDepModule: [String: [ConformanceDeclaration]] = [:]
        for dep in metadata.declaredDeps {
            guard let depMetadata = allMetadataByLabel[dep.label] else { continue }
            let declarations = conformanceDeclarations(
                in: depMetadata.target.sourceFiles,
                workspaceDirectory: workspaceDirectory
            )
            if !declarations.isEmpty {
                declarationsByDepModule[dep.moduleName] = declarations
            }
        }
        guard !declarationsByDepModule.isEmpty else { return sourceFileUsage }

        return sourceFileUsage.map { usage in
            let source = readSourceFile(usage.sourceFile, workspaceDirectory: workspaceDirectory) ?? ""
            guard !source.isEmpty else { return usage }

            var referencedModules = usage.referencedModules
            for moduleName in usage.directImports where !referencedModules.contains(moduleName) {
                guard let declarations = declarationsByDepModule[moduleName] else { continue }
                if declarations.contains(where: { declaration in
                    sourceContainsIdentifier(declaration.typeName, in: source)
                        && sourceContainsIdentifier(declaration.protocolName, in: source)
                }) {
                    referencedModules.insert(moduleName)
                }
            }

            guard referencedModules != usage.referencedModules else { return usage }
            return SourceFileModuleUsage(
                sourceFile: usage.sourceFile,
                isGenerated: usage.isGenerated,
                moduleName: usage.moduleName,
                referencedModules: referencedModules,
                loadedModules: usage.loadedModules,
                systemModules: usage.systemModules,
                directImports: usage.directImports,
                reexportedImports: usage.reexportedImports,
                testableImports: usage.testableImports,
                requiredTestableImports: usage.requiredTestableImports,
                unnecessaryTestableImports: usage.unnecessaryTestableImports,
                conditionalImports: usage.conditionalImports
            )
        }
    }

    private static func conformanceDeclarations(
        in sourceFiles: [SourceFileMetadata],
        workspaceDirectory: URL?
    ) -> [ConformanceDeclaration] {
        sourceFiles.flatMap { sourceFile -> [ConformanceDeclaration] in
            guard let source = readSourceFile(sourceFile.shortPath, workspaceDirectory: workspaceDirectory)
                ?? readSourceFile(sourceFile.path, workspaceDirectory: workspaceDirectory)
            else {
                return []
            }
            return conformanceDeclarations(in: source)
        }
    }

    static func conformanceDeclarations(in source: String) -> [ConformanceDeclaration] {
        let syntax = Parser.parse(source: source)
        let visitor = ExtensionConformanceVisitor()
        visitor.walk(syntax)
        return visitor.declarations
    }

    fileprivate static func normalizedConformanceProtocolName(_ rawValue: String) -> String? {
        let tokens = rawValue
            .replacingOccurrences(of: "@retroactive", with: " ")
            .split { character in
                character.isWhitespace || character == "&"
            }
        guard let token = tokens.first else {
            return nil
        }
        return String(token)
    }

    private static func sourceContainsIdentifier(_ identifier: String, in source: String) -> Bool {
        let name = identifier.split(separator: ".").last.map(String.init) ?? identifier
        let pattern = #"(?<![A-Za-z0-9_])\#(NSRegularExpression.escapedPattern(for: name))(?![A-Za-z0-9_])"#
        return (try? NSRegularExpression(pattern: pattern))
            .map { regex in
                regex.firstMatch(in: source, range: NSRange(source.startIndex..<source.endIndex, in: source)) != nil
            } ?? false
    }

    private static func readSourceFile(_ path: String, workspaceDirectory: URL?) -> String? {
        let url: URL
        if path.hasPrefix("/") {
            url = URL(fileURLWithPath: path)
        } else if let workspaceDirectory {
            url = workspaceDirectory.appendingPathComponent(path)
        } else {
            url = URL(fileURLWithPath: path)
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}

private final class ExtensionConformanceVisitor: SyntaxVisitor {
    var declarations: [ConformanceDeclaration] = []

    init() {
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        guard let inheritanceClause = node.inheritanceClause else {
            return .visitChildren
        }

        let typeName = node.extendedType.description.trimmingCharacters(in: .whitespacesAndNewlines)
        declarations.append(contentsOf: inheritanceClause.inheritedTypes.compactMap { inheritedType in
            let rawProtocol = inheritedType.type.description.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let protocolName = ConformanceImportPreserver.normalizedConformanceProtocolName(rawProtocol) else {
                return nil
            }
            return ConformanceDeclaration(typeName: typeName, protocolName: protocolName)
        })

        return .visitChildren
    }
}
