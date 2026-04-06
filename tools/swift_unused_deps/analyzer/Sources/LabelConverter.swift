import Foundation

/// Converts Bzlmod canonical labels (e.g., `@@swift-syntax+//:SwiftSyntax`)
/// to apparent labels (e.g., `@swiftpkg_swift_syntax//:SwiftSyntax`) so that
/// buildozer commands match the text in BUILD files.
public struct LabelConverter {
    /// Maps canonical repo name to all known apparent names for that repo.
    private let canonicalToApparent: [String: [String]]
    private let isIdentity: Bool

    init(canonicalToApparent: [String: [String]]) {
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
    /// When multiple apparent names exist for the same canonical repo, pass
    /// `buildFileContent` to disambiguate by checking which name actually
    /// appears in the BUILD file.
    ///
    /// - `@@//pkg:target` (main repo) -> `//pkg:target`
    /// - `@@swift-syntax+//:Foo` -> `@swiftpkg_swift_syntax//:Foo`
    /// - Labels without `@@` prefix -> unchanged (WORKSPACE mode)
    public func convert(_ label: String, buildFileContent: String? = nil) -> String {
        let apparent = convertCanonicalToApparent(label, buildFileContent: buildFileContent)
        return Self.stripRSPMSuffix(apparent)
    }

    /// Core canonical-to-apparent conversion logic.
    private func convertCanonicalToApparent(_ label: String, buildFileContent: String?) -> String {
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

        guard let apparentNames = canonicalToApparent[canonicalRepo], !apparentNames.isEmpty else {
            // No mapping found - use canonical name with single @
            return "@\(canonicalRepo)\(remainder)"
        }

        if apparentNames.count == 1 {
            return "@\(apparentNames[0])\(remainder)"
        }

        // Multiple apparent names - check which one the BUILD file uses.
        if let content = buildFileContent {
            for name in apparentNames {
                if content.contains("@\(name)//") || content.contains("@\(name)//:") {
                    return "@\(name)\(remainder)"
                }
            }
        }

        return "@\(apparentNames[0])\(remainder)"
    }

    /// Strip the `.rspm` suffix from external labels.
    ///
    /// `rules_swift_package_manager` creates internal `swift_library` targets with
    /// a `.rspm` suffix and public aliases without it. Bazel resolves aliases before
    /// the aspect sees them, so we strip the suffix to produce labels that match
    /// BUILD file text and have correct visibility.
    private static func stripRSPMSuffix(_ label: String) -> String {
        guard label.hasPrefix("@"), label.hasSuffix(".rspm") else { return label }
        return String(label.dropLast(".rspm".count))
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

        // Reverse the mapping: apparent -> canonical becomes canonical -> [apparent]
        var canonicalToApparent: [String: [String]] = [:]
        for (apparent, canonical) in apparentToCanonical where !apparent.isEmpty {
            canonicalToApparent[canonical, default: []].append(apparent)
        }

        guard !canonicalToApparent.isEmpty else { return nil }
        return LabelConverter(canonicalToApparent: canonicalToApparent)
    }
}
