import iOSLib

public struct CleanIOSTarget {
    let theme = Theme()

    public init() {}

    public func render() -> String {
        "font size: \(theme.font.pointSize)"
    }
}
