import Foundation

public enum DepKind: String, Codable {
    case dep
    case privateDep = "private_dep"
}

public enum IssueKind: String, Codable {
    case unusedDep = "unused_dep"
    case missingDirectDep = "missing_direct_dep"
    case candidatePrivateDep = "candidate_private_dep"
    case unresolvedModule = "unresolved_module"
}

public enum Confidence: String, Codable, Comparable {
    case low
    case medium
    case high

    private var order: Int {
        switch self {
        case .low: return 0
        case .medium: return 1
        case .high: return 2
        }
    }

    public static func < (lhs: Confidence, rhs: Confidence) -> Bool {
        lhs.order < rhs.order
    }
}

public enum SuggestedAction: String, Codable {
    case remove
    case addDep = "add_dep"
    case moveToPrivateDeps = "move_to_private_deps"
    case investigate
}

public struct TargetInfo: Codable {
    public let label: String
    public let moduleName: String
    public let isMixedSource: Bool

    enum CodingKeys: String, CodingKey {
        case label
        case moduleName = "module_name"
        case isMixedSource = "is_mixed_source"
    }

    public init(label: String, moduleName: String, isMixedSource: Bool = false) {
        self.label = label
        self.moduleName = moduleName
        self.isMixedSource = isMixedSource
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
}

public struct TraceEntry: Codable {
    public let path: String
    public let isImportedDirectly: Bool
}

/// Detailed module info (used in newer Swift versions).
/// Has an explicit `name` field so we don't need to parse it from the path.
public struct DetailedTraceEntry: Codable {
    public let name: String
    public let path: String
    public let isImportedDirectly: Bool
}

/// Represents a swiftmodules entry that can be either a plain string path
/// or a dict with path + isImportedDirectly.
public enum SwiftModuleEntry: Codable {
    case path(String)
    case entry(TraceEntry)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let str = try? container.decode(String.self) {
            self = .path(str)
        } else {
            self = .entry(try container.decode(TraceEntry.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .path(let s): try container.encode(s)
        case .entry(let e): try container.encode(e)
        }
    }
}

public struct ModuleTrace: Codable {
    public let name: String
    /// May be plain string paths or dicts, depending on Swift version.
    public let swiftmodules: [SwiftModuleEntry]?
    /// Modern format: includes module name inline. Preferred when present.
    public let swiftmodulesDetailedInfo: [DetailedTraceEntry]?
}

public struct LoadedModule {
    public let name: String
    public let isImportedDirectly: Bool

    public init(name: String, isImportedDirectly: Bool) {
        self.name = name
        self.isImportedDirectly = isImportedDirectly
    }
}

// MARK: - Buildozer Command

public struct BuildozerCommand {
    public let action: String
    public let target: String

    public init(action: String, target: String) {
        self.action = action
        self.target = target
    }

    public var displayString: String {
        "buildozer '\(action)' \(target)"
    }

    public var batchLine: String {
        "\(action)|\(target)"
    }
}

// MARK: - Analysis Result (Output)

public struct Issue {
    public let kind: IssueKind
    public let confidence: Confidence
    public let reason: String
    public let suggestedAction: SuggestedAction
    public var depLabel: String?
    public var depModule: String?
    public var depKind: DepKind?
    public var currentlyReachableVia: [String] = []
    public var buildozerCommand: BuildozerCommand?
}

public struct AnalysisResult {
    public let target: String
    public let moduleName: String
    public let issues: [Issue]
    public let cleanDeps: [DeclaredDep]
    public let skippedModules: [(name: String, reason: String)]

    public var isClean: Bool { issues.isEmpty }
    public var status: String { isClean ? "clean" : "issues_found" }
}
