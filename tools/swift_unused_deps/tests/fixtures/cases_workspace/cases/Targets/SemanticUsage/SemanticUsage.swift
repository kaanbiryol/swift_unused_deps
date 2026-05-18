import GeneratedAPIProvider
import OperatorProvider
import ProtocolConformanceProvider
import SemanticBase
import StaticMemberProvider

public struct SemanticUsage {
    public init() {}

    public func render() -> String {
        let style: SemanticStyle = .warning
        let total = SemanticNumber(1) + SemanticNumber(2)
        let token = SemanticToken("token")

        return [
            style.rawValue,
            "\(total.value)",
            renderToken(token),
            token.generatedDisplayName,
        ].joined(separator: "|")
    }

    private func renderToken<T: SemanticRenderable>(_ token: T) -> String {
        token.rendered()
    }
}
