import SemanticBase

public func + (lhs: SemanticNumber, rhs: SemanticNumber) -> SemanticNumber {
    SemanticNumber(lhs.value + rhs.value)
}
