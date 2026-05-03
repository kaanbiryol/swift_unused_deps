import TransitiveDep
import DirectDepWithTransitive
import LibB

public class CleanTarget {
    let client = APIClient()
    let label = Label(text: "Profile")

    public init() {}

    public func render() -> String {
        let user = client.fetchUser()
        return "\(label.text): \(user.name)"
    }
}
