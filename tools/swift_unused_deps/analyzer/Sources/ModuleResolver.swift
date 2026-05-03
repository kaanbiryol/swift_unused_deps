import Foundation

public enum ResolutionStatus: Equatable {
    case resolved(label: String)
    case system
    case unresolved
}

public struct ResolvedModule {
    public let moduleName: String
    public let status: ResolutionStatus
}

public struct ModuleResolver {

    private let moduleMap: [String: String]
    private let systemModules: Set<String>

    public init(transitiveModuleMap: [String: String], extraSystemModules: Set<String> = []) {
        self.moduleMap = transitiveModuleMap
        self.systemModules = extraSystemModules
    }

    public func resolve(_ moduleName: String) -> ResolvedModule {
        if systemModules.contains(moduleName) {
            return ResolvedModule(moduleName: moduleName, status: .system)
        }
        if let label = moduleMap[moduleName] {
            return ResolvedModule(moduleName: moduleName, status: .resolved(label: label))
        }
        return ResolvedModule(moduleName: moduleName, status: .unresolved)
    }

    public func isSystemModule(_ name: String) -> Bool {
        systemModules.contains(name)
    }
}
