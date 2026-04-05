import Foundation

public enum BatchAnalyzer {

    private struct ArtifactCatalog {
        let metadataFiles: [URL]
        let traceFileMap: [String: URL]
    }

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
        var warnings: [String] = []

        guard directoryExists(at: baseURL, fileManager: fm) else {
            return Output(
                results: [],
                warnings: ["Metadata root does not exist or is not a directory: \(baseURL.path)"]
            )
        }

        let artifacts = discoverArtifacts(in: baseURL, fileManager: fm)
        let filter = options.filter.map(TargetFilter.init)
        let indexStoreUsageByModule = loadIndexStoreUsage(
            storePath: options.indexStorePath,
            warnings: &warnings
        )

        let results = artifacts.metadataFiles.compactMap { metadataFile in
            analyzeTarget(
                metadataFile: metadataFile,
                artifacts: artifacts,
                bazelBin: options.bazelBin,
                fileManager: fm,
                extraSystemModules: options.extraSystemModules,
                filter: filter,
                indexStoreUsageByModule: indexStoreUsageByModule,
                warnings: &warnings
            )
        }

        return Output(results: results, warnings: warnings)
    }

    private static func directoryExists(at url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func discoverArtifacts(in baseURL: URL, fileManager: FileManager) -> ArtifactCatalog {
        var metadataFiles: [URL] = []
        var traceFileMap: [String: URL] = [:]

        if let enumerator = fileManager.enumerator(
            at: baseURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
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
        return ArtifactCatalog(metadataFiles: metadataFiles, traceFileMap: traceFileMap)
    }

    private static func loadIndexStoreUsage(
        storePath: String?,
        warnings: inout [String]
    ) -> [String: [SourceFileModuleUsage]] {
        guard let storePath else { return [:] }

        do {
            let usage = try IndexStoreReader.readModuleUsage(storePath: storePath)
            return Dictionary(grouping: usage, by: \.moduleName)
        } catch {
            warnings.append("Failed to read index store at '\(storePath)': \(error)")
            return [:]
        }
    }

    private static func analyzeTarget(
        metadataFile: URL,
        artifacts: ArtifactCatalog,
        bazelBin: String,
        fileManager: FileManager,
        extraSystemModules: Set<String>,
        filter: TargetFilter?,
        indexStoreUsageByModule: [String: [SourceFileModuleUsage]],
        warnings: inout [String]
    ) -> AnalysisResult? {
        guard let metadata = loadMetadata(from: metadataFile, warnings: &warnings) else {
            return nil
        }
        if let filter, !filter.matches(label: metadata.target.label) {
            return nil
        }

        guard let loadedModules = loadModules(
            for: metadata,
            artifacts: artifacts,
            bazelBin: bazelBin,
            fileManager: fileManager,
            indexStoreUsageByModule: indexStoreUsageByModule,
            warnings: &warnings
        ) else {
            return nil
        }

        let resolver = ModuleResolver(
            transitiveModuleMap: metadata.transitiveModuleMap,
            extraSystemModules: extraSystemModules
        )
        return Analyzer.analyze(
            metadata: metadata,
            loadedModules: loadedModules,
            resolver: resolver
        )
    }

    private static func loadMetadata(
        from metadataFile: URL,
        warnings: inout [String]
    ) -> TargetMetadata? {
        do {
            let data = try Data(contentsOf: metadataFile)
            return try JSONDecoder().decode(TargetMetadata.self, from: data)
        } catch {
            warnings.append("Failed to parse \(metadataFile.path): \(error)")
            return nil
        }
    }

    private static func loadModules(
        for metadata: TargetMetadata,
        artifacts: ArtifactCatalog,
        bazelBin: String,
        fileManager: FileManager,
        indexStoreUsageByModule: [String: [SourceFileModuleUsage]],
        warnings: inout [String]
    ) -> [LoadedModule]? {
        if let targetUsage = indexStoreUsageByModule[metadata.target.moduleName], !targetUsage.isEmpty {
            return deriveLoadedModules(from: targetUsage)
        }

        return loadTraceModules(
            metadata: metadata,
            traceFileMap: artifacts.traceFileMap,
            bazelBin: bazelBin,
            fm: fileManager,
            warnings: &warnings
        )
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
        .sorted { $0.name < $1.name }
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
