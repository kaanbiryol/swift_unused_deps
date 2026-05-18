import Foundation

/// Converts Bzlmod canonical labels (e.g., `@@swift-syntax+//:SwiftSyntax`)
/// to apparent labels (e.g., `@swiftpkg_swift_syntax//:SwiftSyntax`) so that
/// buildozer commands match the text in BUILD files.
struct LabelConverter {
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
    static let identity = LabelConverter(identity: ())

    /// Convert a canonical label to its apparent form.
    ///
    /// When multiple apparent names exist for the same canonical repo, pass
    /// `buildFileContent` to disambiguate by checking which name actually
    /// appears in the BUILD file.
    ///
    /// - `@@//pkg:target` (main repo) -> `//pkg:target`
    /// - `@@swift-syntax+//:Foo` -> `@swiftpkg_swift_syntax//:Foo`
    /// - Labels without `@@` prefix -> unchanged (WORKSPACE mode)
    func convert(_ label: String, buildFileContent: String? = nil) -> String {
        let apparent = convertCanonicalToApparent(label, buildFileContent: buildFileContent)
        let normalized = Self.normalizeRSPMCanonicalRepo(apparent)
        return Self.stripRSPMSuffix(normalized)
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

    /// Convert rules_swift_package_manager extension canonical repos to the
    /// apparent repo names users can write in BUILD files.
    ///
    /// Bazel actions may run without a workspace repo mapping available, but
    /// labels from rules_swift_package_manager still have a stable canonical
    /// shape:
    ///
    /// `@@rules_swift_package_manager++_swift_deps+++swift_deps+swiftpkg_x//:Y`
    /// becomes `@swiftpkg_x//:Y`.
    private static func normalizeRSPMCanonicalRepo(_ label: String) -> String {
        let atPrefix: String
        let withoutAt: String
        if label.hasPrefix("@@") {
            atPrefix = "@"
            withoutAt = String(label.dropFirst(2))
        } else if label.hasPrefix("@") {
            atPrefix = "@"
            withoutAt = String(label.dropFirst())
        } else {
            return label
        }

        guard let packageRange = withoutAt.range(of: "//") else {
            return label
        }

        let repo = String(withoutAt[..<packageRange.lowerBound])
        guard repo.hasPrefix("rules_swift_package_manager"),
              let apparentRange = repo.range(of: "swiftpkg_", options: .backwards)
        else {
            return label
        }

        let apparentRepo = String(repo[apparentRange.lowerBound...])
        let remainder = String(withoutAt[packageRange.lowerBound...])
        return "\(atPrefix)\(apparentRepo)\(remainder)"
    }

    static let repoMappingDumpArguments = [
        "bazel",
        "mod",
        "--lockfile_mode=off",
        "dump_repo_mapping",
        "",
    ]

    /// Load the repo mapping by running `bazel mod --lockfile_mode=off dump_repo_mapping ""`.
    ///
    /// Returns `nil` on failure (WORKSPACE mode, old Bazel, or bazel not available).
    static func loadFromBazel(workspaceDirectory: String? = nil) -> LabelConverter? {
        let workspace = workspaceDirectory
            ?? ProcessInfo.processInfo.environment["BUILD_WORKSPACE_DIRECTORY"]

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = repoMappingDumpArguments
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
