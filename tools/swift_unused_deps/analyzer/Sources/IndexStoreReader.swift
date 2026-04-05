import Foundation
import IndexStore

public struct SourceFileModuleUsage {
    public let sourceFile: String
    public let moduleName: String
    public let referencedModules: Set<String>

    public init(sourceFile: String, moduleName: String, referencedModules: Set<String>) {
        self.sourceFile = sourceFile
        self.moduleName = moduleName
        self.referencedModules = referencedModules
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

        // Pass 1: collect defined USRs per module and referenced USRs per source file.
        var moduleDefinedUSRs: [String: Set<String>] = [:]
        var sourceFileRefs: [(sourceFile: String, moduleName: String, referencedUSRs: Set<String>)] = []
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

            recordReader.forEach { (occurrence: SymbolOccurrence) in
                if occurrence.roles.contains(.definition) {
                    definedUSRs.insert(occurrence.symbol.usr)
                } else if occurrence.roles.contains(.reference) {
                    referencedUSRs.insert(occurrence.symbol.usr)
                }
            }

            let mod = unitReader.moduleName
            moduleDefinedUSRs[mod, default: []].formUnion(definedUSRs)

            if let filter = filterModules, !filter.contains(mod) { continue }

            sourceFileRefs.append((unitReader.mainFile, mod, referencedUSRs))
            seenFiles.insert(unitReader.mainFile)
        }

        // Pass 2: for each source file, determine which modules it actually uses
        // by checking if any USR defined in that module is referenced.
        var results: [SourceFileModuleUsage] = []

        for entry in sourceFileRefs {
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
                referencedModules: referencedModules
            ))
        }

        return results
    }
}
