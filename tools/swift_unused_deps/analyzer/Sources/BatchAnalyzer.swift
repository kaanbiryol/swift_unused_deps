import Foundation

public enum BatchAnalyzer {

    public struct Options {
        public var bazelBin: String
        public var indexStorePath: String?
        public var extraSystemModules: Set<String>
        public var filter: String?

        public init(
            bazelBin: String,
            indexStorePath: String? = nil,
            extraSystemModules: Set<String> = [],
            filter: String? = nil
        ) {
            self.bazelBin = bazelBin
            self.indexStorePath = indexStorePath
            self.extraSystemModules = extraSystemModules
            self.filter = filter
        }
    }

    public struct Output {
        public let results: [AnalysisResult]
        public let warnings: [String]
    }

    public static func analyze(options: Options) -> Output {
        let baseURL = URL(fileURLWithPath: options.bazelBin, isDirectory: true)
        let fm = FileManager.default

        var metadataFiles: [URL] = []
        var traceFileMap: [String: URL] = [:]
        var warnings: [String] = []

        var isDirectory: ObjCBool = false
        if !fm.fileExists(atPath: baseURL.path, isDirectory: &isDirectory) || !isDirectory.boolValue {
            return Output(
                results: [],
                warnings: ["Metadata root does not exist or is not a directory: \(baseURL.path)"]
            )
        }

        if let enumerator = fm.enumerator(at: baseURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator {
                let name = url.lastPathComponent
                if name.hasSuffix(".swift_deps_info.json") {
                    metadataFiles.append(url)
                } else if name.hasSuffix(".trace.json") {
                    let moduleName = String(name.dropLast(".trace.json".count))
                    traceFileMap[moduleName] = url
                }
            }
        }
        metadataFiles.sort { $0.path < $1.path }

        let indexStoreUsage: [SourceFileModuleUsage]
        if let storePath = options.indexStorePath {
            do {
                indexStoreUsage = try IndexStoreReader.readModuleUsage(storePath: storePath)
            } catch {
                indexStoreUsage = []
                warnings.append("Failed to read index store at '\(storePath)': \(error)")
            }
        } else {
            indexStoreUsage = []
        }

        var results: [AnalysisResult] = []

        for metaFile in metadataFiles {
            let metadata: TargetMetadata
            do {
                let data = try Data(contentsOf: metaFile)
                metadata = try JSONDecoder().decode(TargetMetadata.self, from: data)
            } catch {
                warnings.append("Failed to parse \(metaFile.path): \(error)")
                continue
            }

            if let pattern = options.filter {
                let prefix = pattern.replacingOccurrences(of: "...", with: "")
                    .replacingOccurrences(of: "@@", with: "")
                let targetClean = metadata.target.label.replacingOccurrences(of: "@@", with: "")
                if !targetClean.hasPrefix(prefix) { continue }
            }

            let loadedModules: [LoadedModule]

            // Prefer index store (no compiler flags needed). Fall back to traces.
            let targetUsage = indexStoreUsage.filter { $0.moduleName == metadata.target.moduleName }
            if !targetUsage.isEmpty {
                loadedModules = deriveLoadedModules(from: targetUsage)
            } else if let traceModules = loadTraceModules(
                metadata: metadata, traceFileMap: traceFileMap,
                bazelBin: options.bazelBin, fm: fm, warnings: &warnings
            ) {
                loadedModules = traceModules
            } else {
                continue
            }

            let resolver = ModuleResolver(
                transitiveModuleMap: metadata.transitiveModuleMap,
                extraSystemModules: options.extraSystemModules
            )
            let result = Analyzer.analyze(
                metadata: metadata,
                loadedModules: loadedModules,
                resolver: resolver
            )
            results.append(result)
        }

        return Output(results: results, warnings: warnings)
    }

    /// Derive LoadedModule list from index store data.
    /// Filters out modules that are directly imported but have no symbol references.
    private static func deriveLoadedModules(from targetUsage: [SourceFileModuleUsage]) -> [LoadedModule] {
        var allDirectImports = Set<String>()
        var allReferenced = Set<String>()
        var allKnownModules = Set<String>()

        for usage in targetUsage {
            allKnownModules.formUnion(usage.loadedModules)
            allKnownModules.formUnion(usage.directImports)
            allKnownModules.formUnion(usage.referencedModules)
            allDirectImports.formUnion(usage.directImports)
            allReferenced.formUnion(usage.referencedModules)
        }

        return allKnownModules.compactMap { moduleName in
            let isDirectlyImported = allDirectImports.contains(moduleName)
            if isDirectlyImported && !allReferenced.contains(moduleName) {
                return nil
            }
            return LoadedModule(name: moduleName, isImportedDirectly: isDirectlyImported)
        }
    }

    /// Fall back to trace-based module loading.
    private static func loadTraceModules(
        metadata: TargetMetadata,
        traceFileMap: [String: URL],
        bazelBin: String,
        fm: FileManager,
        warnings: inout [String]
    ) -> [LoadedModule]? {
        var traceURL = traceFileMap[metadata.target.moduleName]
        if traceURL == nil && !metadata.traceFile.isEmpty {
            let candidate = URL(fileURLWithPath: bazelBin).appendingPathComponent(metadata.traceFile)
            if fm.fileExists(atPath: candidate.path) {
                traceURL = candidate
            }
        }

        guard let traceFile = traceURL else { return nil }

        do {
            return try TraceParser.parseTraceFile(at: traceFile, forModule: metadata.target.moduleName)
        } catch {
            warnings.append("Failed to parse trace for \(metadata.target.label): \(error)")
            return nil
        }
    }
}
