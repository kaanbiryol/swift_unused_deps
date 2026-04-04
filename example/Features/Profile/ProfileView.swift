import Models
import Networking
import DesignSystem

public class ProfileView {
    let client = APIClient()
    let label = Label(text: "Profile")

    public init() {}

    public func render() -> String {
        let user = client.fetchUser()
        return "\(label.text): \(user.name)"
    }
}
