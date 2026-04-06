import DirectDepWithTransitive

public struct CandidatePrivateDep {
    private let client = APIClient()

    public init() {}

    public func loadFeed() {
        let user = client.fetchUser()
        print(user.name)
    }
}
