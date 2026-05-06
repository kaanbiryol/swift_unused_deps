# swift_unused_deps

[![CI](https://github.com/kaanbiryol/swift_unused_deps/actions/workflows/ci.yml/badge.svg)](https://github.com/kaanbiryol/swift_unused_deps/actions/workflows/ci.yml)

Detect unused and missing direct Bazel dependencies for Swift targets.

Compares declared `deps` in BUILD files against what the Swift compiler actually loaded during compilation. Finds deps you can safely remove and deps you should add.

## Quick start

After setup:

```sh
bazel build --config=swift-unused-deps //App/...

bazel run @swift_unused_deps//:swift_unused_deps -- analyze //App/...

bazel run @swift_unused_deps//:swift_unused_deps -- analyze //App/... \
  --fix-output /tmp/swift-unused-deps.fix.json
bazel run @swift_unused_deps//:swift_unused_deps_apply -- \
  /tmp/swift-unused-deps.fix.json
```

## Setup

### 1. Add the dependency

```python
bazel_dep(name = "swift_unused_deps", version = "0.1.0")

git_override(
    module_name = "swift_unused_deps",
    remote = "https://github.com/kaanbiryol/swift_unused_deps.git",
    commit = "<commit-sha>",
)
```

### 2. Configure your `.bazelrc`

```
build:swift-unused-deps --features=swift.index_while_building
build:swift-unused-deps --aspects=@swift_unused_deps//tools/swift_unused_deps:defs.bzl%swift_unused_deps_aspect
build:swift-unused-deps --output_groups=swift_unused_deps_metadata

build:swift-unused-deps-ios --config=swift-unused-deps
build:swift-unused-deps-ios --platforms=@apple_support//platforms:ios_sim_arm64
```

Use the iOS config only if your Swift targets require that platform.

### Prerequisites

- Bazel 9+ with [rules_swift](https://github.com/bazelbuild/rules_swift) 3.6+

## Usage

### Analyze

```sh
TARGETS=//libraries/...

bazel build --config=swift-unused-deps "${TARGETS}"

bazel run @swift_unused_deps//:swift_unused_deps -- analyze "${TARGETS}"
```

`analyze` never invokes `bazel build`; it reads existing metadata and
index-store artifacts. By default it uses `bazel info bazel-bin` to locate those
artifacts. Bazel owns the aspect build, and the Swift analyzer owns Swift
index-store interpretation.

For iOS-only targets, use `--config=swift-unused-deps-ios` on the Bazel build.

### Apply Fixes

The preferred fix flow is explicit: write structured fixes, inspect them if needed, then apply them.

```sh
TARGETS=//libraries/...
FIX_OUTPUT=/tmp/swift-unused-deps.fix.json

bazel build --config=swift-unused-deps "${TARGETS}"

bazel run @swift_unused_deps//:swift_unused_deps -- analyze "${TARGETS}" \
  --fix-output "${FIX_OUTPUT}"

bazel run @swift_unused_deps//:swift_unused_deps_apply -- \
  "${FIX_OUTPUT}"
```

Fix outputs contain source import removals and structured BUILD edits. The apply command uses [buildozer](https://github.com/bazelbuild/buildtools/tree/master/buildozer) for BUILD edits and applies Swift import removals directly.

Fixes include:
- Remove unused deps (`remove deps`)
- Add missing direct deps (`add deps`)

After applying fixes, rerun the `bazel build` and `analyze` commands to verify
the final report.

Only high-confidence issues are fixed by default. Pass
`--min-fix-confidence low` to include low-confidence fixable suggestions
such as `private_deps` moves. Low-confidence issues without an explicit fix
command, like unresolved modules, are still reported for manual investigation.

If a module is imported in Swift source but no symbols from it are referenced anywhere in the target, the fix output removes both the unused `import` statement(s) and the Bazel dep.

### Common options

| Option | Use |
|--------|-----|
| `TARGET_PATTERN` | Limit analysis to matching Bazel targets |
| `--fix-output <path>` | Write fixes as structured JSON |
| `--json` | Print JSON instead of text |
| `--min-report-confidence low|medium|high` | Hide lower-confidence issues and ignore them for the analyze exit code |
| `--min-fix-confidence low|medium|high` | Include lower-confidence fixes in `--fix-output` |

Advanced options such as `--metadata-root`, `--index-store-path`,
`--workspace-directory`, `--extra-system-modules`, `--report-output`, and
`--exit-code-output` are still available for tests, debugging, and custom
automation.

Run `bazel run @swift_unused_deps//:swift_unused_deps -- analyze --help` for the full CLI reference.

## What it detects

| Issue | Description | Confidence |
|-------|-------------|------------|
| **Unused dep** | Declared in BUILD but module never loaded by compiler | High |
| **Unused import** | Imported in Swift source but no symbols from that module are referenced anywhere in the target | High |
| **Missing direct dep** | Imported in source but not declared, only reachable transitively | High (if directly imported) / Low (if indirect) |
| **private_deps candidate** | Loaded by compiler but not explicitly imported in source | Low |

## How it works

`bazel build --config=swift-unused-deps` runs a Bazel [aspect](https://bazel.build/extending/aspects) on Swift targets. The aspect reads `SwiftInfo` from rules_swift, emits per-target dependency metadata, and records the per-target index-store location produced by `swift.index_while_building`.

`analyze` reads those Bazel outputs and interprets the Swift index store. It does not invoke Bazel. Fixing is represented as a structured plan first; `swift_unused_deps_apply` is the explicit workspace-mutating step.

## Exit codes

| Code | Meaning |
|------|---------|
| 0 | Clean, no issues found |
| 1 | Issues found (or fix failed) |
| 2 | No metadata found, or warnings occurred |

## Limitations

- Per-target index-store analysis depends on `rules_swift` emitting readable index-store directories
- Pure Swift targets only. Mixed Swift/ObjC targets emit a warning.
- `@_exported import` re-exports are treated as non-removable by fix outputs
- Scoped imports like `import struct LibA.Button` are not analyzed reliably end to end yet
- Unused Swift `import` statements are fixed only when the analyzer has index store data for per-file source edits

## License

MIT
