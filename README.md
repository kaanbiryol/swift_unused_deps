# swift_unused_deps

[![CI](https://github.com/kaanbiryol/swift_unused_deps/actions/workflows/ci.yml/badge.svg)](https://github.com/kaanbiryol/swift_unused_deps/actions/workflows/ci.yml)

Detect unused and missing direct Bazel dependencies for Swift targets.

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

### 2. Enable Swift indexing for analysis builds

```text
build:swift-unused-deps --features=swift.index_while_building
```

### Prerequisites

- Bazel 9+ with [rules_swift](https://github.com/bazelbuild/rules_swift) 3.6+

## Usage

Create a BUILD file for the analysis target, for example `tools/BUILD.bazel`:

```python
load("@swift_unused_deps//tools/swift_unused_deps:defs.bzl", "swift_unused_deps")

swift_unused_deps(
    name = "swift_unused_deps",
    targets = [
        "//apps/Example:ExampleApp",
    ],
)
```

This creates three targets:

| Target | Command | Use |
|--------|---------|-----|
| `:swift_unused_deps` | `bazel test` | Check deps and fail on findings |
| `:swift_unused_deps_report` | `bazel build` | Emit merged report and fix artifacts |
| `:swift_unused_deps_fix` | `bazel run` | Apply the generated fix plan |

Run the check like any other Bazel test:

```sh
bazel test --config=swift-unused-deps //tools:swift_unused_deps
```

For iOS or other configured builds, pass the platform to Bazel:

```sh
bazel test --config=swift-unused-deps \
  --platforms=@apple_support//platforms:ios_sim_arm64 \
  //tools:swift_unused_deps
```

The test prints a merged text report and fails when configured findings are
present.

## Report And Fix Targets

```sh
bazel build --config=swift-unused-deps //tools:swift_unused_deps_report
```

This produces:

- `*.swift_unused_deps.report.json`
- `*.swift_unused_deps.report.txt`
- `*.swift_unused_deps.fix.json`
- `*.swift_unused_deps.exit_code`

Common macro attributes:

| Attribute | Use |
|-----------|-----|
| `targets` | Top-level Bazel targets whose Swift dependency closure should be analyzed |
| `report_confidence` | `low` or `high`; minimum confidence level to report and fail tests on. Defaults to `low` |
| `fix_confidence` | `low` or `high`; minimum confidence level to include in the merged fix plan. Defaults to `high` |

Apply generated fixes with the macro-generated fix target:

```sh
bazel run --config=swift-unused-deps //tools:swift_unused_deps_fix
```

Applying fixes mutates source and BUILD files, so it intentionally stays outside
normal Bazel build/test actions. After applying fixes, rerun the check:

```sh
bazel test --config=swift-unused-deps //tools:swift_unused_deps
```

## Low-Level Output Groups

The aspect also exposes per-target artifacts through output groups for debugging
and custom integrations:

```sh
bazel build --features=swift.index_while_building \
  --aspects=@swift_unused_deps//tools/swift_unused_deps:defs.bzl%swift_unused_deps_aspect \
  --output_groups=swift_unused_deps_reports,swift_unused_deps_fix_high \
  //apps/Example:ExampleApp
```

Available output groups:

- `swift_unused_deps_reports`
- `swift_unused_deps_fix_high`
- `swift_unused_deps_fix_low`
- `swift_unused_deps_metadata`

## Debug CLI

The Swift executable is used by Bazel actions. `analyze --metadata-root` remains
available only for debugging already-produced metadata:

```sh
bazel run @swift_unused_deps//:swift_unused_deps -- analyze //apps/Example:ExampleApp \
  --metadata-root /path/to/bazel-bin
```

Normal CI and local checks should use the `swift_unused_deps` macro instead.

## What It Detects

| Issue | Description | Confidence |
|-------|-------------|------------|
| **Unused dep** | Declared in BUILD but module never loaded by compiler | High |
| **Unused import** | Imported in Swift source but no symbols from that module are referenced anywhere in the target | High |
| **Missing direct dep** | Imported in source but not declared, only reachable transitively | High if directly imported, low if indirect |
| **private_deps candidate** | Loaded by compiler but not explicitly imported in source | Low |

## How It Works

The `swift_unused_deps` macro creates test, report, and fix targets. Under the
macro, Bazel rules apply an aspect to the requested targets. The aspect reads
`SwiftInfo`, writes per-target metadata, and runs the analyzer as declared Bazel
actions. The aggregation rule consumes the aspect's `SwiftDepsInfo` provider
directly and merges declared report/fix artifacts without invoking Bazel from
inside the analyzer.

## Limitations

- Pure Swift targets only. Mixed Swift/ObjC targets emit a warning.
- `@_exported import` re-exports are treated as non-removable by fix outputs.
- Scoped imports like `import struct LibA.Button` are not analyzed reliably end to end yet.
- Unused Swift `import` statements are fixed only when the analyzer has index store data for per-file source edits.
- Runtime resource usage is not analyzed today. Calls such as `UIImage(named:)`, `Image(_:)`,
  `Color(_:)`, `Font.custom`, `Bundle` resource lookups, and localized string lookups may depend
  on resources from another Bazel target without creating Swift symbol usage. Review resource
  dependencies manually before applying BUILD fixes.

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

bazel test --features=swift.index_while_building //:candidate_private_dep_unused_deps
```

## License

MIT
