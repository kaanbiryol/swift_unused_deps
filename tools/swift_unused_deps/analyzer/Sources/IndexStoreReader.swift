import Foundation
import IndexStore

public struct SourceFileModuleUsage {
    public let sourceFile: String
    public let isGenerated: Bool
    public let moduleName: String
    /// Modules whose symbols are actually referenced (USR cross-reference).
    public let referencedModules: Set<String>
    /// All modules the compiler loaded for this file (unit dependencies).
    public let loadedModules: Set<String>
    /// Loaded modules the compiler marked as system modules.
    public let systemModules: Set<String>
    /// Modules explicitly imported in source (`import X` statements).
    public let directImports: Set<String>
    /// Modules imported with `@_exported import`.
    public let reexportedImports: Set<String>
    /// Modules imported inside conditional compilation blocks.
    public let conditionalImports: Set<String>

    public init(
        sourceFile: String,
        isGenerated: Bool = false,
        moduleName: String,
        referencedModules: Set<String>,
        loadedModules: Set<String> = [],
        systemModules: Set<String> = [],
        directImports: Set<String> = [],
        reexportedImports: Set<String> = [],
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
        self.conditionalImports = conditionalImports
    }
}

public enum IndexStoreReader {

    private struct SourceUnitKey: Hashable {
        let sourceFile: String
        let moduleName: String
    }

    public struct Result {
        public let usage: [SourceFileModuleUsage]
    }

    public enum Error: Swift.Error, CustomStringConvertible {
        case storeOpenFailed(path: String, underlying: Swift.Error)

        public var description: String {
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
        let loadedModules: Set<String>
        let systemModules: Set<String>
        let directImports: Set<String>
        let reexportedImports: Set<String>
        let conditionalImports: Set<String>
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

    public static func readModuleUsage(
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
        let sourceLookup = SourceFileLookup(sourceFiles: sourceFiles)
        var sourceFileEntries: [SourceFileEntry] = []
        var seenSourceUnits = Set<SourceUnitKey>()

        read(
            store: store,
            sourceLookup: sourceLookup,
            collectsSourceEntries: true,
            moduleDefinedUSRs: &moduleDefinedUSRs,
            sourceFileEntries: &sourceFileEntries,
            seenSourceUnits: &seenSourceUnits
        )

        for definitionStorePath in definitionStorePaths where definitionStorePath != storePath {
            guard let definitionStore = try? IndexStore(path: definitionStorePath) else {
                continue
            }
            read(
                store: definitionStore,
                sourceLookup: nil,
                collectsSourceEntries: false,
                moduleDefinedUSRs: &moduleDefinedUSRs,
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

            results.append(SourceFileModuleUsage(
                sourceFile: entry.sourceFile,
                isGenerated: entry.isGenerated,
                moduleName: entry.moduleName,
                referencedModules: referencedModules,
                loadedModules: entry.loadedModules,
                systemModules: entry.systemModules,
                directImports: entry.directImports,
                reexportedImports: entry.reexportedImports,
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
            var directImports = Set<String>()
            var reexportedImports = Set<String>()
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
                directImports.formUnion(SourceImportEditor.importedModuleNames(in: source))
                reexportedImports.formUnion(SourceImportEditor.reexportedImportModuleNames(in: source))
                conditionalImports.formUnion(SourceImportEditor.conditionalImportModuleNames(in: source))
                importLineNumbers = SourceImportEditor.importLineNumbers(in: source)
            }

            recordReader.forEach { (occurrence: SymbolOccurrence) in
                if occurrence.roles.contains(.definition) {
                    definedUSRs.insert(occurrence.symbol.usr)
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
                    loadedModules: loadedModules,
                    systemModules: systemModules,
                    directImports: directImports,
                    reexportedImports: reexportedImports,
                    conditionalImports: conditionalImports
                ))
            }
            seenSourceUnits.insert(sourceUnitKey)
        }
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
