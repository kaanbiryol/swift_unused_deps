import UIKit

public struct Theme {
    public let primaryColor: UIColor
    public let font: UIFont

    public init() {
        self.primaryColor = .systemBlue
        self.font = .systemFont(ofSize: 16)
    }
}
