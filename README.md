# swift_unused_deps

[![CI](https://github.com/kaanbiryol/swift_unused_deps/actions/workflows/ci.yml/badge.svg)](https://github.com/kaanbiryol/swift_unused_deps/actions/workflows/ci.yml)

Detect unused and missing direct Bazel dependencies for Swift targets.

Compares declared `deps` in BUILD files against what the Swift compiler actually loaded during compilation. Finds deps you can safely remove and deps you should add.

## Quick start

```sh
# Analyze and print results (builds automatically)
bazel run @swift_unused_deps//:swift_unused_deps -- //App/...

# Auto-fix high-confidence issues
bazel run @swift_unused_deps//:swift_unused_deps -- //App/... --fix

# Analyze iOS-only targets with a dedicated Bazel config
bazel run @swift_unused_deps//:swift_unused_deps -- --build-config unused-deps-ios //App:App
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

In your `MODULE.bazel`, pin the GitHub release tag:

```python
bazel_dep(name = "swift_unused_deps", version = "0.1.0")

git_override(
    module_name = "swift_unused_deps",
    remote = "https://github.com/kaanbiryol/swift_unused_deps.git",
    tag = "v0.1.0",
)
```

After the module is published to the Bazel Central Registry, the `git_override`
can be removed.

### 2. Configure your `.bazelrc`

```
build:unused-deps --features=swift.index_while_building
build:unused-deps --features=swift.use_global_index_store
build:unused-deps --aspects=@swift_unused_deps//tools/swift_unused_deps/aspect:deps_info.bzl%swift_deps_aspect
build:unused-deps --output_groups=swift_deps_info,swift_index_store
build:unused-deps --spawn_strategy=local
```

For iOS projects that require a platform setting:

```
build:unused-deps-ios --config=unused-deps
build:unused-deps-ios --platforms=@apple_support//platforms:ios_sim_arm64
```

### Prerequisites

- Bazel 9+ with [rules_swift](https://github.com/bazelbuild/rules_swift) 3.6+
- This repo is pinned to Bazel 9.0.2 via `.bazelversion` for reproducible local runs

## Usage

### Basic analysis

```sh
# Analyze all targets under a path
bazel run @swift_unused_deps//:swift_unused_deps -- //libraries/...

# Analyze a specific target
bazel run @swift_unused_deps//:swift_unused_deps -- //App:App
```

Each run automatically executes `bazel build <pattern> --config=<build-config>` first, then analyzes the produced metadata and traces. Bazel's normal cache handles incremental rebuilds.

The default build config is `unused-deps`. For iOS-only targets or any workspace that uses a different analysis config name, pass `--build-config <name>`.

### Auto-fix

Use `--fix` to automatically apply high-confidence fixes using [buildozer](https://github.com/bazelbuild/buildtools/tree/master/buildozer):

```sh
bazel run @swift_unused_deps//:swift_unused_deps -- //libraries/... --fix
```

This runs buildozer commands to:
- Remove unused deps (`remove deps`)
- Add missing direct deps (`add deps`)

After applying fixes, the tool rebuilds and re-runs analysis so the printed report reflects the post-fix state.

Only high-confidence issues are fixed. Low-confidence issues (like unresolved modules) are reported for manual investigation.

If a module is imported in Swift source but no symbols from it are referenced anywhere in the target, `--fix` removes both the unused `import` statement(s) and the Bazel dep.

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

### Custom build config

Use a different Bazel config for the automatic build step when needed, for example iOS-only targets:

```sh
bazel run @swift_unused_deps//:swift_unused_deps -- --build-config unused-deps-ios //App/...
```

### All options

| Option | Description |
|--------|-------------|
| `PATTERN` | Bazel target pattern to analyze (e.g. `//libraries/...`) |
| `--fix` | Run buildozer to fix high-confidence issues |
| `--json` | Output JSON instead of text |
| `--min-confidence` | Minimum confidence level: `low`, `medium`, `high` (default: `low`) |
| `--extra-system-modules` | Comma-separated module names to treat as system modules |
| `--index-store-path` | Override path to Swift index store (default: Bazel-managed `bazel-out/_global_index_store`) |
| `--build-config` | Bazel config for the automatic build step (default: `unused-deps`) |

## What it detects

| Issue | Description | Confidence |
|-------|-------------|------------|
| **Unused dep** | Declared in BUILD but module never loaded by compiler | High |
| **Unused import** | Imported in Swift source but no symbols from that module are referenced anywhere in the target | High |
| **Missing direct dep** | Imported in source but not declared, only reachable transitively | High (if directly imported) / Low (if indirect) |
| **private_deps candidate** | Loaded by compiler but not explicitly imported in source | Low |

## How it works

`bazel build --config=unused-deps` runs a Bazel [aspect](https://bazel.build/extending/aspects) on every Swift target. For each target, it:

1. **Collects metadata** - reads `SwiftInfo` from rules_swift to get module names, declared deps, and the transitive module map
2. **Captures traces** - copies the Swift compiler's [loaded module trace](https://github.com/swiftlang/swift/blob/main/docs/LoadedModuleTrace.md) (records which `.swiftmodule` files were actually opened)
3. **Reads index store** - uses the `rules_swift` global index store produced by `swift.index_while_building` + `swift.use_global_index_store` to determine which imports are directly used in source (more accurate than traces alone).

Everything is cached by Bazel. Re-running after no changes is instant.

`bazel run @swift_unused_deps//:swift_unused_deps -- <pattern>` first builds the requested targets with `--config=<build-config>`, then reads the metadata outputs reported by that Bazel build and prints a human-readable summary. With `--fix`, it runs buildozer, rebuilds, and prints the post-fix results.

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
- Scoped imports like `import struct LibA.Button` are not analyzed reliably end to end yet
- Unused Swift `import` statements are fixed only in batch mode, where the tool has index store data for per-file source edits

## Example

The `example/` directory contains real `swift_library` targets demonstrating each case:

```sh
bazel run //:swift_unused_deps -- //example/...
```

## License

MIT
