import Utilities

public struct AccountView {
    public let displayName: String

    public init(first: String, last: String) {
        self.displayName = formatName(first, last)
    }
}
