# swift_unused_deps

Detect unused and missing direct Bazel dependencies for Swift targets.

Compares declared `deps` in BUILD files against what the Swift compiler actually loaded during compilation. Finds deps you can safely remove and deps you should add.

## Quick start

```sh
# Analyze and print results (builds automatically)
bazel run @swift_unused_deps//:swift_unused_deps -- //App/...

# Auto-fix high-confidence issues
bazel run @swift_unused_deps//:swift_unused_deps -- //App/... --fix
```

```
//Features/Checkout:Checkout
  Status: 1 issue found

  [HIGH] UNUSED_DEP: //Core/Analytics:Analytics (module: Analytics)
         Module 'Analytics' is declared as a dep but was not loaded during compilation
         Fix: buildozer 'remove deps //Core/Analytics:Analytics' //Features/Checkout:Checkout

Summary: 10 targets analyzed, 1 issue found.
  1 high.

Run with --fix to automatically apply fixes.
```

## Setup

### 1. Add the dependency

In your `MODULE.bazel`:

```python
bazel_dep(name = "swift_unused_deps", version = "0.1.0")
```

### 2. Configure your `.bazelrc`

```
build:unused-deps --aspects=@swift_unused_deps//tools/swift_unused_deps/aspect:deps_info.bzl%swift_deps_aspect
build:unused-deps --output_groups=swift_deps_report
build:unused-deps --@build_bazel_rules_swift//swift:copt=-index-store-path
build:unused-deps --@build_bazel_rules_swift//swift:copt=/tmp/swift_unused_deps_index_store
build:unused-deps --spawn_strategy=local
```

For iOS projects that require a platform setting:

```
build:unused-deps-ios --config=unused-deps
build:unused-deps-ios --platforms=@apple_support//platforms:ios_sim_arm64
```

### Prerequisites

- Bazel 9+ with [rules_swift](https://github.com/bazelbuild/rules_swift) 3.6+

## Usage

### Basic analysis

```sh
# Analyze all targets under a path
bazel run @swift_unused_deps//:swift_unused_deps -- //libraries/...

# Analyze a specific target
bazel run @swift_unused_deps//:swift_unused_deps -- //App:App
```

When you provide a target pattern, the tool automatically runs `bazel build <pattern> --config=unused-deps` first. Use `--no-build` to skip this if you've already built:

```sh
# Build separately, then analyze
bazel build //libraries/... --config=unused-deps
bazel run @swift_unused_deps//:swift_unused_deps -- //libraries/... --no-build
```

### Auto-fix

Use `--fix` to automatically apply high-confidence fixes using [buildozer](https://github.com/bazelbuild/buildtools/tree/master/buildozer):

```sh
bazel run @swift_unused_deps//:swift_unused_deps -- //libraries/... --fix
```

This runs buildozer commands to:
- Remove unused deps (`remove deps`)
- Add missing direct deps (`add deps`)

Only high-confidence issues are fixed. Low-confidence issues (like unresolved modules) are reported for manual investigation.

### JSON output

```sh
bazel run @swift_unused_deps//:swift_unused_deps -- //libraries/... --json
```

### Filtering by confidence

```sh
# Only show high-confidence issues
bazel run @swift_unused_deps//:swift_unused_deps -- //libraries/... --min-confidence high
```

Values: `low` (default), `medium`, `high`.

### Extra system modules

If the tool reports false positives for modules that are part of the system SDK but not in the built-in list:

```sh
bazel run @swift_unused_deps//:swift_unused_deps -- //App/... --extra-system-modules MySystemModule,AnotherModule
```

### All options

| Option | Description |
|--------|-------------|
| `PATTERN` | Bazel target pattern to analyze (e.g. `//libraries/...`) |
| `--fix` | Run buildozer to fix high-confidence issues |
| `--json` | Output JSON instead of text |
| `--min-confidence` | Minimum confidence level: `low`, `medium`, `high` (default: `low`) |
| `--extra-system-modules` | Comma-separated module names to treat as system modules |
| `--no-build` | Skip the automatic `bazel build --config=unused-deps` step |
| `--index-store-path` | Path to Swift index store (default: `/tmp/swift_unused_deps_index_store`) |
| `--bazel-bin` | Explicit path to bazel-bin (auto-detected by default) |

## What it detects

| Issue | Description | Confidence |
|-------|-------------|------------|
| **Unused dep** | Declared in BUILD but module never loaded by compiler | High |
| **Missing direct dep** | Imported in source but not declared, only reachable transitively | High (if directly imported) / Low (if indirect) |
| **private_deps candidate** | Loaded by compiler but not explicitly imported in source | Low |

## How it works

`bazel build --config=unused-deps` runs a Bazel [aspect](https://bazel.build/extending/aspects) on every Swift target. For each target, it:

1. **Collects metadata** - reads `SwiftInfo` from rules_swift to get module names, declared deps, and the transitive module map
2. **Captures traces** - copies the Swift compiler's [loaded module trace](https://github.com/swiftlang/swift/blob/main/docs/LoadedModuleTrace.md) (records which `.swiftmodule` files were actually opened)
3. **Reads index store** - uses the Swift index store to determine which imports are directly used in source (more accurate than traces alone)

Everything is cached by Bazel. Re-running after no changes is instant.

`bazel run @swift_unused_deps//:swift_unused_deps` reads the outputs from `bazel-bin/` and prints a human-readable summary. With `--fix`, it runs buildozer to update BUILD files.

### Exit codes

| Code | Meaning |
|------|---------|
| 0 | Clean, no issues found |
| 1 | Issues found (or fix failed) |
| 2 | No metadata found, or warnings occurred |

## Limitations

- Requires `--spawn_strategy=local` (most iOS Bazel projects already use this)
- Pure Swift targets only. Mixed Swift/ObjC targets emit a warning.
- `@_exported import` re-exports are not tracked
- Unused Swift `import` statements keep deps alive (use a linter like SwiftLint's `unused_import` rule first)

## Example

The `example/` directory contains real `swift_library` targets demonstrating each case:

```sh
bazel run //:swift_unused_deps -- //example/...
```

## License

MIT
