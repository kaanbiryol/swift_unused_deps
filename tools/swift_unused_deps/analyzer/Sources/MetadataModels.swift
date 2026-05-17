import Foundation

public enum DepKind: String, Codable {
    case dep
    case privateDep = "private_dep"
}

public struct SourceFileMetadata: Codable, Equatable, Hashable {
    public let basename: String
    public let path: String
    public let shortPath: String
    public let isGenerated: Bool

    enum CodingKeys: String, CodingKey {
        case basename
        case path
        case shortPath = "short_path"
        case isGenerated = "is_generated"
    }

    public init(
        basename: String,
        path: String,
        shortPath: String,
        isGenerated: Bool = false
    ) {
        self.basename = basename
        self.path = path
        self.shortPath = shortPath
        self.isGenerated = isGenerated
    }
}

public struct TargetInfo: Codable {
    public let label: String
    public let moduleName: String
    public let isMixedSource: Bool
    public let sourceFiles: [SourceFileMetadata]

    enum CodingKeys: String, CodingKey {
        case label
        case moduleName = "module_name"
        case isMixedSource = "is_mixed_source"
        case sourceFiles = "source_files"
    }

    public init(
        label: String,
        moduleName: String,
        isMixedSource: Bool = false,
        sourceFiles: [SourceFileMetadata] = []
    ) {
        self.label = label
        self.moduleName = moduleName
        self.isMixedSource = isMixedSource
        self.sourceFiles = sourceFiles
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        label = try container.decode(String.self, forKey: .label)
        moduleName = try container.decode(String.self, forKey: .moduleName)
        isMixedSource = try container.decodeIfPresent(Bool.self, forKey: .isMixedSource) ?? false
        sourceFiles = try container.decodeIfPresent([SourceFileMetadata].self, forKey: .sourceFiles) ?? []
    }
}

public struct DeclaredDep: Codable, Hashable {
    public let label: String
    public let moduleName: String
    public let kind: DepKind

    enum CodingKeys: String, CodingKey {
        case label
        case moduleName = "module_name"
        case kind
    }

    public init(label: String, moduleName: String, kind: DepKind) {
        self.label = label
        self.moduleName = moduleName
        self.kind = kind
    }
}

public struct TargetMetadata: Codable {
    public let schemaVersion: Int
    public let target: TargetInfo
    public let declaredDeps: [DeclaredDep]
    public let transitiveModuleMap: [String: String]
    public let moduleReachableVia: [String: [String]]
    public let indexStorePath: String?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case target
        case declaredDeps = "declared_deps"
        case transitiveModuleMap = "transitive_module_map"
        case moduleReachableVia = "module_reachable_via"
        case indexStorePath = "indexstore_path"
    }

    public init(
        schemaVersion: Int,
        target: TargetInfo,
        declaredDeps: [DeclaredDep],
        transitiveModuleMap: [String: String],
        moduleReachableVia: [String: [String]] = [:],
        indexStorePath: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.target = target
        self.declaredDeps = declaredDeps
        self.transitiveModuleMap = transitiveModuleMap
        self.moduleReachableVia = moduleReachableVia
        self.indexStorePath = indexStorePath
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        target = try container.decode(TargetInfo.self, forKey: .target)
        declaredDeps = try container.decode([DeclaredDep].self, forKey: .declaredDeps)
        transitiveModuleMap = try container.decode([String: String].self, forKey: .transitiveModuleMap)
        moduleReachableVia = try container.decodeIfPresent([String: [String]].self, forKey: .moduleReachableVia) ?? [:]
        indexStorePath = try container.decodeIfPresent(String.self, forKey: .indexStorePath)
    }

    /// Returns a new instance with all Bazel labels converted from canonical to apparent form.
    ///
    /// When multiple apparent names exist for the same canonical repo, pass
    /// `buildFileContent` to disambiguate by checking which name the BUILD file actually uses.
    public func convertingLabels(with converter: LabelConverter, buildFileContent: String? = nil) -> TargetMetadata {
        TargetMetadata(
            schemaVersion: schemaVersion,
            target: TargetInfo(
                label: converter.convert(target.label, buildFileContent: buildFileContent),
                moduleName: target.moduleName,
                isMixedSource: target.isMixedSource,
                sourceFiles: target.sourceFiles
            ),
            declaredDeps: declaredDeps.map {
                DeclaredDep(
                    label: converter.convert($0.label, buildFileContent: buildFileContent),
                    moduleName: $0.moduleName,
                    kind: $0.kind
                )
            },
            transitiveModuleMap: Dictionary(uniqueKeysWithValues:
                transitiveModuleMap.map { ($0.key, converter.convert($0.value, buildFileContent: buildFileContent)) }
            ),
            moduleReachableVia: Dictionary(uniqueKeysWithValues:
                moduleReachableVia.map { moduleName, directDeps in
                    (
                        moduleName,
                        directDeps.map { converter.convert($0, buildFileContent: buildFileContent) }.sorted()
                    )
                }
            ),
            indexStorePath: indexStorePath
        )
    }
}
