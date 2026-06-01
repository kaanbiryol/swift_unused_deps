import Foundation

enum DepKind: String, Codable {
    case dep
    case privateDep = "private_dep"
    case plugin
}

struct SourceFileMetadata: Codable, Equatable, Hashable {
    let basename: String
    let path: String
    let shortPath: String
    let isGenerated: Bool

    enum CodingKeys: String, CodingKey {
        case basename
        case path
        case shortPath = "short_path"
        case isGenerated = "is_generated"
    }

    init(
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

struct BuildEditMetadata: Codable, Equatable, Hashable {
    let target: String
    let depsAttribute: String

    enum CodingKeys: String, CodingKey {
        case target
        case depsAttribute = "deps_attr"
    }

    init(target: String, depsAttribute: String = "deps") {
        self.target = target
        self.depsAttribute = depsAttribute
    }
}

struct TargetInfo: Codable {
    let label: String
    let moduleName: String
    let isMixedSource: Bool
    let sourceFiles: [SourceFileMetadata]
    let buildEdit: BuildEditMetadata

    enum CodingKeys: String, CodingKey {
        case label
        case moduleName = "module_name"
        case isMixedSource = "is_mixed_source"
        case sourceFiles = "source_files"
        case buildEdit = "build_edit"
    }

    init(
        label: String,
        moduleName: String,
        isMixedSource: Bool = false,
        sourceFiles: [SourceFileMetadata] = [],
        buildEdit: BuildEditMetadata? = nil
    ) {
        self.label = label
        self.moduleName = moduleName
        self.isMixedSource = isMixedSource
        self.sourceFiles = sourceFiles
        self.buildEdit = buildEdit ?? BuildEditMetadata(target: label)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        label = try container.decode(String.self, forKey: .label)
        moduleName = try container.decode(String.self, forKey: .moduleName)
        isMixedSource = try container.decodeIfPresent(Bool.self, forKey: .isMixedSource) ?? false
        sourceFiles = try container.decodeIfPresent([SourceFileMetadata].self, forKey: .sourceFiles) ?? []
        buildEdit = try container.decodeIfPresent(BuildEditMetadata.self, forKey: .buildEdit)
            ?? BuildEditMetadata(target: label)
    }
}

struct DeclaredDep: Codable, Hashable {
    let label: String
    let moduleName: String
    let kind: DepKind

    enum CodingKeys: String, CodingKey {
        case label
        case moduleName = "module_name"
        case kind
    }

    init(label: String, moduleName: String, kind: DepKind) {
        self.label = label
        self.moduleName = moduleName
        self.kind = kind
    }
}

struct TargetMetadata: Codable {
    let schemaVersion: Int
    let target: TargetInfo
    let declaredDeps: [DeclaredDep]
    let pluginDeps: [DeclaredDep]
    let transitiveModuleMap: [String: String]
    let moduleReachableVia: [String: [String]]
    let indexStorePath: String?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case target
        case declaredDeps = "declared_deps"
        case pluginDeps = "plugin_deps"
        case transitiveModuleMap = "transitive_module_map"
        case moduleReachableVia = "module_reachable_via"
        case indexStorePath = "indexstore_path"
    }

    init(
        schemaVersion: Int,
        target: TargetInfo,
        declaredDeps: [DeclaredDep],
        pluginDeps: [DeclaredDep] = [],
        transitiveModuleMap: [String: String],
        moduleReachableVia: [String: [String]] = [:],
        indexStorePath: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.target = target
        self.declaredDeps = declaredDeps
        self.pluginDeps = pluginDeps
        self.transitiveModuleMap = transitiveModuleMap
        self.moduleReachableVia = moduleReachableVia
        self.indexStorePath = indexStorePath
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        target = try container.decode(TargetInfo.self, forKey: .target)
        declaredDeps = try container.decode([DeclaredDep].self, forKey: .declaredDeps)
        pluginDeps = try container.decodeIfPresent([DeclaredDep].self, forKey: .pluginDeps) ?? []
        transitiveModuleMap = try container.decode([String: String].self, forKey: .transitiveModuleMap)
        moduleReachableVia = try container.decodeIfPresent([String: [String]].self, forKey: .moduleReachableVia) ?? [:]
        indexStorePath = try container.decodeIfPresent(String.self, forKey: .indexStorePath)
    }

    /// Returns a new instance with all Bazel labels converted from canonical to apparent form.
    ///
    /// When multiple apparent names exist for the same canonical repo, pass
    /// `buildFileContent` to disambiguate by checking which name the BUILD file actually uses.
    func convertingLabels(with converter: LabelConverter, buildFileContent: String? = nil) -> TargetMetadata {
        TargetMetadata(
            schemaVersion: schemaVersion,
            target: TargetInfo(
                label: converter.convert(target.label, buildFileContent: buildFileContent),
                moduleName: target.moduleName,
                isMixedSource: target.isMixedSource,
                sourceFiles: target.sourceFiles,
                buildEdit: BuildEditMetadata(
                    target: converter.convert(target.buildEdit.target, buildFileContent: buildFileContent),
                    depsAttribute: target.buildEdit.depsAttribute
                )
            ),
            declaredDeps: declaredDeps.map {
                DeclaredDep(
                    label: converter.convert($0.label, buildFileContent: buildFileContent),
                    moduleName: $0.moduleName,
                    kind: $0.kind
                )
            },
            pluginDeps: pluginDeps.map {
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
