# swift_unused_deps

Detect unused Bazel dependencies for Swift targets.

## Quick start

```sh
# Analyze
bazel build //App/... --config=unused-deps

# Print results
bazel run //:swift_unused_deps
```

Output:

```
@@//Features/Checkout:Checkout
  UNUSED: @@//Core/Analytics:Analytics (module: Analytics)
  Fix: buildozer 'remove deps @@//Core/Analytics:Analytics' @@//Features/Checkout:Checkout

@@//Features/Login:Login
  UNUSED: @@//Core/Analytics:Analytics (module: Analytics)
  Fix: buildozer 'remove deps @@//Core/Analytics:Analytics' @@//Features/Login:Login

4 unused dep(s) found across 10 targets.
```

Filter to a subtree:

```sh
bazel run //:swift_unused_deps -- //App/Features/Login
```

## Setup

1. Add to `MODULE.bazel`:
   ```python
   bazel_dep(name = "swift_unused_deps", version = "0.1.0")
   ```

2. Add to `.bazelrc`:
   ```
   build:unused-deps --aspects=@swift_unused_deps//tools/swift_unused_deps/aspect:deps_info.bzl%swift_deps_aspect
   build:unused-deps --output_groups=swift_deps_report
   build:unused-deps --@build_bazel_rules_swift//swift:copt=-emit-loaded-module-trace
   build:unused-deps --spawn_strategy=local
   ```

### Prerequisites

- Bazel 9+ with [rules_swift](https://github.com/bazelbuild/rules_swift) 3.6+

## How it works

`bazel build --config=unused-deps` runs three Bazel actions per Swift target:

1. **Metadata collection** - aspect reads `SwiftInfo` from rules_swift to get module names, declared deps, transitive module map
2. **Trace capture** - copies the Swift compiler's loaded module trace (which `.swiftmodule` files were actually opened)
3. **Analysis** - Swift binary compares declared deps vs loaded modules, writes a JSON report

Everything is cached by Bazel. Re-running after no changes is instant.

`bazel run //:swift_unused_deps` reads the JSON reports from `bazel-bin/` and prints a human-readable summary.

## Limitations (v1)

- Requires `--spawn_strategy=local` (trace files are undeclared compiler outputs)
- Pure Swift targets only. Mixed Swift/ObjC targets emit a warning.
- `@_exported import` re-exports are not tracked.

## Architecture

```
aspect/
  deps_info.bzl           Aspect: collects metadata, captures traces, runs analyzer
  providers.bzl           SwiftDepsInfo provider (module-name-to-label mapping)

analyzer/Sources/
  CLI.swift               Analyzer binary (invoked by aspect as build action)
  ReportCLI.swift         Report printer (invoked by user via bazel run)
  Analyzer.swift          Core detection algorithm
  Models.swift            Codable data models
  TraceParser.swift       Swift loaded module trace parser
  ModuleResolver.swift    Module name -> Bazel label resolution
  Report.swift            Output formatting (text + JSON)
```
