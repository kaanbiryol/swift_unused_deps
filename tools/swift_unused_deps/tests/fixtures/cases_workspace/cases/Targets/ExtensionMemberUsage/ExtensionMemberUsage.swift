import ExtensionBase
import ExtensionProvider
import LibA

public struct ExtensionMemberUsage {
    public init() {}

    public func render() -> String {
        FixtureContainer.shared.providedByExtensionModule()
    }
}
