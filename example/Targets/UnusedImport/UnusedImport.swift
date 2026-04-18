import LibA // Unused import - auto-fix should remove this import and the dep.
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
