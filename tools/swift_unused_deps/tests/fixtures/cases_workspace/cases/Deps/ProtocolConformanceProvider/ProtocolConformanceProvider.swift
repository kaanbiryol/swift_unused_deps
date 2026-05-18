import SemanticBase

extension SemanticToken: SemanticRenderable {
    public func rendered() -> String {
        rawValue
    }
}
