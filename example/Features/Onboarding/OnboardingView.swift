import Analytics // Unused import - no symbols from Analytics are referenced.
                 // Only detectable via index store analysis.
import DesignSystem

public struct OnboardingView {
    private let welcomeButton = Button(title: "Get Started")
    private let subtitle = Label(text: "Welcome to the app")

    public init() {}

    public func render() {
        print(welcomeButton.title)
        print(subtitle.text)
    }
}
