import Foundation

public enum BuildEditOperation: String, Codable {
    case add
    case remove
    case move
}

public struct BuildEdit: Codable, Equatable, Hashable {
    public let operation: BuildEditOperation
    public let attribute: String
    public let label: String
    public let target: String
    public let destinationAttribute: String?

    enum CodingKeys: String, CodingKey {
        case operation
        case attribute
        case label
        case target
        case destinationAttribute = "destination_attribute"
    }

    public init(
        operation: BuildEditOperation,
        attribute: String,
        label: String,
        target: String,
        destinationAttribute: String? = nil
    ) {
        self.operation = operation
        self.attribute = attribute
        self.label = label
        self.target = target
        self.destinationAttribute = destinationAttribute
    }

    public var buildozerCommand: BuildozerCommand {
        switch operation {
        case .add:
            return BuildozerCommand(action: "add \(attribute) \(label)", target: target)
        case .remove:
            return BuildozerCommand(action: "remove \(attribute) \(label)", target: target)
        case .move:
            let destination = destinationAttribute ?? ""
            return BuildozerCommand(action: "move \(attribute) \(destination) \(label)", target: target)
        }
    }

    public static func from(command: BuildozerCommand) -> BuildEdit? {
        let parts = command.action.split(separator: " ", omittingEmptySubsequences: true).map(String.init)

        switch parts.first {
        case "add" where parts.count == 3:
            return BuildEdit(
                operation: .add,
                attribute: parts[1],
                label: parts[2],
                target: command.target
            )
        case "remove" where parts.count == 3:
            return BuildEdit(
                operation: .remove,
                attribute: parts[1],
                label: parts[2],
                target: command.target
            )
        case "move" where parts.count == 4:
            return BuildEdit(
                operation: .move,
                attribute: parts[1],
                label: parts[3],
                target: command.target,
                destinationAttribute: parts[2]
            )
        default:
            return nil
        }
    }
}

public struct FixPlan: Codable, Equatable {
    public let schemaVersion: Int
    public let sourceImportRemovals: [SourceImportRemoval]
    public let buildEdits: [BuildEdit]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case sourceImportRemovals = "source_import_removals"
        case buildEdits = "build_edits"
    }

    public init(
        schemaVersion: Int = 1,
        sourceImportRemovals: [SourceImportRemoval],
        buildEdits: [BuildEdit]
    ) {
        self.schemaVersion = schemaVersion
        self.sourceImportRemovals = sourceImportRemovals.sorted {
            if $0.filePath == $1.filePath {
                return $0.moduleName < $1.moduleName
            }
            return $0.filePath < $1.filePath
        }
        self.buildEdits = buildEdits.sorted {
            if $0.target == $1.target {
                if $0.operation.rawValue == $1.operation.rawValue {
                    if $0.attribute == $1.attribute {
                        return $0.label < $1.label
                    }
                    return $0.attribute < $1.attribute
                }
                return $0.operation.rawValue < $1.operation.rawValue
            }
            return $0.target < $1.target
        }
    }

    public var isEmpty: Bool {
        sourceImportRemovals.isEmpty && buildEdits.isEmpty
    }

    public var buildozerCommands: [BuildozerCommand] {
        buildEdits.map(\.buildozerCommand)
    }

    public static func from(
        results: [AnalysisResult],
        minConfidence: Confidence = .high
    ) -> FixPlan {
        let fixableIssues = results
            .flatMap(\.issues)
            .filter { $0.confidence >= minConfidence }

        let removals = Array(Set(fixableIssues.flatMap(\.sourceImportRemovals)))
        let edits = Array(Set(fixableIssues.compactMap(\.buildozerCommand).compactMap(BuildEdit.from)))

        return FixPlan(
            sourceImportRemovals: removals,
            buildEdits: edits
        )
    }

    public static func merge(_ plans: [FixPlan]) -> FixPlan {
        FixPlan(
            sourceImportRemovals: Array(Set(plans.flatMap(\.sourceImportRemovals))),
            buildEdits: Array(Set(plans.flatMap(\.buildEdits)))
        )
    }

    public static func formatJSON(_ plan: FixPlan) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(plan)
        return String(decoding: data, as: UTF8.self)
    }

    public static func read(from url: URL) throws -> FixPlan {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(FixPlan.self, from: data)
    }
}
