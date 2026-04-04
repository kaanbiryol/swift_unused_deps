import Networking

public struct FeedView {
    private let client = APIClient()

    public init() {}

    public func loadFeed() {
        let user = client.fetchUser()
        print(user.name)
    }
}
