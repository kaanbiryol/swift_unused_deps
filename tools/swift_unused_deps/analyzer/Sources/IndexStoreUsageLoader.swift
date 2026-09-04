import Foundation

struct IndexStoreUsageCache {
    var usageByModuleByKey: [String: [String: [SourceFileModuleUsage]]] = [:]
}

enum IndexStoreUsageLoader {
    static func load(
        for metadata: TargetMetadata,
        allMetadataByLabel: [String: TargetMetadata],
        bazelBin: String,
        overridePath: String?,
        dependencyIndexStorePaths: [String],
        cache: inout IndexStoreUsageCache,
        warnings: inout [String]
    ) -> [SourceFileModuleUsage] {
        guard let storePath = resolveIndexStorePath(
            for: metadata,
            bazelBin: bazelBin,
            overridePath: overridePath
        ) else {
            return []
        }

        let dependencyStorePaths = uniqueStrings(
            dependencyIndexStorePaths + directDependencyIndexStorePaths(
                for: metadata,
                allMetadataByLabel: allMetadataByLabel,
                bazelBin: bazelBin
            )
        )
        let sourceFiles = metadata.target.sourceFiles + directDependencySourceFiles(
            for: metadata,
            allMetadataByLabel: allMetadataByLabel
        )
        let key = cacheKey(
            storePath: storePath,
            dependencyStorePaths: dependencyStorePaths,
            sourceFiles: sourceFiles
        )

        let usageByModule: [String: [SourceFileModuleUsage]]
        if let cached = cache.usageByModuleByKey[key] {
            usageByModule = cached
        } else {
            usageByModule = loadUsageByModule(
                storePath: storePath,
                dependencyStorePaths: dependencyStorePaths,
                sourceFiles: sourceFiles,
                warnings: &warnings
            )
            cache.usageByModuleByKey[key] = usageByModule
        }

        return usageByModule[metadata.target.moduleName] ?? []
    }

    static func resolveIndexStorePath(
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

    private static func loadUsageByModule(
        storePath: String,
        dependencyStorePaths: [String],
        sourceFiles: [SourceFileMetadata],
        warnings: inout [String]
    ) -> [String: [SourceFileModuleUsage]] {
        do {
            let result = try IndexStoreReader.readModuleUsage(
                storePath: storePath,
                sourceFiles: sourceFiles,
                definitionStorePaths: dependencyStorePaths
            )
            return Dictionary(grouping: result.usage, by: \.moduleName)
        } catch {
            warnings.append("Failed to read index store at '\(storePath)': \(error)")
            return [:]
        }
    }

    private static func directDependencyIndexStorePaths(
        for metadata: TargetMetadata,
        allMetadataByLabel: [String: TargetMetadata],
        bazelBin: String
    ) -> [String] {
        (metadata.declaredDeps + metadata.pluginDeps).compactMap { dep in
            guard let dependencyMetadata = allMetadataByLabel[dep.label] else {
                return nil
            }
            return resolveIndexStorePath(
                for: dependencyMetadata,
                bazelBin: bazelBin,
                overridePath: nil
            )
        }
    }

    private static func directDependencySourceFiles(
        for metadata: TargetMetadata,
        allMetadataByLabel: [String: TargetMetadata]
    ) -> [SourceFileMetadata] {
        (metadata.declaredDeps + metadata.pluginDeps).flatMap { dep in
            allMetadataByLabel[dep.label]?.target.sourceFiles ?? []
        }
    }

    private static func cacheKey(
        storePath: String,
        dependencyStorePaths: [String],
        sourceFiles: [SourceFileMetadata]
    ) -> String {
        let sourceKey = sourceFiles
            .map { "\($0.path)=\($0.shortPath)" }
            .sorted()
            .joined(separator: ";")
        let dependencyKey = dependencyStorePaths
            .map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            .sorted()
            .joined(separator: ";")
        return [
            URL(fileURLWithPath: storePath).standardizedFileURL.path,
            sourceKey,
            dependencyKey,
        ].joined(separator: "\u{0}")
    }

    private static func uniqueStrings(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values where !seen.contains(value) {
            seen.insert(value)
            result.append(value)
        }
        return result
    }
}
