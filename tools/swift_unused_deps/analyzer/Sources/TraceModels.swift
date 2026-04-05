import Foundation

public struct TraceEntry: Codable {
    public let path: String
    public let isImportedDirectly: Bool
}

/// Detailed module info (used in newer Swift versions).
/// Has an explicit `name` field so we don't need to parse it from the path.
public struct DetailedTraceEntry: Codable {
    public let name: String
    public let path: String
    public let isImportedDirectly: Bool
}

/// Represents a swiftmodules entry that can be either a plain string path
/// or a dict with path + isImportedDirectly.
public enum SwiftModuleEntry: Codable {
    case path(String)
    case entry(TraceEntry)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let str = try? container.decode(String.self) {
            self = .path(str)
        } else {
            self = .entry(try container.decode(TraceEntry.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .path(let path):
            try container.encode(path)
        case .entry(let entry):
            try container.encode(entry)
        }
    }
}

public struct ModuleTrace: Codable {
    public let name: String
    /// May be plain string paths or dicts, depending on Swift version.
    public let swiftmodules: [SwiftModuleEntry]?
    /// Modern format: includes module name inline. Preferred when present.
    public let swiftmodulesDetailedInfo: [DetailedTraceEntry]?
}

public struct LoadedModule: Equatable {
    public let name: String
    public let isImportedDirectly: Bool

    public init(name: String, isImportedDirectly: Bool) {
        self.name = name
        self.isImportedDirectly = isImportedDirectly
    }
}
