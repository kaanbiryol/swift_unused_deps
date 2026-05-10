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
            if normalizedPrefix == "//" || normalizedPrefix.hasSuffix("//") {
                return normalizedLabel.hasPrefix(normalizedPrefix)
            }
            return normalizedLabel == normalizedPrefix
                || normalizedLabel.hasPrefix("\(normalizedPrefix):")
                || normalizedLabel.hasPrefix("\(normalizedPrefix)/")
        }
        if normalizedLabel == normalizedPrefix {
            return true
        }
        return Self.expandShorthandTarget(normalizedPrefix) == normalizedLabel
    }

    static func normalize(_ value: String) -> String {
        var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.hasSuffix("...") {
            normalized.removeLast(3)
            if normalized.hasSuffix("/") && !normalized.hasSuffix("//") {
                normalized.removeLast()
            }
        }
        while normalized.hasPrefix("@") {
            normalized.removeFirst()
        }
        return normalized
    }

    private static func expandShorthandTarget(_ value: String) -> String? {
        guard let slashSlash = value.range(of: "//") else { return nil }
        let package = value[slashSlash.upperBound...]
        guard !package.isEmpty, !package.contains(":"), !package.hasSuffix("/") else {
            return nil
        }
        guard let targetName = package.split(separator: "/").last else {
            return nil
        }
        return "\(value):\(targetName)"
    }
}
