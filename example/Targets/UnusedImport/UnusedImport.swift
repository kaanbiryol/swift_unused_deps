import LibA // Unused import - no symbols from LibA are referenced.
            // Only detectable via index store analysis.
import LibB

public struct UnusedImport {
    private let welcomeButton = Button(title: "Get Started")
    private let subtitle = Label(text: "Welcome to the app")

    public init() {}

    public func render() {
        print(welcomeButton.title)
        print(subtitle.text)
    }
}
