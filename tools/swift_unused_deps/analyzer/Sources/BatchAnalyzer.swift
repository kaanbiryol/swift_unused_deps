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
        public var labelConverter: LabelConverter
        public var workspaceDirectory: URL?

        public init(
            bazelBin: String,
            indexStorePath: String? = nil,
            extraSystemModules: Set<String> = [],
            filter: String? = nil,
            labelConverter: LabelConverter = .identity,
            workspaceDirectory: URL? = nil
        ) {
            self.bazelBin = bazelBin
            self.indexStorePath = indexStorePath
            self.extraSystemModules = extraSystemModules
            self.filter = filter
            self.labelConverter = labelConverter
            self.workspaceDirectory = workspaceDirectory
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
        var indexStoreCache: [String: IndexStoreData] = [:]

        guard directoryExists(at: baseURL, fileManager: fm) else {
            return Output(
                results: [],
                warnings: ["Metadata root does not exist or is not a directory: \(baseURL.path)"]
            )
        }

        let artifacts = discoverArtifacts(in: baseURL, fileManager: fm)
        let filter = options.filter.map(TargetFilter.init)

        let results = artifacts.metadataFiles.compactMap { metadataFile in
            analyzeTarget(
                metadataFile: metadataFile,
                artifacts: artifacts,
                bazelBin: options.bazelBin,
                fileManager: fm,
                extraSystemModules: options.extraSystemModules,
                filter: filter,
                labelConverter: options.labelConverter,
                workspaceDirectory: options.workspaceDirectory,
                indexStoreOverridePath: options.indexStorePath,
                indexStoreCache: &indexStoreCache,
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

    private struct IndexStoreData {
        let usageByModule: [String: [SourceFileModuleUsage]]

        static let empty = IndexStoreData(usageByModule: [:])
    }

    private static func loadIndexStoreData(
        storePath: String?,
        warnings: inout [String]
    ) -> IndexStoreData {
        guard let storePath else { return .empty }

        do {
            let result = try IndexStoreReader.readModuleUsage(storePath: storePath)
            return IndexStoreData(
                usageByModule: Dictionary(grouping: result.usage, by: \.moduleName)
            )
        } catch {
            warnings.append("Failed to read index store at '\(storePath)': \(error)")
            return .empty
        }
    }

    private static func loadIndexStoreUsage(
        for metadata: TargetMetadata,
        bazelBin: String,
        overridePath: String?,
        cache: inout [String: IndexStoreData],
        warnings: inout [String]
    ) -> [SourceFileModuleUsage] {
        guard let storePath = resolveIndexStorePath(
            for: metadata,
            bazelBin: bazelBin,
            overridePath: overridePath
        ) else {
            return []
        }

        let key = URL(fileURLWithPath: storePath).standardizedFileURL.path
        let indexStoreData: IndexStoreData
        if let cached = cache[key] {
            indexStoreData = cached
        } else {
            indexStoreData = loadIndexStoreData(storePath: key, warnings: &warnings)
            cache[key] = indexStoreData
        }

        return indexStoreData.usageByModule[metadata.target.moduleName] ?? []
    }

    private static func resolveIndexStorePath(
        for metadata: TargetMetadata,
        bazelBin: String,
        overridePath: String?
    ) -> String? {
        if let overridePath, !overridePath.isEmpty {
            return overridePath
        }

        guard let metadataPath = metadata.indexStorePath, !metadataPath.isEmpty else {
            return nil
        }

        if metadataPath.hasPrefix("/") {
            return metadataPath
        }

        let bazelBinURL = URL(fileURLWithPath: bazelBin, isDirectory: true)
        return bazelBinURL.appendingPathComponent(metadataPath).path
    }

    private static func analyzeTarget(
        metadataFile: URL,
        artifacts: ArtifactCatalog,
        bazelBin: String,
        fileManager: FileManager,
        extraSystemModules: Set<String>,
        filter: TargetFilter?,
        labelConverter: LabelConverter,
        workspaceDirectory: URL?,
        indexStoreOverridePath: String?,
        indexStoreCache: inout [String: IndexStoreData],
        warnings: inout [String]
    ) -> AnalysisResult? {
        guard var metadata = loadMetadata(from: metadataFile, warnings: &warnings) else {
            return nil
        }
        let buildFileContent = readBuildFile(
            for: metadata.target.label,
            workspaceDirectory: workspaceDirectory
        )
        metadata = metadata.convertingLabels(with: labelConverter, buildFileContent: buildFileContent)
        if let filter, !filter.matches(label: metadata.target.label) {
            return nil
        }

        let sourceFileUsage = loadIndexStoreUsage(
            for: metadata,
            bazelBin: bazelBin,
            overridePath: indexStoreOverridePath,
            cache: &indexStoreCache,
            warnings: &warnings
        )

        guard let loadedModules = loadModules(
            for: metadata,
            artifacts: artifacts,
            bazelBin: bazelBin,
            fileManager: fileManager,
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
        let unusedImportIssues = unusedImportIssues(
            metadata: metadata,
            sourceFileUsage: sourceFileUsage
        )
        guard !unusedImportIssues.isEmpty else { return baseResult }

        let unusedImportModules = Set(unusedImportIssues.compactMap(\.depModule))
        return AnalysisResult(
            target: baseResult.target,
            moduleName: baseResult.moduleName,
            issues: baseResult.issues + unusedImportIssues,
            cleanDeps: baseResult.cleanDeps.filter { !unusedImportModules.contains($0.moduleName) },
            skippedModules: baseResult.skippedModules
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
        sourceFileUsage: [SourceFileModuleUsage],
        warnings: inout [String]
    ) -> [LoadedModule]? {
        if !sourceFileUsage.isEmpty {
            return deriveLoadedModules(from: sourceFileUsage)
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
    ///
    /// Direct imports remain "loaded" even when no symbols are referenced from
    /// them. The import still requires a compilable dep, so auto-fix must not
    /// treat that dep as safely removable.
    static func deriveLoadedModules(
        from targetUsage: [SourceFileModuleUsage]
    ) -> [LoadedModule] {
        var allDirectImports = Set<String>()
        var allKnownModules = Set<String>()

        for usage in targetUsage {
            allKnownModules.formUnion(usage.loadedModules)
            allKnownModules.formUnion(usage.directImports)
            allKnownModules.formUnion(usage.referencedModules)
            allDirectImports.formUnion(usage.directImports)
        }

        return allKnownModules.compactMap { moduleName in
            let isDirectlyImported = allDirectImports.contains(moduleName)
            return LoadedModule(name: moduleName, isImportedDirectly: isDirectlyImported)
        }
        .sorted { $0.name < $1.name }
    }

    static func unusedImportIssues(
        metadata: TargetMetadata,
        sourceFileUsage: [SourceFileModuleUsage]
    ) -> [Issue] {
        guard !metadata.target.isMixedSource else { return [] }
        guard !sourceFileUsage.isEmpty else { return [] }

        let referencedModules = sourceFileUsage.reduce(into: Set<String>()) { partial, usage in
            partial.formUnion(usage.referencedModules)
        }

        return metadata.declaredDeps.sorted { $0.moduleName < $1.moduleName }.compactMap { dep in
            guard !referencedModules.contains(dep.moduleName) else { return nil }

            let removals = sourceFileUsage.compactMap { usage -> SourceImportRemoval? in
                guard usage.directImports.contains(dep.moduleName) else { return nil }
                guard !usage.referencedModules.contains(dep.moduleName) else { return nil }
                return SourceImportRemoval(
                    filePath: usage.sourceFile,
                    moduleName: dep.moduleName
                )
            }

            guard !removals.isEmpty else { return nil }
            return Issue.unusedImport(
                dep,
                targetLabel: metadata.target.label,
                sourceImportRemovals: removals
            )
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

    /// Read the BUILD file for a target label to help disambiguate apparent repo names.
    private static func readBuildFile(for targetLabel: String, workspaceDirectory: URL?) -> String? {
        guard let workspaceDirectory else {
            return nil
        }

        // Extract package path from label like "@@//path/to/pkg:target" or "//path/to/pkg:target"
        var label = targetLabel
        while label.hasPrefix("@") { label.removeFirst() }
        guard let slashSlash = label.range(of: "//") else { return nil }
        let afterSlash = label[slashSlash.upperBound...]
        let packagePath = String(afterSlash.prefix(while: { $0 != ":" }))

        let dir = workspaceDirectory.appendingPathComponent(packagePath)
        for name in ["BUILD.bazel", "BUILD"] {
            let path = dir.appendingPathComponent(name).path
            if let content = try? String(contentsOfFile: path, encoding: .utf8) {
                return content
            }
        }
        return nil
    }
}
