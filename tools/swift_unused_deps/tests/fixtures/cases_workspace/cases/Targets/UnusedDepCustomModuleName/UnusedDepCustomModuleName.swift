import DirectDepWithTransitive
import TransitiveDep
import AppLogger

public class UnusedDepCustomModuleName {
    private let client = APIClient()

    public init() {}

    public func login() -> User {
        Logger.log("Logging in...")
        return client.fetchUser()
    }
}
