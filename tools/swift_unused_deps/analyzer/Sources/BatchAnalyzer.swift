import Foundation

enum BatchAnalyzer {

    struct Options {
        var bazelBin: String
        var indexStorePath: String?
        var dependencyIndexStorePaths: [String]
        var extraSystemModules: Set<String>
        var filter: String?
        var includedLabels: Set<String>?
        var labelConverter: LabelConverter
        var workspaceDirectory: URL?

        init(
            bazelBin: String,
            indexStorePath: String? = nil,
            dependencyIndexStorePaths: [String] = [],
            extraSystemModules: Set<String> = [],
            filter: String? = nil,
            includedLabels: Set<String>? = nil,
            labelConverter: LabelConverter = .identity,
            workspaceDirectory: URL? = nil
        ) {
            self.bazelBin = bazelBin
            self.indexStorePath = indexStorePath
            self.dependencyIndexStorePaths = dependencyIndexStorePaths
            self.extraSystemModules = extraSystemModules
            self.filter = filter
            self.includedLabels = includedLabels
            self.labelConverter = labelConverter
            self.workspaceDirectory = workspaceDirectory
        }
    }

    struct Output {
        let results: [AnalysisResult]
        let warnings: [String]
    }

    static func analyze(options: Options) -> Output {
        let baseURL = URL(fileURLWithPath: options.bazelBin, isDirectory: true)
        let fm = FileManager.default

        guard MetadataArtifactDiscovery.directoryExists(at: baseURL, fileManager: fm) else {
            return Output(
                results: [],
                warnings: ["Metadata root does not exist or is not a directory: \(baseURL.path)"]
            )
        }

        let artifacts = MetadataArtifactDiscovery.discover(in: baseURL, fileManager: fm)
        return analyze(metadataFiles: artifacts.metadataFiles, options: options)
    }

    static func analyze(metadataFiles: [URL], options: Options) -> Output {
        var warnings: [String] = []
        var indexStoreCache = IndexStoreUsageCache()
        let filter = options.filter.map(TargetFilter.init)
        let loadedMetadata = metadataFiles.compactMap { metadataFile -> TargetMetadata? in
            guard var metadata = MetadataArtifactDiscovery.loadMetadata(from: metadataFile, warnings: &warnings) else {
                return nil
            }
            let buildFileContent = MetadataArtifactDiscovery.readBuildFile(
                for: metadata.target.label,
                workspaceDirectory: options.workspaceDirectory
            )
            metadata = metadata.convertingLabels(
                with: options.labelConverter,
                buildFileContent: buildFileContent
            )
            return metadata
        }
        let metadataByLabel = loadedMetadata.reduce(into: [String: TargetMetadata]()) { partial, metadata in
            partial[metadata.target.label] = metadata
        }

        let results = loadedMetadata.compactMap { metadata in
            analyzeTarget(
                metadata: metadata,
                allMetadataByLabel: metadataByLabel,
                bazelBin: options.bazelBin,
                extraSystemModules: options.extraSystemModules,
                filter: filter,
                includedLabels: options.includedLabels,
                dependencyIndexStorePaths: options.dependencyIndexStorePaths,
                indexStoreOverridePath: options.indexStorePath,
                workspaceDirectory: options.workspaceDirectory,
                indexStoreCache: &indexStoreCache,
                warnings: &warnings
            )
        }

        return Output(results: results, warnings: warnings)
    }

    private static func analyzeTarget(
        metadata: TargetMetadata,
        allMetadataByLabel: [String: TargetMetadata],
        bazelBin: String,
        extraSystemModules: Set<String>,
        filter: TargetFilter?,
        includedLabels: Set<String>?,
        dependencyIndexStorePaths: [String],
        indexStoreOverridePath: String?,
        workspaceDirectory: URL?,
        indexStoreCache: inout IndexStoreUsageCache,
        warnings: inout [String]
    ) -> AnalysisResult? {
        if let includedLabels {
            guard includedLabels.contains(metadata.target.label) else { return nil }
        } else if let filter, !filter.matches(label: metadata.target.label) {
            return nil
        }
        let rawSourceFileUsage = IndexStoreUsageLoader.load(
            for: metadata,
            allMetadataByLabel: allMetadataByLabel,
            bazelBin: bazelBin,
            overridePath: indexStoreOverridePath,
            dependencyIndexStorePaths: dependencyIndexStorePaths,
            cache: &indexStoreCache,
            warnings: &warnings
        )
        let sourceFileUsage = ConformanceImportPreserver.preserve(
            in: UnusedImportAnalyzer.filterReferencedModules(
                rawSourceFileUsage,
                for: metadata,
                extraSystemModules: extraSystemModules
            ),
            metadata: metadata,
            allMetadataByLabel: allMetadataByLabel,
            workspaceDirectory: workspaceDirectory
        )

        guard let loadedModules = loadModules(
            for: metadata,
            sourceFileUsage: sourceFileUsage,
            warnings: &warnings
        ) else {
            return nil
        }

        let resolver = ModuleResolver(
            transitiveModuleMap: metadata.transitiveModuleMap,
            extraSystemModules: extraSystemModules
        )
        let baseResult = Analyzer.analyze(
            metadata: metadata,
            loadedModules: loadedModules,
            resolver: resolver
        )
        let unusedImportIssues = UnusedImportAnalyzer.issues(
            metadata: metadata,
            sourceFileUsage: sourceFileUsage
        )
        return UnusedImportAnalyzer.merge(
            baseResult: baseResult,
            unusedImportIssues: unusedImportIssues
        )
    }

    private static func loadModules(
        for metadata: TargetMetadata,
        sourceFileUsage: [SourceFileModuleUsage],
        warnings: inout [String]
    ) -> [LoadedModule]? {
        guard !sourceFileUsage.isEmpty else {
            warnings.append(
                "No index-store data found for \(metadata.target.label) (module: \(metadata.target.moduleName)). " +
                    "Verify swift.index_while_building is enabled and the metadata indexstore_path exists."
            )
            return nil
        }

        return deriveLoadedModules(from: sourceFileUsage)
    }

    /// Derive LoadedModule list from index store data.
    ///
    /// Direct imports remain "loaded" even when no symbols are referenced from
    /// them. The import still requires a compilable dep, so auto-fix must not
    /// treat that dep as safely removable.
    static func deriveLoadedModules(
        from targetUsage: [SourceFileModuleUsage]
    ) -> [LoadedModule] {
        var allDirectImports = Set<String>()
        var allKnownModules = Set<String>()
        var allSystemModules = Set<String>()

        for usage in targetUsage {
            allKnownModules.formUnion(usage.loadedModules)
            allKnownModules.formUnion(usage.directImports)
            allKnownModules.formUnion(usage.referencedModules)
            allSystemModules.formUnion(usage.systemModules)
            allDirectImports.formUnion(usage.directImports)
        }

        return allKnownModules.compactMap { moduleName in
            let isDirectlyImported = allDirectImports.contains(moduleName)
            return LoadedModule(
                name: moduleName,
                isImportedDirectly: isDirectlyImported,
                isSystem: allSystemModules.contains(moduleName)
            )
        }
        .sorted { $0.name < $1.name }
    }

}
