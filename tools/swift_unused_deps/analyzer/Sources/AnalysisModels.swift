import Foundation

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
        case .low:
            return 0
        case .medium:
            return 1
        case .high:
            return 2
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

public enum SkippedModuleReason: String, Codable {
    case systemModule = "system_module"
    case unresolved
}

public struct SkippedModule: Codable, Equatable {
    public let name: String
    public let reason: SkippedModuleReason

    public init(name: String, reason: SkippedModuleReason) {
        self.name = name
        self.reason = reason
    }
}

public enum IssueContext {
    case unusedDep(DeclaredDep)
    case missingDirectDep(
        depLabel: String,
        moduleName: String,
        reachableVia: [String],
        isImportedDirectly: Bool
    )
    case candidatePrivateDep(DeclaredDep)
    case unresolvedModule(name: String)
    case mixedSourceTarget(label: String)
}

public struct Issue {
    public let kind: IssueKind
    public let confidence: Confidence
    public let reason: String
    public let suggestedAction: SuggestedAction
    public let context: IssueContext
    public let buildozerCommand: BuildozerCommand?

    public static func mixedSourceWarning(targetLabel: String) -> Issue {
        Issue(
            kind: .unresolvedModule,
            confidence: .low,
            reason: "Target \(targetLabel) has mixed Swift/ObjC sources. Analysis may be incomplete - ObjC imports are not tracked.",
            suggestedAction: .investigate,
            context: .mixedSourceTarget(label: targetLabel),
            buildozerCommand: nil
        )
    }

    public static func unresolvedModule(_ moduleName: String) -> Issue {
        Issue(
            kind: .unresolvedModule,
            confidence: .low,
            reason: "Module '\(moduleName)' was loaded during compilation but could not be mapped to a Bazel label",
            suggestedAction: .investigate,
            context: .unresolvedModule(name: moduleName),
            buildozerCommand: nil
        )
    }

    public static func unusedDep(_ dep: DeclaredDep, targetLabel: String) -> Issue {
        let attrName = dep.kind == .privateDep ? "private_deps" : "deps"
        return Issue(
            kind: .unusedDep,
            confidence: .high,
            reason: "Module '\(dep.moduleName)' is declared as a \(dep.kind.rawValue) but was not loaded during compilation",
            suggestedAction: .remove,
            context: .unusedDep(dep),
            buildozerCommand: BuildozerCommand(
                action: "remove \(attrName) \(dep.label)",
                target: targetLabel
            )
        )
    }

    public static func missingDirectDep(
        depLabel: String,
        moduleName: String,
        currentlyReachableVia: [String],
        isImportedDirectly: Bool,
        targetLabel: String
    ) -> Issue {
        let action: SuggestedAction = isImportedDirectly ? .addDep : .investigate
        return Issue(
            kind: .missingDirectDep,
            confidence: isImportedDirectly ? .high : .low,
            reason: "Module '\(moduleName)' is loaded (isImportedDirectly=\(isImportedDirectly)) but not declared as a dep",
            suggestedAction: action,
            context: .missingDirectDep(
                depLabel: depLabel,
                moduleName: moduleName,
                reachableVia: currentlyReachableVia,
                isImportedDirectly: isImportedDirectly
            ),
            buildozerCommand: action == .addDep
                ? BuildozerCommand(action: "add deps \(depLabel)", target: targetLabel)
                : nil
        )
    }

    public static func candidatePrivateDep(_ dep: DeclaredDep, targetLabel: String) -> Issue {
        Issue(
            kind: .candidatePrivateDep,
            confidence: .low,
            reason: "Module '\(dep.moduleName)' is loaded but not directly imported in source code - may be suitable for private_deps",
            suggestedAction: .moveToPrivateDeps,
            context: .candidatePrivateDep(dep),
            buildozerCommand: BuildozerCommand(
                action: "move deps private_deps \(dep.label)",
                target: targetLabel
            )
        )
    }

    public var depLabel: String? {
        switch context {
        case .unusedDep(let dep):
            return dep.label
        case .missingDirectDep(let depLabel, _, _, _):
            return depLabel
        case .candidatePrivateDep(let dep):
            return dep.label
        case .unresolvedModule, .mixedSourceTarget:
            return nil
        }
    }

    public var depModule: String? {
        switch context {
        case .unusedDep(let dep):
            return dep.moduleName
        case .missingDirectDep(_, let moduleName, _, _):
            return moduleName
        case .candidatePrivateDep(let dep):
            return dep.moduleName
        case .unresolvedModule(let name):
            return name
        case .mixedSourceTarget:
            return nil
        }
    }

    public var depKind: DepKind? {
        switch context {
        case .unusedDep(let dep), .candidatePrivateDep(let dep):
            return dep.kind
        case .missingDirectDep, .unresolvedModule, .mixedSourceTarget:
            return nil
        }
    }

    public var currentlyReachableVia: [String] {
        switch context {
        case .missingDirectDep(_, _, let reachableVia, _):
            return reachableVia
        case .unusedDep, .candidatePrivateDep, .unresolvedModule, .mixedSourceTarget:
            return []
        }
    }
}

public struct AnalysisResult {
    public let target: String
    public let moduleName: String
    public let issues: [Issue]
    public let cleanDeps: [DeclaredDep]
    public let skippedModules: [SkippedModule]

    public var isClean: Bool { issues.isEmpty }
    public var status: String { isClean ? "clean" : "issues_found" }
}
