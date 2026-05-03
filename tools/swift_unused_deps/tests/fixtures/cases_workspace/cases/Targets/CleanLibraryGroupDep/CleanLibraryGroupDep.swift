import LibraryGroup

public struct CleanLibraryGroupDep {
    public let displayName: String

    public init(first: String, last: String) {
        self.displayName = formatName(first, last)
    }
}
