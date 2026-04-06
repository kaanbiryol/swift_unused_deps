import Foundation

public enum DepKind: String, Codable {
    case dep
    case privateDep = "private_dep"
}

public struct TargetInfo: Codable {
    public let label: String
    public let moduleName: String
    public let isMixedSource: Bool
    public let srcs: [String]

    enum CodingKeys: String, CodingKey {
        case label
        case moduleName = "module_name"
        case isMixedSource = "is_mixed_source"
        case srcs
    }

    public init(label: String, moduleName: String, isMixedSource: Bool = false, srcs: [String] = []) {
        self.label = label
        self.moduleName = moduleName
        self.isMixedSource = isMixedSource
        self.srcs = srcs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        label = try container.decode(String.self, forKey: .label)
        moduleName = try container.decode(String.self, forKey: .moduleName)
        isMixedSource = try container.decodeIfPresent(Bool.self, forKey: .isMixedSource) ?? false
        srcs = try container.decodeIfPresent([String].self, forKey: .srcs) ?? []
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
    public let traceFile: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case target
        case declaredDeps = "declared_deps"
        case transitiveModuleMap = "transitive_module_map"
        case traceFile = "trace_file"
    }

    /// Returns a new instance with all Bazel labels converted from canonical to apparent form.
    public func convertingLabels(with converter: LabelConverter) -> TargetMetadata {
        TargetMetadata(
            schemaVersion: schemaVersion,
            target: TargetInfo(
                label: converter.convert(target.label),
                moduleName: target.moduleName,
                isMixedSource: target.isMixedSource,
                srcs: target.srcs
            ),
            declaredDeps: declaredDeps.map {
                DeclaredDep(
                    label: converter.convert($0.label),
                    moduleName: $0.moduleName,
                    kind: $0.kind
                )
            },
            transitiveModuleMap: Dictionary(uniqueKeysWithValues:
                transitiveModuleMap.map { ($0.key, converter.convert($0.value)) }
            ),
            traceFile: traceFile
        )
    }
}
