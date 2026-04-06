import Foundation

/// Converts Bzlmod canonical labels (e.g., `@@swift-syntax+//:SwiftSyntax`)
/// to apparent labels (e.g., `@swiftpkg_swift_syntax//:SwiftSyntax`) so that
/// buildozer commands match the text in BUILD files.
public struct LabelConverter {
    /// Maps canonical repo name (e.g. "swift-syntax+") to apparent name (e.g. "swiftpkg_swift_syntax").
    private let canonicalToApparent: [String: String]
    private let isIdentity: Bool

    init(canonicalToApparent: [String: String]) {
        self.canonicalToApparent = canonicalToApparent
        self.isIdentity = false
    }

    private init(identity: Void) {
        self.canonicalToApparent = [:]
        self.isIdentity = true
    }

    /// A no-op converter that passes labels through unchanged (for WORKSPACE mode).
    public static let identity = LabelConverter(identity: ())

    /// Convert a canonical label to its apparent form.
    ///
    /// - `@@//pkg:target` (main repo) -> `//pkg:target`
    /// - `@@swift-syntax+//:Foo` -> `@swiftpkg_swift_syntax//:Foo`
    /// - Labels without `@@` prefix -> unchanged (WORKSPACE mode)
    public func convert(_ label: String) -> String {
        guard !isIdentity, label.hasPrefix("@@") else { return label }

        let withoutPrefix = String(label.dropFirst(2))

        // Main repo: "@@//pkg:target" -> "//pkg:target"
        if withoutPrefix.hasPrefix("//") {
            return withoutPrefix
        }

        // External repo: "@@swift-syntax+//:Foo"
        guard let range = withoutPrefix.range(of: "//") else {
            return label
        }

        let canonicalRepo = String(withoutPrefix[..<range.lowerBound])
        let remainder = String(withoutPrefix[range.lowerBound...])

        if let apparent = canonicalToApparent[canonicalRepo] {
            return "@\(apparent)\(remainder)"
        }

        // No mapping found - use canonical name with single @
        return "@\(canonicalRepo)\(remainder)"
    }

    /// Load the repo mapping by running `bazel mod dump_repo_mapping ""`.
    ///
    /// Returns `nil` on failure (WORKSPACE mode, old Bazel, or bazel not available).
    public static func loadFromBazel(workspaceDirectory: String? = nil) -> LabelConverter? {
        let workspace = workspaceDirectory
            ?? ProcessInfo.processInfo.environment["BUILD_WORKSPACE_DIRECTORY"]

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["bazel", "mod", "dump_repo_mapping", ""]
        if let ws = workspace {
            proc.currentDirectoryURL = URL(fileURLWithPath: ws)
        }

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return nil
        }

        guard proc.terminationStatus == 0 else {
            return nil
        }

        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        guard let apparentToCanonical = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return nil
        }

        // Reverse the mapping: apparent -> canonical becomes canonical -> apparent
        var canonicalToApparent: [String: String] = [:]
        for (apparent, canonical) in apparentToCanonical where !apparent.isEmpty {
            canonicalToApparent[canonical] = apparent
        }

        guard !canonicalToApparent.isEmpty else { return nil }
        return LabelConverter(canonicalToApparent: canonicalToApparent)
    }
}
