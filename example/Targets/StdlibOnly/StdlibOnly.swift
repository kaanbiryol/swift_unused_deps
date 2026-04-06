import Foundation

public class StdlibOnly {
    public var preferences: [String: String] = [:]

    public init() {}

    public func save() {
        UserDefaults.standard.set(preferences, forKey: "prefs")
    }
}
