import Foundation

public enum Analyzer {

    private struct UsedModule {
        let name: String
        let label: String
        let isImportedDirectly: Bool
    }

    private struct ResolvedUsage {
        let usedModulesByName: [String: UsedModule]
        let issues: [Issue]
        let skippedModules: [SkippedModule]
    }

    public static func analyze(
        metadata: TargetMetadata,
        loadedModules: [LoadedModule],
        resolver: ModuleResolver
    ) -> AnalysisResult {
        let declaredByModule = Dictionary(
            uniqueKeysWithValues: metadata.declaredDeps.map { ($0.moduleName, $0) }
        )
        let resolvedUsage = resolveLoadedModules(
            loadedModules,
            targetModuleName: metadata.target.moduleName,
            resolver: resolver
        )

        var issues = metadata.target.isMixedSource
            ? [Issue.mixedSourceWarning(targetLabel: metadata.target.label)]
            : []
        issues.append(contentsOf: resolvedUsage.issues)
        issues.append(contentsOf: unusedDepIssues(
            declaredByModule: declaredByModule,
            usedModulesByName: resolvedUsage.usedModulesByName,
            targetLabel: metadata.target.label
        ))
        issues.append(contentsOf: missingDirectDepIssues(
            metadata: metadata,
            declaredByModule: declaredByModule,
            usedModulesByName: resolvedUsage.usedModulesByName
        ))
        issues.append(contentsOf: candidatePrivateDepIssues(
            declaredByModule: declaredByModule,
            usedModulesByName: resolvedUsage.usedModulesByName,
            targetLabel: metadata.target.label
        ))

        return AnalysisResult(
            target: metadata.target.label,
            moduleName: metadata.target.moduleName,
            issues: issues,
            cleanDeps: cleanDeps(
                declaredByModule: declaredByModule,
                usedModulesByName: resolvedUsage.usedModulesByName
            ),
            skippedModules: resolvedUsage.skippedModules
        )
    }

    private static func resolveLoadedModules(
        _ loadedModules: [LoadedModule],
        targetModuleName: String,
        resolver: ModuleResolver
    ) -> ResolvedUsage {
        var issues: [Issue] = []
        var skippedModules: [SkippedModule] = []
        var usedModulesByName: [String: UsedModule] = [:]

        for loaded in loadedModules where loaded.name != targetModuleName {
            switch resolver.resolve(loaded.name).status {
            case .system:
                skippedModules.append(SkippedModule(name: loaded.name, reason: .systemModule))

            case .unresolved:
                issues.append(Issue.unresolvedModule(loaded.name))
                skippedModules.append(SkippedModule(name: loaded.name, reason: .unresolved))

            case .resolved(let label):
                let existing = usedModulesByName[loaded.name]
                usedModulesByName[loaded.name] = UsedModule(
                    name: loaded.name,
                    label: label,
                    isImportedDirectly: (existing?.isImportedDirectly ?? false) || loaded.isImportedDirectly
                )
            }
        }

        return ResolvedUsage(
            usedModulesByName: usedModulesByName,
            issues: issues,
            skippedModules: skippedModules
        )
    }

    private static func cleanDeps(
        declaredByModule: [String: DeclaredDep],
        usedModulesByName: [String: UsedModule]
    ) -> [DeclaredDep] {
        declaredByModule
            .sorted(by: { $0.key < $1.key })
            .compactMap { moduleName, dep in
                usedModulesByName[moduleName] != nil ? dep : nil
            }
    }

    private static func unusedDepIssues(
        declaredByModule: [String: DeclaredDep],
        usedModulesByName: [String: UsedModule],
        targetLabel: String
    ) -> [Issue] {
        declaredByModule
            .sorted(by: { $0.key < $1.key })
            .compactMap { moduleName, dep in
                guard usedModulesByName[moduleName] == nil else { return nil }
                return Issue.unusedDep(dep, targetLabel: targetLabel)
            }
    }

    private static func missingDirectDepIssues(
        metadata: TargetMetadata,
        declaredByModule: [String: DeclaredDep],
        usedModulesByName: [String: UsedModule]
    ) -> [Issue] {
        let declaredModuleNames = Set(declaredByModule.keys)
        let reachableVia = metadata.declaredDeps.map(\.label)

        return usedModulesByName
            .sorted(by: { $0.key < $1.key })
            .compactMap { moduleName, info in
                guard !declaredModuleNames.contains(moduleName) else { return nil }
                return Issue.missingDirectDep(
                    depLabel: info.label,
                    moduleName: moduleName,
                    currentlyReachableVia: reachableVia,
                    isImportedDirectly: info.isImportedDirectly,
                    targetLabel: metadata.target.label
                )
            }
    }

    private static func candidatePrivateDepIssues(
        declaredByModule: [String: DeclaredDep],
        usedModulesByName: [String: UsedModule],
        targetLabel: String
    ) -> [Issue] {
        declaredByModule
            .sorted(by: { $0.key < $1.key })
            .compactMap { moduleName, dep in
                guard dep.kind == .dep else { return nil }
                guard let info = usedModulesByName[moduleName], !info.isImportedDirectly else { return nil }
                return Issue.candidatePrivateDep(dep, targetLabel: targetLabel)
            }
    }
}
