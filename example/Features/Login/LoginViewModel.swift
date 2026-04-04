import Networking
import Models
import AppLogger

public class LoginViewModel {
    private let client = APIClient()

    public init() {}

    public func login() -> User {
        Logger.log("Logging in...")
        return client.fetchUser()
    }
}
