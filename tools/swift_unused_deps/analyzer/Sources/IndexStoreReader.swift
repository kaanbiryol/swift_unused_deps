import Foundation
import IndexStore

struct SourceFileModuleUsage {
    let sourceFile: String
    let isGenerated: Bool
    let moduleName: String
    /// Modules whose symbols are actually referenced (USR cross-reference).
    let referencedModules: Set<String>
    /// All modules the compiler loaded for this file (unit dependencies).
    let loadedModules: Set<String>
    /// Loaded modules the compiler marked as system modules.
    let systemModules: Set<String>
    /// Modules explicitly imported in source (`import X` statements).
    let directImports: Set<String>
    /// Modules imported with `@_exported import`.
    let reexportedImports: Set<String>
    /// Modules imported with `@testable import`.
    let testableImports: Set<String>
    /// `@testable` imports that reference at least one declaration unavailable
    /// through a plain import.
    let requiredTestableImports: Set<String>
    /// `@testable` imports whose indexed references all resolve to public API.
    /// Imports absent from both sets could not be classified safely.
    let unnecessaryTestableImports: Set<String>
    /// Modules imported inside conditional compilation blocks.
    let conditionalImports: Set<String>

    init(
        sourceFile: String,
        isGenerated: Bool = false,
        moduleName: String,
        referencedModules: Set<String>,
        loadedModules: Set<String> = [],
        systemModules: Set<String> = [],
        directImports: Set<String> = [],
        reexportedImports: Set<String> = [],
        testableImports: Set<String> = [],
        requiredTestableImports: Set<String> = [],
        unnecessaryTestableImports: Set<String> = [],
        conditionalImports: Set<String> = []
    ) {
        self.sourceFile = sourceFile
        self.isGenerated = isGenerated
        self.moduleName = moduleName
        self.referencedModules = referencedModules
        self.loadedModules = loadedModules
        self.systemModules = systemModules
        self.directImports = directImports
        self.reexportedImports = reexportedImports
        self.testableImports = testableImports
        self.requiredTestableImports = requiredTestableImports
        self.unnecessaryTestableImports = unnecessaryTestableImports
        self.conditionalImports = conditionalImports
    }
}

enum IndexStoreReader {

    private struct SourceUnitKey: Hashable {
        let sourceFile: String
        let moduleName: String
    }

    struct Result {
        let usage: [SourceFileModuleUsage]
    }

    enum Error: Swift.Error, CustomStringConvertible {
        case storeOpenFailed(path: String, underlying: Swift.Error)

        var description: String {
            switch self {
            case .storeOpenFailed(let path, let error):
                return "Failed to open index store at '\(path)': \(error)"
            }
        }
    }

    private struct ResolvedSourceFile {
        let readablePath: String?
        let reportPath: String
        let isGenerated: Bool
    }

    private struct SourceFileEntry {
        let sourceFile: String
        let isGenerated: Bool
        let moduleName: String
        let referencedUSRs: Set<String>
        let overrideUSRs: Set<String>
        let loadedModules: Set<String>
        let systemModules: Set<String>
        let directImports: Set<String>
        let reexportedImports: Set<String>
        let testableImports: Set<String>
        let conditionalImports: Set<String>
    }

    private enum TestableDefinitionAccess: Equatable {
        case accessibleWithoutTestable
        case requiresTestable
        case publicButNotOpen
        case ignored
        case unknown

        func resolved(isOverride: Bool) -> TestableDefinitionAccess {
            if self == .publicButNotOpen {
                return isOverride ? .requiresTestable : .accessibleWithoutTestable
            }
            return self
        }
    }

    private enum TestableImportRequirement {
        case required
        case unnecessary
    }

    private struct SourceFileLookup {
        let sourceFiles: [SourceFileMetadata]
        let fileManager = FileManager.default

        func resolve(_ indexStorePath: String) -> ResolvedSourceFile {
            if let exact = bestSourceFileMatch(for: indexStorePath) {
                return ResolvedSourceFile(
                    readablePath: readablePath(for: exact) ?? readableIndexStorePath(indexStorePath),
                    reportPath: reportPath(for: exact),
                    isGenerated: exact.isGenerated || exact.shortPath.hasPrefix("../")
                )
            }

            if fileManager.fileExists(atPath: indexStorePath) {
                return ResolvedSourceFile(
                    readablePath: indexStorePath,
                    reportPath: indexStorePath,
                    isGenerated: false
                )
            }

            let basename = URL(fileURLWithPath: indexStorePath).lastPathComponent
            let basenameMatches = sourceFiles.filter { $0.basename == basename }
            if basenameMatches.count == 1, let match = basenameMatches.first {
                return ResolvedSourceFile(
                    readablePath: readablePath(for: match),
                    reportPath: reportPath(for: match),
                    isGenerated: match.isGenerated || match.shortPath.hasPrefix("../")
                )
            }

            return ResolvedSourceFile(
                readablePath: nil,
                reportPath: indexStorePath,
                isGenerated: false
            )
        }

        private func bestSourceFileMatch(for indexStorePath: String) -> SourceFileMetadata? {
            let normalizedIndexPath = normalize(indexStorePath)
            return sourceFiles
                .filter { source in
                    let candidates = [source.path, source.shortPath].map(normalize)
                    return candidates.contains { candidate in
                        normalizedIndexPath == candidate || normalizedIndexPath.hasSuffix("/" + candidate)
                    }
                }
                .max { lhs, rhs in
                    max(lhs.path.count, lhs.shortPath.count) < max(rhs.path.count, rhs.shortPath.count)
                }
        }

        private func readablePath(for source: SourceFileMetadata) -> String? {
            for path in [source.path, source.shortPath] where fileManager.fileExists(atPath: path) {
                return path
            }
            return nil
        }

        private func readableIndexStorePath(_ path: String) -> String? {
            fileManager.fileExists(atPath: path) ? path : nil
        }

        private func reportPath(for source: SourceFileMetadata) -> String {
            if !source.shortPath.isEmpty {
                if source.shortPath.hasPrefix("./") {
                    return String(source.shortPath.dropFirst(2))
                }
                return source.shortPath
            }
            return source.path
        }

        private func normalize(_ path: String) -> String {
            path.replacingOccurrences(of: "\\", with: "/")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
    }

    static func readModuleUsage(
        storePath: String,
        sourceFiles: [SourceFileMetadata] = [],
        definitionStorePaths: [String] = []
    ) throws -> Result {
        let store: IndexStore
        do {
            store = try IndexStore(path: storePath)
        } catch {
            throw Error.storeOpenFailed(path: storePath, underlying: error)
        }

        // Pass 1: gather defined USRs per module and per-file data. Definition
        // stores from direct dependencies let us attribute extension members to
        // the module that defines them, even when the USR is attached to an
        // extended type from another module.
        var moduleDefinedUSRs: [String: Set<String>] = [:]
        var definitionAccessByModuleUSR: [String: [String: [TestableDefinitionAccess]]] = [:]
        var sourceLinesByPath: [String: [String]?] = [:]
        let sourceLookup = SourceFileLookup(sourceFiles: sourceFiles)
        var sourceFileEntries: [SourceFileEntry] = []
        var seenSourceUnits = Set<SourceUnitKey>()

        read(
            store: store,
            sourceLookup: sourceLookup,
            collectsSourceEntries: true,
            moduleDefinedUSRs: &moduleDefinedUSRs,
            definitionAccessByModuleUSR: &definitionAccessByModuleUSR,
            sourceLinesByPath: &sourceLinesByPath,
            sourceFileEntries: &sourceFileEntries,
            seenSourceUnits: &seenSourceUnits
        )

        for definitionStorePath in definitionStorePaths where definitionStorePath != storePath {
            guard let definitionStore = try? IndexStore(path: definitionStorePath) else {
                continue
            }
            read(
                store: definitionStore,
                sourceLookup: sourceLookup,
                collectsSourceEntries: false,
                moduleDefinedUSRs: &moduleDefinedUSRs,
                definitionAccessByModuleUSR: &definitionAccessByModuleUSR,
                sourceLinesByPath: &sourceLinesByPath,
                sourceFileEntries: &sourceFileEntries,
                seenSourceUnits: &seenSourceUnits
            )
        }

        // Pass 2: resolve referenced modules via USR cross-reference.
        var results: [SourceFileModuleUsage] = []

        for entry in sourceFileEntries {
            var referencedModules = Set<String>()
            for (mod, definedUSRs) in moduleDefinedUSRs {
                if mod == entry.moduleName { continue }
                if !definedUSRs.isDisjoint(with: entry.referencedUSRs) {
                    referencedModules.insert(mod)
                }
            }

            for usr in entry.referencedUSRs {
                guard let module = moduleName(fromUSR: usr) else {
                    continue
                }
                if module != entry.moduleName {
                    referencedModules.insert(module)
                }
            }

            var requiredTestableImports = Set<String>()
            var unnecessaryTestableImports = Set<String>()
            for moduleName in entry.testableImports where referencedModules.contains(moduleName) {
                switch testableImportRequirement(
                    moduleName: moduleName,
                    referencedUSRs: entry.referencedUSRs,
                    overrideUSRs: entry.overrideUSRs,
                    definitionAccessByModuleUSR: definitionAccessByModuleUSR
                ) {
                case .required:
                    requiredTestableImports.insert(moduleName)
                case .unnecessary:
                    unnecessaryTestableImports.insert(moduleName)
                case nil:
                    break
                }
            }

            results.append(SourceFileModuleUsage(
                sourceFile: entry.sourceFile,
                isGenerated: entry.isGenerated,
                moduleName: entry.moduleName,
                referencedModules: referencedModules,
                loadedModules: entry.loadedModules,
                systemModules: entry.systemModules,
                directImports: entry.directImports,
                reexportedImports: entry.reexportedImports,
                testableImports: entry.testableImports,
                requiredTestableImports: requiredTestableImports,
                unnecessaryTestableImports: unnecessaryTestableImports,
                conditionalImports: entry.conditionalImports
            ))
        }

        return Result(usage: results)
    }

    private static func read(
        store: IndexStore,
        sourceLookup: SourceFileLookup?,
        collectsSourceEntries: Bool,
        moduleDefinedUSRs: inout [String: Set<String>],
        definitionAccessByModuleUSR: inout [String: [String: [TestableDefinitionAccess]]],
        sourceLinesByPath: inout [String: [String]?],
        sourceFileEntries: inout [SourceFileEntry],
        seenSourceUnits: inout Set<SourceUnitKey>
    ) {
        for unitReader in store.units {
            if unitReader.mainFile.isEmpty { continue }
            let mod = unitReader.moduleName
            let sourceUnitKey = SourceUnitKey(sourceFile: unitReader.mainFile, moduleName: mod)
            if seenSourceUnits.contains(sourceUnitKey) { continue }

            guard let recordName = unitReader.recordName else { continue }
            let recordReader: RecordReader
            do {
                recordReader = try RecordReader(indexStore: store, recordName: recordName)
            } catch {
                continue
            }

            var definedUSRs = Set<String>()
            var referencedUSRs = Set<String>()
            var overrideUSRs = Set<String>()
            var directImports = Set<String>()
            var reexportedImports = Set<String>()
            var testableImports = Set<String>()
            var conditionalImports = Set<String>()
            var importLineNumbers = Set<Int>()
            let resolvedSource = sourceLookup?.resolve(unitReader.mainFile) ?? ResolvedSourceFile(
                readablePath: nil,
                reportPath: unitReader.mainFile,
                isGenerated: false
            )

            if collectsSourceEntries,
               let readablePath = resolvedSource.readablePath,
               let source = try? String(contentsOfFile: readablePath, encoding: .utf8) {
                let importSummary = SourceImportEditor.importSummary(in: source)
                directImports.formUnion(importSummary.importedModuleNames)
                reexportedImports.formUnion(importSummary.reexportedImportModuleNames)
                testableImports.formUnion(importSummary.testableImportModuleNames)
                conditionalImports.formUnion(importSummary.conditionalImportModuleNames)
                importLineNumbers = importSummary.importLineNumbers
            }

            recordReader.forEach { (occurrence: SymbolOccurrence) in
                if occurrence.roles.contains(.definition) {
                    definedUSRs.insert(occurrence.symbol.usr)
                    let access = testableDefinitionAccess(
                        occurrence,
                        sourcePath: resolvedSource.readablePath,
                        sourceLinesByPath: &sourceLinesByPath
                    )
                    definitionAccessByModuleUSR[mod, default: [:]][occurrence.symbol.usr, default: []]
                        .append(access)
                } else if collectsSourceEntries, occurrence.roles.contains(.reference) {
                    // Symbol-scoped imports like `import struct LibA.Type` appear as
                    // references in the index store, but they are import declarations,
                    // not semantic usage sites.
                    if !importLineNumbers.contains(occurrence.location.line) {
                        referencedUSRs.insert(occurrence.symbol.usr)
                    }
                    if occurrence.symbol.kind == .module {
                        directImports.insert(occurrence.symbol.name)
                    }
                    if occurrence.roles.contains(.overrideOf) || occurrence.roles.contains(.baseOf) {
                        overrideUSRs.insert(occurrence.symbol.usr)
                    }
                }
            }

            // Gather loaded modules from unit dependencies.
            var loadedModules = Set<String>()
            var systemModules = Set<String>()
            if collectsSourceEntries {
                unitReader.forEach(dependency: { dep in
                    if dep.kind == .unit && !dep.moduleName.isEmpty {
                        loadedModules.insert(dep.moduleName)
                        if dep.isSystem {
                            systemModules.insert(dep.moduleName)
                        }
                    }
                })
            }

            moduleDefinedUSRs[mod, default: []].formUnion(definedUSRs)

            if collectsSourceEntries {
                sourceFileEntries.append(SourceFileEntry(
                    sourceFile: resolvedSource.reportPath,
                    isGenerated: resolvedSource.isGenerated,
                    moduleName: mod,
                    referencedUSRs: referencedUSRs,
                    overrideUSRs: overrideUSRs,
                    loadedModules: loadedModules,
                    systemModules: systemModules,
                    directImports: directImports,
                    reexportedImports: reexportedImports,
                    testableImports: testableImports,
                    conditionalImports: conditionalImports
                ))
            }
            seenSourceUnits.insert(sourceUnitKey)
        }
    }

    private static func testableImportRequirement(
        moduleName: String,
        referencedUSRs: Set<String>,
        overrideUSRs: Set<String>,
        definitionAccessByModuleUSR: [String: [String: [TestableDefinitionAccess]]]
    ) -> TestableImportRequirement? {
        let definitionsByUSR = definitionAccessByModuleUSR[moduleName] ?? [:]
        let moduleUSRs = referencedUSRs.filter { usr in
            definitionsByUSR[usr] != nil || self.moduleName(fromUSR: usr) == moduleName
        }
        guard !moduleUSRs.isEmpty else { return nil }

        var sawClassifiableDefinition = false
        var sawUnknownDefinition = false

        for usr in moduleUSRs {
            guard let definitions = definitionsByUSR[usr], !definitions.isEmpty else {
                sawUnknownDefinition = true
                continue
            }

            for definition in definitions {
                switch definition.resolved(isOverride: overrideUSRs.contains(usr)) {
                case .requiresTestable:
                    return .required
                case .accessibleWithoutTestable:
                    sawClassifiableDefinition = true
                case .unknown:
                    sawUnknownDefinition = true
                case .ignored:
                    break
                case .publicButNotOpen:
                    preconditionFailure("publicButNotOpen must be resolved before classification")
                }
            }
        }

        guard sawClassifiableDefinition, !sawUnknownDefinition else { return nil }
        return .unnecessary
    }

    private static func testableDefinitionAccess(
        _ occurrence: SymbolOccurrence,
        sourcePath: String?,
        sourceLinesByPath: inout [String: [String]?]
    ) -> TestableDefinitionAccess {
        if isChildOfProtocol(occurrence) || isGetterOrSetterFunction(occurrence) {
            return .ignored
        }

        if occurrence.roles.contains(.implicit) {
            return .requiresTestable
        }

        if occurrence.symbol.kind == .enumConstant {
            return .accessibleWithoutTestable
        }

        guard let sourcePath else { return .unknown }
        let lines: [String]?
        if let cached = sourceLinesByPath[sourcePath] {
            lines = cached
        } else {
            lines = try? String(contentsOfFile: sourcePath, encoding: .utf8)
                .components(separatedBy: .newlines)
            sourceLinesByPath[sourcePath] = lines
        }
        guard let lines,
              occurrence.location.line > 0,
              occurrence.location.line <= lines.count
        else {
            return .unknown
        }

        let line = lines[occurrence.location.line - 1]
        if line.contains("open ") {
            return .accessibleWithoutTestable
        }
        if line.contains("public ") {
            return line.contains(" internal(") ? .requiresTestable : .publicButNotOpen
        }
        return .requiresTestable
    }

    private static func isChildOfProtocol(_ occurrence: SymbolOccurrence) -> Bool {
        let protocolMemberKinds: [SymbolKind] = [
            .instanceMethod,
            .classMethod,
            .staticMethod,
            .instanceProperty,
            .classProperty,
            .staticProperty,
        ]
        guard protocolMemberKinds.contains(occurrence.symbol.kind) else { return false }

        var result = false
        occurrence.forEach { symbol, roles in
            if roles.contains(.childOf), symbol.kind == .protocol {
                result = true
            }
        }
        return result
    }

    private static func isGetterOrSetterFunction(_ occurrence: SymbolOccurrence) -> Bool {
        let functionKinds: [SymbolKind] = [.classMethod, .instanceMethod, .staticMethod]
        return functionKinds.contains(occurrence.symbol.kind)
            && occurrence.roles.contains(.accessorOf)
    }

    static func moduleName(fromUSR usr: String) -> String? {
        if usr.hasPrefix("c:@M@") {
            return String(usr.dropFirst("c:@M@".count).prefix(while: isModuleNameCharacter))
        }

        var cursor = usr.startIndex
        while cursor < usr.endIndex {
            guard usr[cursor] == ":" else {
                cursor = usr.index(after: cursor)
                continue
            }

            let lengthStart = usr.index(after: cursor)
            var lengthEnd = lengthStart
            while lengthEnd < usr.endIndex, usr[lengthEnd].wholeNumberValue != nil {
                lengthEnd = usr.index(after: lengthEnd)
            }

            guard lengthEnd > lengthStart,
                  let length = Int(usr[lengthStart..<lengthEnd]),
                  let moduleEnd = usr.index(lengthEnd, offsetBy: length, limitedBy: usr.endIndex)
            else {
                cursor = lengthStart
                continue
            }

            let module = String(usr[lengthEnd..<moduleEnd])
            if !module.isEmpty, module.allSatisfy(isModuleNameCharacter) {
                return module
            }

            cursor = lengthEnd
        }

        return nil
    }

    private static func isModuleNameCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }
}
