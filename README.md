# swift_unused_deps

[![CI](https://github.com/kaanbiryol/swift_unused_deps/actions/workflows/ci.yml/badge.svg)](https://github.com/kaanbiryol/swift_unused_deps/actions/workflows/ci.yml)

Detect unused and missing direct Bazel dependencies for Swift targets.

Compares declared `deps` in BUILD files against what the Swift compiler actually loaded during compilation. Finds deps you can safely remove and deps you should add.

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

### Prerequisites

- Bazel 9+ with [rules_swift](https://github.com/bazelbuild/rules_swift) 3.6+

## Usage

```sh
TARGETS=//libraries/...
bazel build --config=swift-unused-deps "${TARGETS}"
bazel run @swift_unused_deps//:swift_unused_deps -- analyze "${TARGETS}"
```

> For iOS targets, use `--config=swift-unused-deps-ios` on the Bazel build.

### Commands

| Task | Command |
|------|---------|
| Report findings | `bazel run @swift_unused_deps//:swift_unused_deps -- analyze "${TARGETS}"` |
| Output findings as JSON | `bazel run @swift_unused_deps//:swift_unused_deps -- analyze "${TARGETS}" --report-output report.json` |
| Output fix plan | `bazel run @swift_unused_deps//:swift_unused_deps -- analyze "${TARGETS}" --fix-output fix.json` |
| Apply a fix plan | `bazel run @swift_unused_deps//:swift_unused_deps_apply -- fix.json` |
| Auto-apply fixes | `bazel run @swift_unused_deps//:swift_unused_deps -- fix "${TARGETS}"` |

Fix plans contain source import removals and structured BUILD edits. Applying
fixes uses [buildozer](https://github.com/bazelbuild/buildtools/tree/master/buildozer)
for BUILD edits and applies Swift import removals directly.

### Options

| Option | Use |
|--------|-----|
| `TARGET_PATTERN` | Limit analysis to matching Bazel targets |
| `--report-output <path>` | Write the analysis report as JSON while still printing text |
| `--fix-output <path>` | Write fixes as structured JSON |
| `--include-low-confidence-fixes` | Include low-confidence fixes, such as `private_deps` moves |

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

`analyze` reads those Bazel outputs and interprets the Swift index store. Fixing can be represented as structured JSON first and applied with `swift_unused_deps_apply`, or applied directly with `swift_unused_deps fix`.

## Limitations

- Pure Swift targets only. Mixed Swift/ObjC targets emit a warning.
- `@_exported import` re-exports are treated as non-removable by fix outputs
- Scoped imports like `import struct LibA.Button` are not analyzed reliably end to end yet
- Unused Swift `import` statements are fixed only when the analyzer has index store data for per-file source edits

## Development

Run the unit tests:

```sh
bazel test //tools/swift_unused_deps/tests:swift_unused_deps_tests
```

Try the fixture workspace:

```sh
FIXTURE_WORKSPACE=/tmp/swift-unused-deps-fixture
rm -rf "${FIXTURE_WORKSPACE}"

tools/swift_unused_deps/tests/helpers/materialize_fixture_workspace.sh \
  cases_workspace \
  "${FIXTURE_WORKSPACE}" \
  "$PWD"

cd "${FIXTURE_WORKSPACE}"

TARGETS=//cases/Targets/UnusedImport:UnusedImport
bazel build --config=swift-unused-deps "${TARGETS}"
bazel run @swift_unused_deps//:swift_unused_deps -- analyze "${TARGETS}"
```

## License

MIT
