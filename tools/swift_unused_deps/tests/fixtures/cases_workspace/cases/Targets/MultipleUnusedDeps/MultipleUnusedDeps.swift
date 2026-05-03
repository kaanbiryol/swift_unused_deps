import DirectDepWithTransitive
import TransitiveDep

public class MultipleUnusedDeps {
    let client = APIClient()

    public init() {}

    public func purchase() -> User {
        return client.fetchUser()
    }
}
