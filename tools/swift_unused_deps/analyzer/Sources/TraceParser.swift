import Foundation

public enum TraceParser {

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
            guard component.hasSuffix(".swiftmodule") else {
                // Also handle .swiftinterface paths
                if component.hasSuffix(".swiftinterface") { continue }
                continue
            }
            let candidate = String(component.dropLast(".swiftmodule".count))
            // Skip architecture slugs like "arm64-apple-ios" or "arm64e-apple-macos"
            if candidate.contains("-") { continue }
            return candidate
        }
        return nil
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
        let content = String(data: data, encoding: .utf8) ?? ""
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)

        if lines.count <= 1 {
            return try parseTraceData(data)
        }

        var allTraces: [(name: String, modules: [LoadedModule])] = []
        for line in lines {
            guard let lineData = line.data(using: .utf8) else { continue }
            let trace = try JSONDecoder().decode(ModuleTrace.self, from: lineData)
            let modules = extractModules(from: trace)
            allTraces.append((trace.name, modules))
        }

        if let target = moduleName {
            if let match = allTraces.first(where: { $0.name == target }) {
                return match.modules
            }
        }

        // Otherwise return the last trace (typically the top-level target).
        return allTraces.last?.modules ?? []
    }

    /// Parse loaded module trace from raw JSON data (single trace).
    public static func parseTraceData(_ data: Data) throws -> [LoadedModule] {
        let trace = try JSONDecoder().decode(ModuleTrace.self, from: data)
        return extractModules(from: trace)
    }

    private static func extractModules(from trace: ModuleTrace) -> [LoadedModule] {
        // Prefer swiftmodulesDetailedInfo (has inline name field).
        if let detailed = trace.swiftmodulesDetailedInfo, !detailed.isEmpty {
            return detailed.map { entry in
                LoadedModule(name: entry.name, isImportedDirectly: entry.isImportedDirectly)
            }
        }

        // Fall back to legacy swiftmodules (extract name from path).
        guard let entries = trace.swiftmodules else { return [] }
        return entries.compactMap { entry -> LoadedModule? in
            switch entry {
            case .path(let path):
                guard let name = extractModuleName(from: path) else { return nil }
                return LoadedModule(name: name, isImportedDirectly: true)
            case .entry(let e):
                guard let name = extractModuleName(from: e.path) else { return nil }
                return LoadedModule(name: name, isImportedDirectly: e.isImportedDirectly)
            }
        }
    }
}
