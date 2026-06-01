import LibB
import MacroFeature

public struct MacroFeatureTests {
    private let feature = MacroFeature()
    private let button = Button(title: "Run")

    public init() {}

    public func render() -> String {
        feature.title() + " " + button.title
    }
}
