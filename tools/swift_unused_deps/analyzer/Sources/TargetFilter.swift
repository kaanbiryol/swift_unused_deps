import Foundation

public struct TargetFilter: Equatable {
    public let rawValue: String
    private let normalizedPrefix: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
        self.normalizedPrefix = Self.normalize(rawValue)
    }

    public func matches(label: String) -> Bool {
        Self.normalize(label).hasPrefix(normalizedPrefix)
    }

    static func normalize(_ value: String) -> String {
        var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.hasSuffix("...") {
            normalized.removeLast(3)
        }
        while normalized.hasPrefix("@") {
            normalized.removeFirst()
        }
        return normalized
    }
}
