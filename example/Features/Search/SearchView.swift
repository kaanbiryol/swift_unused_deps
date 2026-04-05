import Foundation
import RegexBuilder

public struct SearchView {
    public init() {}

    public func search(in text: String, for pattern: String) -> Bool {
        let regex = Regex {
            pattern
        }
        return text.contains(regex)
    }
}
