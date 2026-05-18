import Foundation

struct MetadataArtifactCatalog {
    let metadataFiles: [URL]
}

enum MetadataArtifactDiscovery {
    static func directoryExists(at url: URL, fileManager: FileManager = .default) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    static func discover(in baseURL: URL, fileManager: FileManager = .default) -> MetadataArtifactCatalog {
        var metadataFiles: [URL] = []

        if let enumerator = fileManager.enumerator(
            at: baseURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator {
                let name = url.lastPathComponent
                if name.hasSuffix(".swift_deps_info.json") {
                    metadataFiles.append(url)
                }
            }
        }

        metadataFiles.sort { $0.path < $1.path }
        return MetadataArtifactCatalog(metadataFiles: metadataFiles)
    }

    static func loadMetadata(
        from metadataFile: URL,
        warnings: inout [String]
    ) -> TargetMetadata? {
        do {
            let data = try Data(contentsOf: metadataFile)
            return try JSONDecoder().decode(TargetMetadata.self, from: data)
        } catch {
            warnings.append("Failed to parse \(metadataFile.path): \(error)")
            return nil
        }
    }

    static func readBuildFile(for targetLabel: String, workspaceDirectory: URL?) -> String? {
        guard let workspaceDirectory else {
            return nil
        }

        var label = targetLabel
        while label.hasPrefix("@") { label.removeFirst() }
        guard let slashSlash = label.range(of: "//") else { return nil }
        let afterSlash = label[slashSlash.upperBound...]
        let packagePath = String(afterSlash.prefix(while: { $0 != ":" }))

        let directory = workspaceDirectory.appendingPathComponent(packagePath)
        for name in ["BUILD.bazel", "BUILD"] {
            let path = directory.appendingPathComponent(name).path
            if let content = try? String(contentsOfFile: path, encoding: .utf8) {
                return content
            }
        }
        return nil
    }
}
