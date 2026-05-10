import Foundation

public enum BatchAnalyzer {

    private struct ArtifactCatalog {
        let metadataFiles: [URL]
    }

    public struct Options {
        public var bazelBin: String
        public var indexStorePath: String?
        public var extraSystemModules: Set<String>
        public var filter: String?
        public var includedLabels: Set<String>?
        public var labelConverter: LabelConverter
        public var workspaceDirectory: URL?

        public init(
            bazelBin: String,
            indexStorePath: String? = nil,
            extraSystemModules: Set<String> = [],
            filter: String? = nil,
            includedLabels: Set<String>? = nil,
            labelConverter: LabelConverter = .identity,
            workspaceDirectory: URL? = nil
        ) {
            self.bazelBin = bazelBin
            self.indexStorePath = indexStorePath
            self.extraSystemModules = extraSystemModules
            self.filter = filter
            self.includedLabels = includedLabels
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
                bazelBin: options.bazelBin,
                extraSystemModules: options.extraSystemModules,
                filter: filter,
                includedLabels: options.includedLabels,
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

        if let enumerator = fileManager.enumerator(
            at: baseURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator {
                let name = url.lastPathComponent
                if name.hasSuffix(".swift_deps_info.json") {
                    metadataFiles.append(url)
                }
            }
        }

        metadataFiles.sort { $0.path < $1.path }
        return ArtifactCatalog(metadataFiles: metadataFiles)
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
        bazelBin: String,
        extraSystemModules: Set<String>,
        filter: TargetFilter?,
        includedLabels: Set<String>?,
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
        if let includedLabels {
            guard includedLabels.contains(metadata.target.label) else { return nil }
        } else if let filter, !filter.matches(label: metadata.target.label) {
            return nil
        }

        let rawSourceFileUsage = loadIndexStoreUsage(
            for: metadata,
            bazelBin: bazelBin,
            overridePath: indexStoreOverridePath,
            cache: &indexStoreCache,
            warnings: &warnings
        )
        let sourceFileUsage = filterReferencedModules(
            rawSourceFileUsage,
            for: metadata,
            extraSystemModules: extraSystemModules
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
        let unusedImportIssues = unusedImportIssues(
            metadata: metadata,
            sourceFileUsage: sourceFileUsage
        )
        return mergeUnusedImportIssues(
            baseResult: baseResult,
            unusedImportIssues: unusedImportIssues
        )
    }

    static func mergeUnusedImportIssues(
        baseResult: AnalysisResult,
        unusedImportIssues: [Issue]
    ) -> AnalysisResult {
        guard !unusedImportIssues.isEmpty else { return baseResult }
        let unusedImportModules = Set(unusedImportIssues.compactMap(\.depModule))
        let filteredBaseIssues = baseResult.issues.filter { issue in
            !(issue.kind == .missingDirectDep && issue.depModule.map(unusedImportModules.contains) == true)
        }
        return AnalysisResult(
            target: baseResult.target,
            moduleName: baseResult.moduleName,
            issues: filteredBaseIssues + unusedImportIssues,
            cleanDeps: baseResult.cleanDeps.filter { !unusedImportModules.contains($0.moduleName) },
            skippedModules: baseResult.skippedModules
        )
    }

    private static func filterReferencedModules(
        _ sourceFileUsage: [SourceFileModuleUsage],
        for metadata: TargetMetadata,
        extraSystemModules: Set<String>
    ) -> [SourceFileModuleUsage] {
        let knownModules = Set(metadata.transitiveModuleMap.keys)
            .union([metadata.target.moduleName])
            .union(extraSystemModules)
            .union(sourceFileUsage.flatMap(\.systemModules))

        return sourceFileUsage.map { usage in
            SourceFileModuleUsage(
                sourceFile: usage.sourceFile,
                moduleName: usage.moduleName,
                referencedModules: usage.referencedModules.intersection(knownModules),
                loadedModules: usage.loadedModules,
                systemModules: usage.systemModules,
                directImports: usage.directImports,
                reexportedImports: usage.reexportedImports,
                conditionalImports: usage.conditionalImports
            )
        }
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

    static func unusedImportIssues(
        metadata: TargetMetadata,
        sourceFileUsage: [SourceFileModuleUsage]
    ) -> [Issue] {
        guard !metadata.target.isMixedSource else { return [] }
        guard !sourceFileUsage.isEmpty else { return [] }

        let referencedModules = sourceFileUsage.reduce(into: Set<String>()) { partial, usage in
            partial.formUnion(usage.referencedModules)
        }
        let reexportedImportModules = sourceFileUsage.reduce(into: Set<String>()) { partial, usage in
            partial.formUnion(usage.reexportedImports)
        }
        let conditionalImportModules = sourceFileUsage.reduce(into: Set<String>()) { partial, usage in
            partial.formUnion(usage.conditionalImports)
        }

        return DeclaredDepGrouping.groups(metadata.declaredDeps).flatMap { group -> [Issue] in
            var shouldRemoveDep = group.moduleNames.isDisjoint(with: referencedModules)
                && group.moduleNames.isDisjoint(with: reexportedImportModules)
                && group.moduleNames.isDisjoint(with: conditionalImportModules)

            return group.deps.sorted { $0.moduleName < $1.moduleName }.compactMap { dep in
                guard !referencedModules.contains(dep.moduleName) else { return nil }
                guard !reexportedImportModules.contains(dep.moduleName) else { return nil }
                guard !conditionalImportModules.contains(dep.moduleName) else { return nil }

                let removals = sourceFileUsage.compactMap { usage -> SourceImportRemoval? in
                    guard usage.directImports.contains(dep.moduleName) else { return nil }
                    guard !usage.referencedModules.contains(dep.moduleName) else { return nil }
                    guard !usage.reexportedImports.contains(dep.moduleName) else { return nil }
                    guard !usage.conditionalImports.contains(dep.moduleName) else { return nil }
                    return SourceImportRemoval(
                        filePath: usage.sourceFile,
                        moduleName: dep.moduleName
                    )
                }

                guard !removals.isEmpty else { return nil }
                let removeDep = shouldRemoveDep
                shouldRemoveDep = false
                return Issue.unusedImport(
                    dep,
                    targetLabel: metadata.target.label,
                    sourceImportRemovals: removals,
                    removeDep: removeDep
                )
            }
        } + transitiveUnusedImportIssues(
            metadata: metadata,
            sourceFileUsage: sourceFileUsage,
            referencedModules: referencedModules,
            reexportedImportModules: reexportedImportModules,
            conditionalImportModules: conditionalImportModules
        )
    }

    private static func transitiveUnusedImportIssues(
        metadata: TargetMetadata,
        sourceFileUsage: [SourceFileModuleUsage],
        referencedModules: Set<String>,
        reexportedImportModules: Set<String>,
        conditionalImportModules: Set<String>
    ) -> [Issue] {
        let declaredModuleNames = Set(metadata.declaredDeps.map(\.moduleName))
        let directImports = sourceFileUsage.reduce(into: Set<String>()) { partial, usage in
            partial.formUnion(usage.directImports)
        }

        return directImports
            .subtracting(declaredModuleNames)
            .subtracting(referencedModules)
            .subtracting(reexportedImportModules)
            .subtracting(conditionalImportModules)
            .filter { $0 != metadata.target.moduleName }
            .sorted()
            .compactMap { moduleName -> Issue? in
                guard let label = metadata.transitiveModuleMap[moduleName] else {
                    return nil
                }
                let removals = sourceFileUsage.compactMap { usage -> SourceImportRemoval? in
                    guard usage.directImports.contains(moduleName) else { return nil }
                    guard !usage.referencedModules.contains(moduleName) else { return nil }
                    guard !usage.reexportedImports.contains(moduleName) else { return nil }
                    guard !usage.conditionalImports.contains(moduleName) else { return nil }
                    return SourceImportRemoval(
                        filePath: usage.sourceFile,
                        moduleName: moduleName
                    )
                }
                guard !removals.isEmpty else { return nil }
                return Issue.unusedImport(
                    DeclaredDep(label: label, moduleName: moduleName, kind: .dep),
                    targetLabel: metadata.target.label,
                    sourceImportRemovals: removals,
                    removeDep: false
                )
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
