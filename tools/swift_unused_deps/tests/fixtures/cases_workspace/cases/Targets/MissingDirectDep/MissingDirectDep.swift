import TransitiveDep
import DirectDepWithTransitive

public struct MissingDirectDep {
    private let client = APIClient()

    public init() {}

    public func display() -> User {
        client.fetchUser()
    }
}
