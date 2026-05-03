@preconcurrency import LibA // Unused attributed import - auto-fix should remove this and the dep.
import LibB

public struct UnusedAttributedImport {
    private let subtitle = Label(text: "Welcome to the app")

    public init() {}

    public func render() {
        print(subtitle.text)
    }
}
