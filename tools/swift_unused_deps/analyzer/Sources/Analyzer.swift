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
        let declaredGroups = DeclaredDepGrouping.groups(metadata.declaredDeps)
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
            declaredGroups: declaredGroups,
            usedModulesByName: resolvedUsage.usedModulesByName,
            targetLabel: metadata.target.label
        ))
        issues.append(contentsOf: missingDirectDepIssues(
            metadata: metadata,
            declaredModuleNames: declaredModuleNamesIncludingPlugins(metadata),
            usedModulesByName: resolvedUsage.usedModulesByName
        ))
        issues.append(contentsOf: candidatePrivateDepIssues(
            declaredGroups: declaredGroups,
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
            if loaded.isSystem {
                if loaded.isImportedDirectly {
                    skippedModules.append(SkippedModule(name: loaded.name, reason: .systemModule))
                }
                continue
            }

            switch resolver.resolve(loaded.name) {
            case .system:
                if loaded.isImportedDirectly {
                    skippedModules.append(SkippedModule(name: loaded.name, reason: .systemModule))
                }

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
        declaredGroups: [DeclaredDepGroup],
        usedModulesByName: [String: UsedModule],
        targetLabel: String
    ) -> [Issue] {
        declaredGroups.compactMap { group in
            guard group.moduleNames.isDisjoint(with: usedModulesByName.keys) else {
                return nil
            }
            return Issue.unusedDep(group.representative, targetLabel: targetLabel)
        }
    }

    private static func missingDirectDepIssues(
        metadata: TargetMetadata,
        declaredModuleNames: Set<String>,
        usedModulesByName: [String: UsedModule]
    ) -> [Issue] {
        return usedModulesByName
            .sorted(by: { $0.key < $1.key })
            .compactMap { moduleName, info in
                guard !declaredModuleNames.contains(moduleName) else { return nil }
                return Issue.missingDirectDep(
                    depLabel: info.label,
                    moduleName: moduleName,
                    currentlyReachableVia: metadata.moduleReachableVia[moduleName] ?? [],
                    isImportedDirectly: info.isImportedDirectly,
                    targetLabel: metadata.target.label
                )
            }
    }

    private static func declaredModuleNamesIncludingPlugins(_ metadata: TargetMetadata) -> Set<String> {
        Set(metadata.declaredDeps.map(\.moduleName))
            .union(metadata.pluginDeps.map(\.moduleName))
    }

    private static func candidatePrivateDepIssues(
        declaredGroups: [DeclaredDepGroup],
        usedModulesByName: [String: UsedModule],
        targetLabel: String
    ) -> [Issue] {
        declaredGroups.compactMap { group in
            guard group.key.kind == .dep else { return nil }
            let usedModules = group.moduleNames.compactMap { usedModulesByName[$0] }
            guard !usedModules.isEmpty else { return nil }
            guard usedModules.allSatisfy({ !$0.isImportedDirectly }) else { return nil }
            return Issue.candidatePrivateDep(group.representative, targetLabel: targetLabel)
        }
    }
}
