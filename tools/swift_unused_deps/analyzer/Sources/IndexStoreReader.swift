import Foundation
import IndexStore

public struct SourceFileModuleUsage {
    public let sourceFile: String
    public let moduleName: String
    /// Modules whose symbols are actually referenced (USR cross-reference).
    public let referencedModules: Set<String>
    /// All modules the compiler loaded for this file (unit dependencies).
    public let loadedModules: Set<String>
    /// Modules explicitly imported in source (`import X` statements).
    public let directImports: Set<String>

    public init(
        sourceFile: String,
        moduleName: String,
        referencedModules: Set<String>,
        loadedModules: Set<String> = [],
        directImports: Set<String> = []
    ) {
        self.sourceFile = sourceFile
        self.moduleName = moduleName
        self.referencedModules = referencedModules
        self.loadedModules = loadedModules
        self.directImports = directImports
    }
}

public enum IndexStoreReader {

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
    ) throws -> [SourceFileModuleUsage] {
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
            directImports: Set<String>
        )] = []
        var seenFiles = Set<String>()

        for unitReader in store.units {
            if unitReader.mainFile.isEmpty { continue }
            if seenFiles.contains(unitReader.mainFile) { continue }

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

            recordReader.forEach { (occurrence: SymbolOccurrence) in
                if occurrence.roles.contains(.definition) {
                    definedUSRs.insert(occurrence.symbol.usr)
                } else if occurrence.roles.contains(.reference) {
                    referencedUSRs.insert(occurrence.symbol.usr)
                    if occurrence.symbol.kind == .module {
                        directImports.insert(occurrence.symbol.name)
                    }
                }
            }

            // Collect loaded modules from unit dependencies.
            var loadedModules = Set<String>()
            unitReader.forEach(dependency: { dep in
                if dep.kind == .unit && !dep.moduleName.isEmpty && !dep.isSystem {
                    loadedModules.insert(dep.moduleName)
                }
            })

            let mod = unitReader.moduleName
            moduleDefinedUSRs[mod, default: []].formUnion(definedUSRs)

            if let filter = filterModules, !filter.contains(mod) { continue }

            sourceFileEntries.append((
                unitReader.mainFile, mod, referencedUSRs, loadedModules, directImports
            ))
            seenFiles.insert(unitReader.mainFile)
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
                directImports: entry.directImports
            ))
        }

        return results
    }
}
