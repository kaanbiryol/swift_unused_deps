public enum ImportRefiner {

    /// Filters out modules that are directly imported but have no symbol
    /// references in the index store. Returns only the modules confirmed used.
    public static func refine(
        loadedModules: [LoadedModule],
        targetModuleName: String,
        indexStoreUsage: [SourceFileModuleUsage]
    ) -> [LoadedModule] {
        let targetUsage = indexStoreUsage.filter { $0.moduleName == targetModuleName }
        guard !targetUsage.isEmpty else { return loadedModules }

        var referencedModules = Set<String>()
        for usage in targetUsage {
            referencedModules.formUnion(usage.referencedModules)
        }

        return loadedModules.filter { module in
            !module.isImportedDirectly || referencedModules.contains(module.name)
        }
    }
}
