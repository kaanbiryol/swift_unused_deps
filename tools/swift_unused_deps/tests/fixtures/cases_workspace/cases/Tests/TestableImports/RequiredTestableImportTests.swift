@testable import TestableSubject

public func requiredInternalValue() -> String {
    InternalSubject(value: "internal").value
}
