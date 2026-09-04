@testable import TestableSubject

public func publicValue() -> String {
    PublicSubject(value: "public").value
}
