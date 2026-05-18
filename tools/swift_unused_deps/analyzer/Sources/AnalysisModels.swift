import Foundation

enum IssueKind: String, Codable {
    case unusedDep = "unused_dep"
    case unusedImport = "unused_import"
    case missingDirectDep = "missing_direct_dep"
    case candidatePrivateDep = "candidate_private_dep"
    case unresolvedModule = "unresolved_module"
    case mixedSourceTarget = "mixed_source_target"
}

enum Confidence: String, Codable, Comparable {
    case low
    case high

    private var order: Int {
        switch self {
        case .low:
            return 0
        case .high:
            return 1
        }
    }

    static func < (lhs: Confidence, rhs: Confidence) -> Bool {
        lhs.order < rhs.order
    }
}

enum SuggestedAction: String, Codable {
    case remove
    case addDep = "add_dep"
    case moveToPrivateDeps = "move_to_private_deps"
    case investigate
}

enum SkippedModuleReason: String, Codable {
    case systemModule = "system_module"
    case unresolved
}

struct SkippedModule: Codable, Equatable {
    let name: String
    let reason: SkippedModuleReason

    init(name: String, reason: SkippedModuleReason) {
        self.name = name
        self.reason = reason
    }
}

struct SourceImportRemoval: Codable, Equatable, Hashable {
    let filePath: String
    let moduleName: String

    init(filePath: String, moduleName: String) {
        self.filePath = filePath
        self.moduleName = moduleName
    }
}

struct LoadedModule: Equatable {
    let name: String
    let isImportedDirectly: Bool
    let isSystem: Bool

    init(name: String, isImportedDirectly: Bool, isSystem: Bool = false) {
        self.name = name
        self.isImportedDirectly = isImportedDirectly
        self.isSystem = isSystem
    }
}

enum IssueContext {
    case unusedDep(DeclaredDep)
    case unusedImport(DeclaredDep)
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

struct Issue {
    let kind: IssueKind
    let confidence: Confidence
    let reason: String
    let suggestedAction: SuggestedAction
    let context: IssueContext
    let buildozerCommand: BuildozerCommand?
    let sourceImportRemovals: [SourceImportRemoval]

    static func mixedSourceWarning(targetLabel: String) -> Issue {
        Issue(
            kind: .mixedSourceTarget,
            confidence: .low,
            reason: "Target \(targetLabel) has mixed Swift/ObjC sources. Analysis may be incomplete - ObjC imports are not tracked.",
            suggestedAction: .investigate,
            context: .mixedSourceTarget(label: targetLabel),
            buildozerCommand: nil,
            sourceImportRemovals: []
        )
    }

    static func unresolvedModule(_ moduleName: String) -> Issue {
        Issue(
            kind: .unresolvedModule,
            confidence: .low,
            reason: "Module '\(moduleName)' was loaded during compilation but could not be mapped to a Bazel label",
            suggestedAction: .investigate,
            context: .unresolvedModule(name: moduleName),
            buildozerCommand: nil,
            sourceImportRemovals: []
        )
    }

    static func unusedDep(_ dep: DeclaredDep, targetLabel: String) -> Issue {
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
            ),
            sourceImportRemovals: []
        )
    }

    static func unusedImport(
        _ dep: DeclaredDep,
        targetLabel: String,
        sourceImportRemovals: [SourceImportRemoval],
        removeDep: Bool = true
    ) -> Issue {
        let attrName = dep.kind == .privateDep ? "private_deps" : "deps"
        return Issue(
            kind: .unusedImport,
            confidence: .high,
            reason: "Module '\(dep.moduleName)' is imported in source but no symbols from it are referenced",
            suggestedAction: .remove,
            context: .unusedImport(dep),
            buildozerCommand: removeDep
                ? BuildozerCommand(
                    action: "remove \(attrName) \(dep.label)",
                    target: targetLabel
                )
                : nil,
            sourceImportRemovals: sourceImportRemovals.sorted {
                if $0.filePath == $1.filePath {
                    return $0.moduleName < $1.moduleName
                }
                return $0.filePath < $1.filePath
            }
        )
    }

    static func missingDirectDep(
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
                : nil,
            sourceImportRemovals: []
        )
    }

    static func candidatePrivateDep(_ dep: DeclaredDep, targetLabel: String) -> Issue {
        Issue(
            kind: .candidatePrivateDep,
            confidence: .low,
            reason: "Module '\(dep.moduleName)' is loaded but not directly imported in source code - may be suitable for private_deps",
            suggestedAction: .moveToPrivateDeps,
            context: .candidatePrivateDep(dep),
            buildozerCommand: BuildozerCommand(
                action: "move deps private_deps \(dep.label)",
                target: targetLabel
            ),
            sourceImportRemovals: []
        )
    }

    var depLabel: String? {
        switch context {
        case .unusedDep(let dep):
            return dep.label
        case .unusedImport(let dep):
            return dep.label
        case .missingDirectDep(let depLabel, _, _, _):
            return depLabel
        case .candidatePrivateDep(let dep):
            return dep.label
        case .unresolvedModule, .mixedSourceTarget:
            return nil
        }
    }

    var depModule: String? {
        switch context {
        case .unusedDep(let dep):
            return dep.moduleName
        case .unusedImport(let dep):
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

    var depKind: DepKind? {
        switch context {
        case .unusedDep(let dep), .unusedImport(let dep), .candidatePrivateDep(let dep):
            return dep.kind
        case .missingDirectDep, .unresolvedModule, .mixedSourceTarget:
            return nil
        }
    }

    var currentlyReachableVia: [String] {
        switch context {
        case .missingDirectDep(_, _, let reachableVia, _):
            return reachableVia
        case .unusedDep, .unusedImport, .candidatePrivateDep, .unresolvedModule, .mixedSourceTarget:
            return []
        }
    }
}

struct AnalysisResult {
    let target: String
    let moduleName: String
    let issues: [Issue]
    let cleanDeps: [DeclaredDep]
    let skippedModules: [SkippedModule]

    var isClean: Bool { issues.isEmpty }
}
