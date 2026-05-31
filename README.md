# swift_unused_deps

[![CI](https://github.com/kaanbiryol/swift_unused_deps/actions/workflows/ci.yml/badge.svg)](https://github.com/kaanbiryol/swift_unused_deps/actions/workflows/ci.yml)

Detect unused and missing direct Bazel dependencies for Swift targets.

## Requirements

- Bazel 9+ with [rules_swift](https://github.com/bazelbuild/rules_swift) 3.6+

## Setup

### Dependency

Add the `bazel_dep` declaration and a root-module `git_override` pinned to the
GitHub release tag in your `MODULE.bazel`:

```starlark
bazel_dep(name = "swift_unused_deps", version = "0.1.0")

git_override(
    module_name = "swift_unused_deps",
    remote = "https://github.com/kaanbiryol/swift_unused_deps.git",
    tag = "v0.1.0",
)
```

### Bazel Config

Add a named config to your workspace `.bazelrc`:

```text
build:swift-unused-deps --features=swift.index_while_building
test:swift-unused-deps --test_output=errors
```

The `build:` line is enough for `bazel test` and `bazel run` too, because those
commands build their prerequisites and inherit build options from the selected
config. The `test:` line makes Bazel print the generated report inline when the
check fails.

> Unused Swift `import` edits require index store data, which is why the config
> enables `swift.index_while_building`.

## App And Library Targets

Create a BUILD file for the analysis target, for example `tools/BUILD.bazel`.
Point `targets` at the app, library, or package-level targets whose Swift
dependency closure should be checked.

```starlark
load("@swift_unused_deps//tools/swift_unused_deps:defs.bzl", "swift_unused_deps")

swift_unused_deps(
    name = "swift_unused_deps",
    targets = [
        "//apps/Example:ExampleApp",
    ],
)
```

Run the check like any other Bazel test. No separate `bazel build` step is
required; Bazel builds the analyzed targets, the analysis artifacts, and the
test wrapper before running the check.

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

Apply generated fixes with the macro-generated fix target:

```sh
bazel run --config=swift-unused-deps //tools:swift_unused_deps_fix
```

`bazel run` builds the fix plan first, then invokes the applier. Applying fixes
mutates source and BUILD files, so it intentionally stays outside normal
Bazel build/test actions. After applying fixes, rerun the check.

## Test Targets

For test code, prefer the same shape commonly used by iOS test bundles: put
Swift test sources in a `testonly` `swift_library`, then make the runnable test
target depend on that library. Point `swift_unused_deps` at the test library.

```starlark
swift_library(
    name = "FeatureTestsLib",
    testonly = True,
    srcs = ["FeatureTests.swift"],
    deps = [
        ":Feature",
        "//tests/support:SnapshotHelpers",
    ],
)

ios_unit_test(
    name = "FeatureTests",
    deps = [":FeatureTestsLib"],
)

swift_unused_deps(
    name = "feature_tests_unused_deps",
    testonly = True,
    targets = [":FeatureTestsLib"],
)
```

For larger projects, put the runnable test targets in a `test_suite` and point a
single `swift_unused_deps` target at the suite. The aspect traverses the suite's
`tests`, then the normal dependency attributes under those tests.

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

This works best when each runnable Apple test target depends on a test-only
`swift_library` that owns the test sources.

## Generated Targets

Given `name = "swift_unused_deps"`, the macro creates:

| Target | Command | Use |
|--------|---------|-----|
| `:swift_unused_deps` | `bazel test` | Check deps and fail on findings |
| `:swift_unused_deps_fix` | `bazel run` | Apply the generated fix plan |
| `:swift_unused_deps_report` | `bazel build` | Optional: emit report and fix artifacts without running the check or applying fixes |

The report target is for artifact-only workflows, such as CI uploads or
machine-readable JSON. It is not required before `bazel test` or `bazel run`.

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

## Macro Attributes

Pass these directly to the `swift_unused_deps(...)` macro in your BUILD file:

```starlark
swift_unused_deps(
    name = "swift_unused_deps",
    targets = ["//apps/Example:ExampleApp"],
    report_confidence = "high",
    fix_confidence = "high",
)
```

| Attribute | Use |
|-----------|-----|
| `targets` | Top-level Bazel targets whose Swift dependency closure should be analyzed |
| `report_confidence` | `low` or `high`; minimum confidence level to report and fail tests on. Defaults to `low` |
| `fix_confidence` | `low` or `high`; minimum confidence level to include in the merged fix plan. Defaults to `high` |
| `testonly` | Set to `True` when `targets` includes test-only labels |

## What It Detects

| Issue | Description | Confidence |
|-------|-------------|------------|
| **Unused dep** | Declared in BUILD but module never loaded by compiler | High |
| **Unused import** | Imported in Swift source but no symbols from that module are referenced anywhere in the target | High |
| **Missing direct dep** | Imported in source but not declared, only reachable transitively | High if directly imported, low if indirect |
| **private_deps candidate** | Loaded by compiler but not explicitly imported in source | Low |

## Limitations

- Pure Swift targets only. Mixed Swift/ObjC targets emit a warning.
- Runnable test rules and `test_suite` targets are traversal roots. To analyze
  test source files directly, put them in a `testonly` `swift_library`.
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
