import Foundation
import IndexStore

public struct SourceFileModuleUsage {
    public let sourceFile: String
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
        moduleName: String,
        referencedModules: Set<String>,
        loadedModules: Set<String> = [],
        systemModules: Set<String> = [],
        directImports: Set<String> = [],
        reexportedImports: Set<String> = [],
        conditionalImports: Set<String> = []
    ) {
        self.sourceFile = sourceFile
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
        /// Module names that have defined symbols (records) in the index store.
        public let indexedModules: Set<String>
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

    public static func readModuleUsage(
        storePath: String,
        filterModules: Set<String>? = nil
    ) throws -> Result {
        let store: IndexStore
        do {
            store = try IndexStore(path: storePath)
        } catch {
            throw Error.storeOpenFailed(path: storePath, underlying: error)
        }

        // Pass 1: collect defined USRs per module and per-file data.
        var moduleDefinedUSRs: [String: Set<String>] = [:]
        var sourceFileEntries: [(
            sourceFile: String,
            moduleName: String,
            referencedUSRs: Set<String>,
            loadedModules: Set<String>,
            systemModules: Set<String>,
            directImports: Set<String>,
            reexportedImports: Set<String>,
            conditionalImports: Set<String>
        )] = []
        var seenSourceUnits = Set<SourceUnitKey>()

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

            if let source = try? String(contentsOfFile: unitReader.mainFile, encoding: .utf8) {
                directImports.formUnion(SourceImportEditor.importedModuleNames(in: source))
                reexportedImports.formUnion(SourceImportEditor.reexportedImportModuleNames(in: source))
                conditionalImports.formUnion(SourceImportEditor.conditionalImportModuleNames(in: source))
                importLineNumbers = SourceImportEditor.importLineNumbers(in: source)
            }

            recordReader.forEach { (occurrence: SymbolOccurrence) in
                if occurrence.roles.contains(.definition) {
                    definedUSRs.insert(occurrence.symbol.usr)
                } else if occurrence.roles.contains(.reference) {
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

            // Collect loaded modules from unit dependencies.
            var loadedModules = Set<String>()
            var systemModules = Set<String>()
            unitReader.forEach(dependency: { dep in
                if dep.kind == .unit && !dep.moduleName.isEmpty {
                    loadedModules.insert(dep.moduleName)
                    if dep.isSystem {
                        systemModules.insert(dep.moduleName)
                    }
                }
            })

            moduleDefinedUSRs[mod, default: []].formUnion(definedUSRs)

            if let filter = filterModules, !filter.contains(mod) { continue }

            sourceFileEntries.append((
                unitReader.mainFile, mod, referencedUSRs, loadedModules, systemModules, directImports, reexportedImports,
                conditionalImports
            ))
            seenSourceUnits.insert(sourceUnitKey)
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

            results.append(SourceFileModuleUsage(
                sourceFile: entry.sourceFile,
                moduleName: entry.moduleName,
                referencedModules: referencedModules,
                loadedModules: entry.loadedModules,
                systemModules: entry.systemModules,
                directImports: entry.directImports,
                reexportedImports: entry.reexportedImports,
                conditionalImports: entry.conditionalImports
            ))
        }

        return Result(
            usage: results,
            indexedModules: Set(moduleDefinedUSRs.keys)
        )
    }
}
