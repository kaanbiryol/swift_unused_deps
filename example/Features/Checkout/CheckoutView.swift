import Networking
import Models

public class CheckoutView {
    let client = APIClient()

    public init() {}

    public func purchase() -> User {
        return client.fetchUser()
    }
}
