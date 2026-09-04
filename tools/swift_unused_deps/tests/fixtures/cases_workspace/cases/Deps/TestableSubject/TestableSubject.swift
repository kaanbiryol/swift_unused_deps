public struct PublicSubject {
    public let value: String

    public init(value: String) {
        self.value = value
    }
}

struct InternalSubject {
    let value: String

    init(value: String) {
        self.value = value
    }
}
