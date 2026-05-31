# swift_unused_deps

[![CI](https://github.com/kaanbiryol/swift_unused_deps/actions/workflows/ci.yml/badge.svg)](https://github.com/kaanbiryol/swift_unused_deps/actions/workflows/ci.yml)

Detect unused and missing direct Bazel dependencies for Swift targets.

## Quick Start

### Prerequisites

- Bazel 9+ with [rules_swift](https://github.com/bazelbuild/rules_swift) 3.6+

### 1. Add the dependency with a Git override

Add the `bazel_dep` declaration and a root-module `git_override` that tells Bazel where
to fetch the module to your `MODULE.bazel`:

```starlark
bazel_dep(name = "swift_unused_deps", version = "0.1.0")

git_override(
    module_name = "swift_unused_deps",
    remote = "https://github.com/kaanbiryol/swift_unused_deps.git",
    commit = "<commit-sha>",
)
```

### 2. Enable Swift indexing and failure output

```text
build:swift-unused-deps --features=swift.index_while_building
test:swift-unused-deps --test_output=errors
```

> Unused Swift `import` edits require index store data.

### 3. Add an analysis target

Create a BUILD file for the analysis target, for example `tools/BUILD.bazel`.
Point `targets` at the app, test, or package-level targets whose Swift
dependency closure should be checked:

```starlark
load("@swift_unused_deps//tools/swift_unused_deps:defs.bzl", "swift_unused_deps")

swift_unused_deps(
    name = "swift_unused_deps",
    targets = [
        "//apps/Example:ExampleApp",
    ],
)
```

The macro creates three targets:

| Target | Command | Use |
|--------|---------|-----|
| `:swift_unused_deps` | `bazel test` | Check deps and fail on findings |
| `:swift_unused_deps_fix` | `bazel run` | Apply the generated fix plan |
| `:swift_unused_deps_report` | `bazel build` | Optional: emit report and fix artifacts without running the check or applying fixes |

### 4. Run the check

Run the check like any other Bazel test:

```sh
bazel test --config=swift-unused-deps //tools:swift_unused_deps
```

> No separate `bazel build` step is required before this. The test target builds
> and merges the analysis artifacts as part of `bazel test`.

For iOS or other configured builds, pass the platform to Bazel:

```sh
bazel test --config=swift-unused-deps \
  --platforms=@apple_support//platforms:ios_sim_arm64 \
  //tools:swift_unused_deps
```

The test prints a merged text report and fails when configured findings are
present.

If you are not using the `swift-unused-deps` config, pass `--test_output=errors`
to show the report inline when findings fail the test:

```sh
bazel test --test_output=errors --features=swift.index_while_building //tools:swift_unused_deps
```

## Test Target Examples

When an analysis target points at a `swift_test`, mark the generated targets as
`testonly` so Bazel allows them to depend on test-only labels:

```starlark
swift_test(
    name = "FeatureTests",
    srcs = ["FeatureTests.swift"],
    deps = [":Feature"],
)

swift_unused_deps(
    name = "feature_tests_unused_deps",
    testonly = True,
    targets = [":FeatureTests"],
)
```

Today this checks the Swift dependency closure below `FeatureTests`. It does not
analyze `FeatureTests.swift` itself unless the test rule exposes a direct Swift
module through `SwiftInfo`.

To analyze test-only Swift code directly today, put that code in a `testonly`
Swift library and point `swift_unused_deps` at the library:

```starlark
swift_library(
    name = "FeatureTestSupport",
    testonly = True,
    srcs = ["FeatureTestSupport.swift"],
    deps = [
        ":Feature",
        "//tests/support:SnapshotHelpers",
    ],
)

swift_test(
    name = "FeatureTests",
    srcs = ["FeatureTests.swift"],
    deps = [":FeatureTestSupport"],
)

swift_unused_deps(
    name = "feature_test_support_unused_deps",
    testonly = True,
    targets = [":FeatureTestSupport"],
)
```

For larger projects, put the runnable test targets in a `test_suite` and point
one `swift_unused_deps` target at the suite:

```starlark
test_suite(
    name = "all_ios_unit_tests",
    tests = [
        "//Features/Login/Tests:LoginTests",
        "//Features/Profile/Tests:ProfileTests",
        "//Features/Search/Tests:SearchTests",
    ],
)

swift_unused_deps(
    name = "ios_tests_unused_deps",
    testonly = True,
    targets = [":all_ios_unit_tests"],
)
```

The aspect traverses the suite's `tests`, then the normal dependency attributes
under those tests. This works best when each runnable Apple test target depends
on a test-only `swift_library` that owns the test sources.

## Configuration

Common macro attributes:

| Attribute | Use |
|-----------|-----|
| `targets` | Top-level Bazel targets whose Swift dependency closure should be analyzed |
| `report_confidence` | `low` or `high`; minimum confidence level to report and fail tests on. Defaults to `low` |
| `fix_confidence` | `low` or `high`; minimum confidence level to include in the merged fix plan. Defaults to `high` |
| `testonly` | Set to `True` when analyzing `swift_test` or other test-only targets |

## Fixes And Optional Artifacts

After reviewing the report from `bazel test`, apply generated fixes with the
macro-generated fix target:

```sh
bazel run --config=swift-unused-deps //tools:swift_unused_deps_fix
```

No separate `bazel build` step is required before this. `bazel run` builds the
fix target and its generated fix plan before invoking the applier.

Applying fixes mutates source and BUILD files, so it intentionally stays outside
normal Bazel build/test actions. After applying fixes, rerun the check:

```sh
bazel test --config=swift-unused-deps //tools:swift_unused_deps
```

The report target is optional. Build it when you want standalone JSON/text/fix
artifacts without running the check wrapper or applying fixes:

```sh
bazel build --config=swift-unused-deps //tools:swift_unused_deps_report
```

This produces:

- `*.swift_unused_deps.report.json`
- `*.swift_unused_deps.report.txt`
- `*.swift_unused_deps.fix.json`
- `*.swift_unused_deps.exit_code`

For the example target above, inspect the text report with:

```sh
cat bazel-bin/tools/swift_unused_deps_report.swift_unused_deps.report.txt
```

## What It Detects

| Issue | Description | Confidence |
|-------|-------------|------------|
| **Unused dep** | Declared in BUILD but module never loaded by compiler | High |
| **Unused import** | Imported in Swift source but no symbols from that module are referenced anywhere in the target | High |
| **Missing direct dep** | Imported in source but not declared, only reachable transitively | High if directly imported, low if indirect |
| **private_deps candidate** | Loaded by compiler but not explicitly imported in source | Low |

## Limitations

- Pure Swift targets only. Mixed Swift/ObjC targets emit a warning.
- `swift_test` and `test_suite` targets are accepted as top-level roots for
  dependency-closure traversal, but their own test source files are not analyzed
  unless the Swift sources live in a target that exposes a direct Swift module
  through `SwiftInfo`, such as a `testonly` `swift_library`.
- `@_exported import` re-exports are treated as non-removable by fix outputs.
- Scoped imports like `import struct LibA.Button` are not analyzed reliably end to end yet.
- Unused Swift `import` statements are fixed only when the analyzer has index store data for per-file source edits.
- Runtime resource usage is not analyzed today. Calls such as `UIImage(named:)`, `Image(_:)`,
  `Color(_:)`, `Font.custom`, `Bundle` resource lookups, and localized string lookups may depend
  on resources from another Bazel target without creating Swift symbol usage. Review resource
  dependencies manually before applying BUILD fixes.

## Advanced Usage

Normal CI and local checks should use the `swift_unused_deps` macro. The lower
level output groups below are useful for debugging generated artifacts or
building custom integrations.

The aspect exposes per-target artifacts through output groups:

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

## Internals

The `swift_unused_deps` macro creates test, report, and fix targets. Under the
macro, Bazel rules apply an aspect to the requested targets. The aspect reads
`SwiftInfo`, writes per-target metadata, and runs the analyzer as declared Bazel
actions. The aggregation rule consumes the aspect's `SwiftDepsInfo` provider
directly and merges declared report/fix artifacts without invoking Bazel from
inside the analyzer.

## Development

Run the unit tests:

```sh
bazel test //tools/swift_unused_deps/tests:swift_unused_deps_tests
```

Run the full local test suite:

```sh
bazel test //...
```

Check Bazel formatting:

```sh
buildifier -mode=check $(git ls-files '*.bazel' '*.bzl' '*.fixture')
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

bazel test --config=swift-unused-deps //:candidate_private_dep_unused_deps
```

Run the acceptance tests:

```sh
bats tools/swift_unused_deps/tests/acceptance
```

## License

MIT
