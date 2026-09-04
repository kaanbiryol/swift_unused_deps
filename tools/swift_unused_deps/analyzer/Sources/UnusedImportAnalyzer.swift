enum UnusedImportAnalyzer {
    static func merge(
        baseResult: AnalysisResult,
        unusedImportIssues: [Issue]
    ) -> AnalysisResult {
        guard !unusedImportIssues.isEmpty else { return baseResult }
        let unusedImportModules = Set(
            unusedImportIssues
                .filter { $0.kind == .unusedImport }
                .compactMap(\.depModule)
        )
        let filteredBaseIssues = baseResult.issues.filter { issue in
            !(issue.kind == .missingDirectDep && issue.depModule.map(unusedImportModules.contains) == true)
        }
        return AnalysisResult(
            target: baseResult.target,
            moduleName: baseResult.moduleName,
            issues: filteredBaseIssues + unusedImportIssues,
            cleanDeps: baseResult.cleanDeps.filter { !unusedImportModules.contains($0.moduleName) },
            skippedModules: baseResult.skippedModules
        )
    }

    static func filterReferencedModules(
        _ sourceFileUsage: [SourceFileModuleUsage],
        for metadata: TargetMetadata,
        extraSystemModules: Set<String>
    ) -> [SourceFileModuleUsage] {
        let knownModules = Set(metadata.transitiveModuleMap.keys)
            .union([metadata.target.moduleName])
            .union(extraSystemModules)
            .union(sourceFileUsage.flatMap(\.systemModules))

        return sourceFileUsage.map { usage in
            SourceFileModuleUsage(
                sourceFile: usage.sourceFile,
                isGenerated: usage.isGenerated,
                moduleName: usage.moduleName,
                referencedModules: usage.referencedModules.intersection(knownModules),
                loadedModules: usage.loadedModules,
                systemModules: usage.systemModules,
                directImports: usage.directImports,
                reexportedImports: usage.reexportedImports,
                testableImports: usage.testableImports,
                requiredTestableImports: usage.requiredTestableImports,
                unnecessaryTestableImports: usage.unnecessaryTestableImports,
                conditionalImports: usage.conditionalImports
            )
        }
    }

    static func issues(
        metadata: TargetMetadata,
        sourceFileUsage: [SourceFileModuleUsage]
    ) -> [Issue] {
        guard !metadata.target.isMixedSource else { return [] }
        guard !sourceFileUsage.isEmpty else { return [] }

        let referencedModules = sourceFileUsage.reduce(into: Set<String>()) { partial, usage in
            partial.formUnion(usage.referencedModules)
        }
        let reexportedImportModules = sourceFileUsage.reduce(into: Set<String>()) { partial, usage in
            partial.formUnion(usage.reexportedImports)
        }
        let testableImportModules = sourceFileUsage.reduce(into: Set<String>()) { partial, usage in
            partial.formUnion(usage.testableImports)
        }
        let conditionalImportModules = sourceFileUsage.reduce(into: Set<String>()) { partial, usage in
            partial.formUnion(usage.conditionalImports)
        }

        let dependencyIssues = DeclaredDepGrouping.groups(metadata.declaredDeps).flatMap { group -> [Issue] in
            var shouldRemoveDep = group.moduleNames.isDisjoint(with: referencedModules)
                && group.moduleNames.isDisjoint(with: reexportedImportModules)
                && group.moduleNames.isDisjoint(with: testableImportModules)
                && group.moduleNames.isDisjoint(with: conditionalImportModules)

            return group.deps.sorted { $0.moduleName < $1.moduleName }.compactMap { dep in
                guard !referencedModules.contains(dep.moduleName) else { return nil }
                guard !reexportedImportModules.contains(dep.moduleName) else { return nil }
                guard !testableImportModules.contains(dep.moduleName) else { return nil }
                guard !conditionalImportModules.contains(dep.moduleName) else { return nil }

                let removals = sourceFileUsage.compactMap { usage -> SourceImportRemoval? in
                    guard !usage.isGenerated else { return nil }
                    guard usage.directImports.contains(dep.moduleName) else { return nil }
                    guard !usage.referencedModules.contains(dep.moduleName) else { return nil }
                    guard !usage.reexportedImports.contains(dep.moduleName) else { return nil }
                    guard !usage.testableImports.contains(dep.moduleName) else { return nil }
                    guard !usage.conditionalImports.contains(dep.moduleName) else { return nil }
                    return SourceImportRemoval(
                        filePath: usage.sourceFile,
                        moduleName: dep.moduleName
                    )
                }

                guard !removals.isEmpty else { return nil }
                let removeDep = shouldRemoveDep
                    && metadata.target.buildEdit.canRemove(group.key.label)
                shouldRemoveDep = false
                return Issue.unusedImport(
                    dep,
                    targetLabel: metadata.target.buildEdit.target,
                    sourceImportRemovals: removals,
                    removeDep: removeDep,
                    depsAttribute: metadata.target.buildEdit.depsAttribute
                )
            }
        } + transitiveIssues(
            metadata: metadata,
            sourceFileUsage: sourceFileUsage,
            referencedModules: referencedModules,
            reexportedImportModules: reexportedImportModules,
            testableImportModules: testableImportModules,
            conditionalImportModules: conditionalImportModules
        )

        return dependencyIssues + testableImportIssues(sourceFileUsage)
    }

    private static func testableImportIssues(
        _ sourceFileUsage: [SourceFileModuleUsage]
    ) -> [Issue] {
        sourceFileUsage.flatMap { usage -> [Issue] in
            guard !usage.isGenerated else { return [] }

            return usage.testableImports.sorted().compactMap { moduleName in
                guard !usage.conditionalImports.contains(moduleName) else { return nil }

                if !usage.referencedModules.contains(moduleName) {
                    return Issue.unusedTestableImport(
                        moduleName: moduleName,
                        sourceFile: usage.sourceFile
                    )
                }

                guard usage.unnecessaryTestableImports.contains(moduleName),
                      !usage.requiredTestableImports.contains(moduleName)
                else {
                    return nil
                }
                return Issue.unnecessaryTestableAttribute(
                    moduleName: moduleName,
                    sourceFile: usage.sourceFile
                )
            }
        }
    }

    private static func transitiveIssues(
        metadata: TargetMetadata,
        sourceFileUsage: [SourceFileModuleUsage],
        referencedModules: Set<String>,
        reexportedImportModules: Set<String>,
        testableImportModules: Set<String>,
        conditionalImportModules: Set<String>
    ) -> [Issue] {
        let declaredModuleNames = Set(metadata.declaredDeps.map(\.moduleName))
            .union(metadata.pluginDeps.map(\.moduleName))
        let directImports = sourceFileUsage.reduce(into: Set<String>()) { partial, usage in
            partial.formUnion(usage.directImports)
        }

        return directImports
            .subtracting(declaredModuleNames)
            .subtracting(referencedModules)
            .subtracting(reexportedImportModules)
            .subtracting(testableImportModules)
            .subtracting(conditionalImportModules)
            .filter { $0 != metadata.target.moduleName }
            .sorted()
            .compactMap { moduleName -> Issue? in
                guard let label = metadata.transitiveModuleMap[moduleName] else {
                    return nil
                }
                let removals = sourceFileUsage.compactMap { usage -> SourceImportRemoval? in
                    guard !usage.isGenerated else { return nil }
                    guard usage.directImports.contains(moduleName) else { return nil }
                    guard !usage.referencedModules.contains(moduleName) else { return nil }
                    guard !usage.reexportedImports.contains(moduleName) else { return nil }
                    guard !usage.testableImports.contains(moduleName) else { return nil }
                    guard !usage.conditionalImports.contains(moduleName) else { return nil }
                    return SourceImportRemoval(
                        filePath: usage.sourceFile,
                        moduleName: moduleName
                    )
                }
                guard !removals.isEmpty else { return nil }
                return Issue.unusedImport(
                    DeclaredDep(label: label, moduleName: moduleName, kind: .dep),
                    targetLabel: metadata.target.buildEdit.target,
                    sourceImportRemovals: removals,
                    removeDep: false
                )
            }
    }
}
