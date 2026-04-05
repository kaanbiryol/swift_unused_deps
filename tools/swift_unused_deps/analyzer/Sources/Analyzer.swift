import Foundation

public enum Analyzer {

    public static func analyze(
        metadata: TargetMetadata,
        loadedModules: [LoadedModule],
        resolver: ModuleResolver
    ) -> AnalysisResult {
        var issues: [Issue] = []
        var cleanDeps: [DeclaredDep] = []
        var skippedModules: [(name: String, reason: String)] = []

        if metadata.target.isMixedSource {
            issues.append(Issue(
                kind: .unresolvedModule,
                confidence: .low,
                reason: "Target \(metadata.target.label) has mixed Swift/ObjC sources. Analysis may be incomplete - ObjC imports are not tracked.",
                suggestedAction: .investigate
            ))
        }

        var declaredByModule: [String: DeclaredDep] = [:]
        for dep in metadata.declaredDeps {
            declaredByModule[dep.moduleName] = dep
        }

        var usedModules: [String: (label: String, isImportedDirectly: Bool)] = [:]

        for loaded in loadedModules {
            if loaded.name == metadata.target.moduleName { continue }

            let resolved = resolver.resolve(loaded.name)
            switch resolved.status {
            case .system:
                skippedModules.append((loaded.name, "system_module"))

            case .unresolved:
                issues.append(Issue(
                    kind: .unresolvedModule,
                    confidence: .low,
                    reason: "Module '\(loaded.name)' was loaded during compilation but could not be mapped to a Bazel label",
                    suggestedAction: .investigate,
                    depModule: loaded.name
                ))
                skippedModules.append((loaded.name, "unresolved"))

            case .resolved(let label):
                usedModules[loaded.name] = (label, loaded.isImportedDirectly)
            }
        }

        let usedModuleNames = Set(usedModules.keys)
        for (moduleName, dep) in declaredByModule.sorted(by: { $0.key < $1.key }) {
            if !usedModuleNames.contains(moduleName) {
                let attrName = dep.kind == .privateDep ? "private_deps" : "deps"
                issues.append(Issue(
                    kind: .unusedDep,
                    confidence: .high,
                    reason: "Module '\(moduleName)' is declared as a \(dep.kind.rawValue) but was not loaded during compilation",
                    suggestedAction: .remove,
                    depLabel: dep.label,
                    depModule: moduleName,
                    depKind: dep.kind,
                    buildozerCommand: "buildozer 'remove \(attrName) \(dep.label)' \(metadata.target.label)"
                ))
            } else {
                cleanDeps.append(dep)
            }
        }

        let declaredModuleNames = Set(declaredByModule.keys)
        for (moduleName, info) in usedModules.sorted(by: { $0.key < $1.key }) {
            if declaredModuleNames.contains(moduleName) { continue }

            let reachableVia = metadata.declaredDeps.map(\.label)
            let confidence: Confidence = info.isImportedDirectly ? .high : .low
            let action: SuggestedAction = info.isImportedDirectly ? .addDep : .investigate

            issues.append(Issue(
                kind: .missingDirectDep,
                confidence: confidence,
                reason: "Module '\(moduleName)' is loaded (isImportedDirectly=\(info.isImportedDirectly)) but not declared as a dep",
                suggestedAction: action,
                depLabel: info.label,
                depModule: moduleName,
                currentlyReachableVia: reachableVia,
                buildozerCommand: action == .addDep
                    ? "buildozer 'add deps \(info.label)' \(metadata.target.label)"
                    : nil
            ))
        }

        for (moduleName, dep) in declaredByModule.sorted(by: { $0.key < $1.key }) {
            guard dep.kind == .dep else { continue }
            guard let info = usedModules[moduleName] else { continue }
            if !info.isImportedDirectly {
                issues.append(Issue(
                    kind: .candidatePrivateDep,
                    confidence: .low,
                    reason: "Module '\(moduleName)' is loaded but not directly imported in source code - may be suitable for private_deps",
                    suggestedAction: .moveToPrivateDeps,
                    depLabel: dep.label,
                    depModule: moduleName,
                    depKind: dep.kind,
                    buildozerCommand: "buildozer 'move deps private_deps \(dep.label)' \(metadata.target.label)"
                ))
            }
        }

        return AnalysisResult(
            target: metadata.target.label,
            moduleName: metadata.target.moduleName,
            issues: issues,
            cleanDeps: cleanDeps,
            skippedModules: skippedModules
        )
    }
}
