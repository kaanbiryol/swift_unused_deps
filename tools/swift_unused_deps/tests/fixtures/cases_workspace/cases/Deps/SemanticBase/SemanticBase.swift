public struct SemanticStyle: Equatable {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct SemanticNumber: Equatable {
    public let value: Int

    public init(_ value: Int) {
        self.value = value
    }
}

public protocol SemanticRenderable {
    func rendered() -> String
}

public struct SemanticToken: Equatable {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}
