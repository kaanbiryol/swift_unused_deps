# swift_unused_deps

Detect unused Bazel dependencies for Swift targets.

Compares declared `deps` in BUILD files against what the Swift compiler actually loaded during compilation. Finds deps you can safely remove.

## Quick start

```sh
# Analyze
bazel build //App/... --config=unused-deps

# Print results
bazel run //:swift_unused_deps
```

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

## Prerequisites

- Bazel 9+ with [rules_swift](https://github.com/bazelbuild/rules_swift) 3.6+

## How it works

`bazel build --config=unused-deps` runs a Bazel [aspect](https://bazel.build/extending/aspects) on every Swift target. For each target, three actions run:

1. **Metadata collection** - reads `SwiftInfo` from rules_swift to get module names, declared deps, and the transitive module map
2. **Trace capture** - copies the Swift compiler's [loaded module trace](https://github.com/swiftlang/swift/blob/main/docs/LoadedModuleTrace.md) (records which `.swiftmodule` files were actually opened)
3. **Analysis** - compares declared deps vs loaded modules, writes a JSON report

Everything is cached by Bazel. Re-running after no changes is instant.

`bazel run //:swift_unused_deps` reads the JSON reports from `bazel-bin/` and prints a human-readable summary.

## What it detects

| Issue | Description | Confidence |
|-------|-------------|------------|
| **Unused dep** | Declared in BUILD but module never loaded by compiler | High |
| **Missing direct dep** | Imported in source but not declared, only reachable transitively | High/Low |
| **private_deps candidate** | Loaded by compiler but not explicitly imported in source | Low |

The report only shows high-confidence issues by default.

## Limitations

- Requires `--spawn_strategy=local` (most iOS Bazel projects already use this)
- Pure Swift targets only. Mixed Swift/ObjC targets emit a warning.
- `@_exported import` re-exports are not tracked
- Unused Swift `import` statements keep deps alive (use a linter like SwiftLint's `unused_import` rule first)

## Example

The `example/` directory contains real `swift_library` targets demonstrating each case:

```sh
bazel build //example/... --config=unused-deps
bazel run //:swift_unused_deps
```

## License

MIT
