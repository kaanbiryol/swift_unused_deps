import LibA // Unused import in test-only Swift code.
import LibB

public struct TestRenderer {
    private let label = Label(text: "Profile")

    public init() {}

    public func title() -> String {
        label.text
    }
}
