import iOSLib

public struct UnusedDepIOSTarget {
    let theme = Theme()

    public init() {}

    public func render() -> String {
        "color: \(theme.primaryColor)"
    }
}
