import Foundation

enum ResolutionStatus: Equatable {
    case resolved(label: String)
    case system
    case unresolved
}

struct ModuleResolver {

    private let moduleMap: [String: String]
    private let systemModules: Set<String>

    init(transitiveModuleMap: [String: String], extraSystemModules: Set<String> = []) {
        self.moduleMap = transitiveModuleMap
        self.systemModules = extraSystemModules
    }

    func resolve(_ moduleName: String) -> ResolutionStatus {
        if systemModules.contains(moduleName) {
            return .system
        }
        if let label = moduleMap[moduleName] {
            return .resolved(label: label)
        }
        return .unresolved
    }
}
