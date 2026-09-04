import LibB

public struct MacroFeatureTests {
    private let button = Button(title: "Run")

    public init() {}

    public func render() -> String {
        button.title
    }
}
