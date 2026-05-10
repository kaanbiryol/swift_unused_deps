struct DeclaredDepGroupKey: Hashable {
    let label: String
    let kind: DepKind
}

struct DeclaredDepGroup {
    let key: DeclaredDepGroupKey
    let deps: [DeclaredDep]

    var representative: DeclaredDep {
        deps.sorted { lhs, rhs in
            if lhs.moduleName == rhs.moduleName {
                return lhs.label < rhs.label
            }
            return lhs.moduleName < rhs.moduleName
        }[0]
    }

    var moduleNames: Set<String> {
        Set(deps.map(\.moduleName))
    }
}

enum DeclaredDepGrouping {
    static func groups(_ deps: [DeclaredDep]) -> [DeclaredDepGroup] {
        Dictionary(grouping: deps) {
            DeclaredDepGroupKey(label: $0.label, kind: $0.kind)
        }
        .map { key, deps in
            DeclaredDepGroup(key: key, deps: deps)
        }
        .sorted { lhs, rhs in
            if lhs.key.label == rhs.key.label {
                return lhs.key.kind.rawValue < rhs.key.kind.rawValue
            }
            return lhs.key.label < rhs.key.label
        }
    }
}
