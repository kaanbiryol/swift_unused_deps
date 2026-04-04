import Models
import Networking

public struct DashboardView {
    private let client = APIClient()

    public init() {}

    public func display() -> User {
        client.fetchUser()
    }
}
