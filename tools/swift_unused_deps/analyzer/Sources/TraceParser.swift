import Foundation

public enum TraceParser {

    public enum Error: Swift.Error, CustomStringConvertible {
        case emptyTraceFile(path: String?)
        case invalidTraceFile(path: String?, underlying: Swift.Error)
        case missingTraceForModule(requestedModule: String, path: String)

        public var description: String {
            switch self {
            case .emptyTraceFile(let path):
                if let path {
                    return "Trace file '\(path)' is empty."
                }
                return "Trace data is empty."
            case .invalidTraceFile(let path, let underlying):
                if let path {
                    return "Trace file '\(path)' is not valid loaded-module trace JSON: \(underlying)"
                }
                return "Trace data is not valid loaded-module trace JSON: \(underlying)"
            case .missingTraceForModule(let requestedModule, let path):
                return "Trace file '\(path)' does not contain an entry for module '\(requestedModule)'."
            }
        }
    }

    /// Extract the Swift module name from a .swiftmodule file path.
    ///
    /// Handles multiple layouts:
    ///   .../Foo.swiftmodule                              -> Foo
    ///   .../Foo.swiftmodule/arm64-apple-ios.swiftmodule  -> Foo
    ///   .../Foo.swiftmodule/Project/arm64.swiftmodule    -> Foo
    ///
    /// Returns nil if the module name cannot be determined.
    public static func extractModuleName(from path: String) -> String? {
        let components = path.split(separator: "/").map(String.init)
        for component in components.reversed() {
            guard component.hasSuffix(".swiftmodule") else { continue }
            let candidate = String(component.dropLast(".swiftmodule".count))
            // Skip architecture slugs like "arm64-apple-ios" or "arm64e-apple-macos"
            if candidate.contains("-") { continue }
            return candidate
        }
        return nil
    }

    public static func isSystemModulePath(_ path: String) -> Bool {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        return normalized.contains(".sdk/System/Library/")
            || normalized.contains(".sdk/usr/lib/")
            || normalized.contains("/usr/lib/swift/")
    }

    /// Parse a loaded module trace file.
    ///
    /// Handles two formats:
    /// 1. Single JSON object (one trace)
    /// 2. JSONL (multiple traces, one per line - happens when multiple targets
    ///    share the same trace output path via --swiftcopt)
    ///
    /// When multiple traces are present, returns modules only from the trace
    /// whose `name` matches `forModule`. If nil, returns the last trace.
    public static func parseTraceFile(at url: URL, forModule moduleName: String? = nil) throws -> [LoadedModule] {
        let data = try Data(contentsOf: url)
        let content = try decodeTraceContent(data, path: url.path)
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)

        if lines.count <= 1 {
            return try parseTraceData(data, path: url.path)
        }

        var allTraces: [(name: String, modules: [LoadedModule])] = []
        for line in lines {
            guard let lineData = line.data(using: .utf8) else {
                throw Error.invalidTraceFile(
                    path: url.path,
                    underlying: CocoaError(.fileReadCorruptFile)
                )
            }
            let trace = try decodeTrace(lineData, path: url.path)
            let modules = extractModules(from: trace)
            allTraces.append((trace.name, modules))
        }

        if let target = moduleName {
            if let match = allTraces.first(where: { $0.name == target }) {
                return match.modules
            }
            throw Error.missingTraceForModule(requestedModule: target, path: url.path)
        }

        // Otherwise return the last trace (typically the top-level target).
        return allTraces.last?.modules ?? []
    }

    /// Parse loaded module trace from raw JSON data (single trace).
    public static func parseTraceData(_ data: Data, path: String? = nil) throws -> [LoadedModule] {
        _ = try decodeTraceContent(data, path: path)
        let trace = try decodeTrace(data, path: path)
        return extractModules(from: trace)
    }

    private static func decodeTraceContent(_ data: Data, path: String?) throws -> String {
        let content = String(data: data, encoding: .utf8) ?? ""
        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw Error.emptyTraceFile(path: path)
        }
        return content
    }

    private static func decodeTrace(_ data: Data, path: String?) throws -> ModuleTrace {
        do {
            return try JSONDecoder().decode(ModuleTrace.self, from: data)
        } catch {
            throw Error.invalidTraceFile(path: path, underlying: error)
        }
    }

    private static func extractModules(from trace: ModuleTrace) -> [LoadedModule] {
        // Prefer swiftmodulesDetailedInfo (has inline name field).
        if let detailed = trace.swiftmodulesDetailedInfo, !detailed.isEmpty {
            return detailed.map { entry in
                LoadedModule(
                    name: entry.name,
                    isImportedDirectly: entry.isImportedDirectly,
                    isSystem: isSystemModulePath(entry.path)
                )
            }
        }

        // Fall back to legacy swiftmodules (extract name from path).
        guard let entries = trace.swiftmodules else { return [] }
        return entries.compactMap { entry -> LoadedModule? in
            switch entry {
            case .path(let path):
                guard let name = extractModuleName(from: path) else { return nil }
                return LoadedModule(
                    name: name,
                    isImportedDirectly: true,
                    isSystem: isSystemModulePath(path)
                )
            case .entry(let e):
                guard let name = extractModuleName(from: e.path) else { return nil }
                return LoadedModule(
                    name: name,
                    isImportedDirectly: e.isImportedDirectly,
                    isSystem: isSystemModulePath(e.path)
                )
            }
        }
    }
}
