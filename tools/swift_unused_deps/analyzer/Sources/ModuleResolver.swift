import Foundation

public enum ResolutionStatus: Equatable {
    case resolved(label: String)
    case system
    case unresolved
}

public struct ModuleResolver {

    private let moduleMap: [String: String]
    private let systemModules: Set<String>

    public init(transitiveModuleMap: [String: String], extraSystemModules: Set<String> = []) {
        self.moduleMap = transitiveModuleMap
        self.systemModules = extraSystemModules
    }

    public func resolve(_ moduleName: String) -> ResolutionStatus {
        if systemModules.contains(moduleName) {
            return .system
        }
        if let label = moduleMap[moduleName] {
            return .resolved(label: label)
        }
        return .unresolved
    }
}
