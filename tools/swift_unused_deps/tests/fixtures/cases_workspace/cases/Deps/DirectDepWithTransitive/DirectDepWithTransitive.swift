import TransitiveDep

public struct APIClient {
    public init() {}

    public func fetchUser() -> User {
        return User(id: "1", name: "Test")
    }
}
