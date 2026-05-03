import Foundation

public struct TargetFilter: Equatable {
    public let rawValue: String
    private let isRecursivePattern: Bool
    private let normalizedPrefix: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
        self.isRecursivePattern = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            .hasSuffix("...")
        self.normalizedPrefix = Self.normalize(rawValue)
    }

    public func matches(label: String) -> Bool {
        let normalizedLabel = Self.normalize(label)
        if isRecursivePattern {
            return normalizedLabel.hasPrefix(normalizedPrefix)
        }
        return normalizedLabel == normalizedPrefix
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
