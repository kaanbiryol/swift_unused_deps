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
            }
        } else {
            indexStoreUsage = []
        }

        var results: [AnalysisResult] = []
        var warnings: [String] = []

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

            var traceURL = traceFileMap[metadata.target.moduleName]
            if traceURL == nil && !metadata.traceFile.isEmpty {
                let candidate = URL(fileURLWithPath: options.bazelBin).appendingPathComponent(metadata.traceFile)
                if fm.fileExists(atPath: candidate.path) {
                    traceURL = candidate
                }
            }

            guard let traceFile = traceURL else {
                warnings.append(
                    "No trace file for \(metadata.target.label) (module: \(metadata.target.moduleName)). "
                    + "Was --config=unused-deps used during build?"
                )
                continue
            }

            let loadedModules: [LoadedModule]
            do {
                loadedModules = try TraceParser.parseTraceFile(at: traceFile, forModule: metadata.target.moduleName)
            } catch {
                warnings.append("Failed to parse trace for \(metadata.target.label): \(error)")
                continue
            }

            if loadedModules.isEmpty && !metadata.declaredDeps.isEmpty {
                continue
            }

            let effectiveModules = ImportRefiner.refine(
                loadedModules: loadedModules,
                targetModuleName: metadata.target.moduleName,
                indexStoreUsage: indexStoreUsage
            )

            let resolver = ModuleResolver(
                transitiveModuleMap: metadata.transitiveModuleMap,
                extraSystemModules: options.extraSystemModules
            )
            let result = Analyzer.analyze(
                metadata: metadata,
                loadedModules: effectiveModules,
                resolver: resolver
            )
            results.append(result)
        }

        return Output(results: results, warnings: warnings)
    }
}
