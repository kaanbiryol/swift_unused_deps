# swift_unused_deps

[![CI](https://github.com/kaanbiryol/swift_unused_deps/actions/workflows/ci.yml/badge.svg)](https://github.com/kaanbiryol/swift_unused_deps/actions/workflows/ci.yml)

Detect unused and missing direct Bazel dependencies for Swift targets.

Compares declared `deps` in BUILD files against what the Swift compiler actually loaded during compilation. Finds deps you can safely remove and deps you should add.

## Quick start

```sh
# Build with the swift_unused_deps aspect enabled
bazel build --config=swift-unused-deps //App/...

# Analyze the produced artifacts
bazel run //:swift_unused_deps -- analyze \
  --metadata-root "$(bazel info bazel-bin)" \
  --index-store-path "$(bazel info output_path)/_global_index_store" \
  --filter //App/...

# Produce an explicit fix plan, then apply it
bazel run //:swift_unused_deps -- analyze \
  --metadata-root "$(bazel info bazel-bin)" \
  --index-store-path "$(bazel info output_path)/_global_index_store" \
  --filter //App/... \
  --fix-plan-output /tmp/swift-unused-deps.fix_plan.json
bazel run //:swift_unused_deps_apply -- \
  /tmp/swift-unused-deps.fix_plan.json

# Analyze iOS-only targets
bazel build --config=swift-unused-deps-ios //App/...
```

```
//Features/Checkout:Checkout
  Status: 1 issue found

  [HIGH] UNUSED_DEP: //Core/Analytics:Analytics (module: Analytics)
         Module 'Analytics' is declared as a dep but was not loaded during compilation
         Fix: buildozer 'remove deps //Core/Analytics:Analytics' //Features/Checkout:Checkout

Summary: 10 targets analyzed, 1 issue found.
  1 high.

Run with --fix-plan-output to produce an explicit fix plan.
```

## Setup

Configure a Bazel build config that enables rules_swift index-store output,
attaches the aspect, and requests the metadata output group:

```
build:swift-unused-deps --features=swift.index_while_building
build:swift-unused-deps --features=swift.use_global_index_store
build:swift-unused-deps --aspects=//tools/swift_unused_deps:defs.bzl%swift_unused_deps_aspect
build:swift-unused-deps --output_groups=swift_unused_deps_metadata,swift_index_store
build:swift-unused-deps --spawn_strategy=local

build:swift-unused-deps-ios --config=swift-unused-deps
build:swift-unused-deps-ios --platforms=@apple_support//platforms:ios_sim_arm64
```

Use the iOS config only if your Swift targets require that platform.

### Prerequisites

- Bazel 9+ with [rules_swift](https://github.com/bazelbuild/rules_swift) 3.6+
- This repo is pinned to Bazel 9.0.2 via `.bazelversion` for reproducible local runs

## Usage

### Basic analysis

```sh
TARGETS=//libraries/...
CONFIG=swift-unused-deps

bazel build --config="${CONFIG}" "${TARGETS}"

bazel run //:swift_unused_deps -- analyze \
  --metadata-root "$(bazel info bazel-bin)" \
  --index-store-path "$(bazel info output_path)/_global_index_store" \
  --filter "${TARGETS}"
```

`analyze` never invokes `bazel build`; it only reads existing metadata and
index-store artifacts. Bazel owns the aspect build, and the Swift analyzer owns
Swift index-store interpretation.

For iOS-only targets, use `CONFIG=swift-unused-deps-ios`.

### Fix plans

The preferred fix flow is explicit: write a structured fix plan, inspect it if needed, then apply it.

```sh
TARGETS=//libraries/...
CONFIG=swift-unused-deps
FIX_PLAN=/tmp/swift-unused-deps.fix_plan.json

bazel build --config="${CONFIG}" "${TARGETS}"

bazel run //:swift_unused_deps -- analyze \
  --metadata-root "$(bazel info bazel-bin)" \
  --index-store-path "$(bazel info output_path)/_global_index_store" \
  --filter "${TARGETS}" \
  --fix-plan-output "${FIX_PLAN}"

bazel run //:swift_unused_deps_apply -- \
  "${FIX_PLAN}"
```

Fix plans contain source import removals and structured BUILD edits. The apply command uses [buildozer](https://github.com/bazelbuild/buildtools/tree/master/buildozer) for BUILD edits and applies Swift import removals directly.

Fixes include:
- Remove unused deps (`remove deps`)
- Add missing direct deps (`add deps`)

After applying fixes, rerun the `bazel build` and `analyze` commands to verify
the final report.

Only high-confidence issues are fixed. Low-confidence issues (like unresolved modules) are reported for manual investigation.

If a module is imported in Swift source but no symbols from it are referenced anywhere in the target, the fix plan removes both the unused `import` statement(s) and the Bazel dep.

### JSON output

```sh
bazel run //:swift_unused_deps -- analyze \
  --metadata-root "$(bazel info bazel-bin)" \
  --index-store-path "$(bazel info output_path)/_global_index_store" \
  --filter //libraries/... \
  --json
```

### Filtering by confidence

```sh
# Only show high-confidence issues
bazel run //:swift_unused_deps -- analyze \
  --metadata-root "$(bazel info bazel-bin)" \
  --index-store-path "$(bazel info output_path)/_global_index_store" \
  --filter //libraries/... \
  --min-confidence high
```

Values: `low` (default), `medium`, `high`.

### Extra system modules

The tool uses compiler/index-store metadata to skip system modules. If a custom
toolchain or SDK module is not reported as system, add it explicitly:

```sh
bazel run //:swift_unused_deps -- analyze \
  --metadata-root "$(bazel info bazel-bin)" \
  --index-store-path "$(bazel info output_path)/_global_index_store" \
  --filter //App/... \
  --extra-system-modules MySystemModule,AnotherModule
```

### Custom build config

Use a different Bazel config for the aspect build when your workspace needs one:

```sh
CONFIG=swift-unused-deps-ios
TARGETS=//App/...

bazel build --config="${CONFIG}" "${TARGETS}"

bazel run //:swift_unused_deps -- analyze \
  --metadata-root "$(bazel info bazel-bin)" \
  --index-store-path "$(bazel info output_path)/_global_index_store" \
  --filter "${TARGETS}"
```

### All options

| Option | Description |
|--------|-------------|
| `analyze` | Analyze already-produced metadata and index-store artifacts without invoking Bazel |
| `apply FIX_PLAN` | Apply one or more structured fix-plan JSON files |
| `--fix-plan-output` | Write high-confidence fixes as structured JSON |
| `--json` | Output JSON instead of text |
| `--min-confidence` | Minimum confidence level: `low`, `medium`, `high` (default: `low`) |
| `--extra-system-modules` | Comma-separated module names to treat as system modules |
| `--metadata-root` | Root containing `.swift_deps_info.json` files |
| `--index-store-path` | Path to the Swift index store |
| `--filter` | Bazel target pattern to filter analysis results |
| `--workspace-directory` | Workspace directory used for source paths and label conversion |

## What it detects

| Issue | Description | Confidence |
|-------|-------------|------------|
| **Unused dep** | Declared in BUILD but module never loaded by compiler | High |
| **Unused import** | Imported in Swift source but no symbols from that module are referenced anywhere in the target | High |
| **Missing direct dep** | Imported in source but not declared, only reachable transitively | High (if directly imported) / Low (if indirect) |
| **private_deps candidate** | Loaded by compiler but not explicitly imported in source | Low |

## How it works

`bazel build --config=swift-unused-deps` runs a Bazel [aspect](https://bazel.build/extending/aspects) on every Swift target. For each target, the aspect:

1. **Emits metadata** - reads `SwiftInfo` from rules_swift to get module names, declared deps, and the transitive module map
2. **Records index-store locations** - points the analyzer at the `rules_swift` global index store produced by `swift.index_while_building` + `swift.use_global_index_store`

Everything is cached by Bazel. Re-running after no changes is instant.

Bazel builds the requested targets with the configured aspect and index-store
features. `analyze` reads those outputs and prints a report. The analyzer
requires index-store data because it distinguishes direct imports from actual
symbol references and drives unused-import source edits. Fixing is represented
as a structured plan first; `swift_unused_deps_apply` is the explicit
workspace-mutating step.

### Exit codes

| Code | Meaning |
|------|---------|
| 0 | Clean, no issues found |
| 1 | Issues found (or fix failed) |
| 2 | No metadata found, or warnings occurred |

## Limitations

- Index-store generation uses `--spawn_strategy=local`; remote execution is not supported for index-store generation
- Pure Swift targets only. Mixed Swift/ObjC targets emit a warning.
- `@_exported import` re-exports are treated as non-removable by fix plans
- Scoped imports like `import struct LibA.Button` are not analyzed reliably end to end yet
- Unused Swift `import` statements are fixed only when the analyzer has index store data for per-file source edits

## Development Fixtures

Analyzer case workspaces live under `tools/swift_unused_deps/tests/fixtures/`.

Run Swift unit tests with Bazel. These cover analyzer internals and do not run
the fixture acceptance tests:

```sh
bazel test //...
```

Run fixture acceptance tests with [Bats](https://github.com/bats-core/bats-core).
These materialize fixture workspaces, run the public CLI, and assert reports or
file edits:

```sh
bats tools/swift_unused_deps/tests/acceptance
```

If Bats is not installed locally:

```sh
brew install bats-core
```

To inspect a fixture manually:

```sh
tools/swift_unused_deps/tests/helpers/materialize_fixture_workspace.sh cases_workspace /tmp/swift-unused-deps-cases
cd /tmp/swift-unused-deps-cases
TARGETS=//cases/Targets/UnusedImport:UnusedImport
CONFIG=swift-unused-deps
bazel build --config="${CONFIG}" "${TARGETS}"
bazel run //:swift_unused_deps -- analyze \
  --metadata-root "$(bazel info bazel-bin)" \
  --index-store-path "$(bazel info output_path)/_global_index_store" \
  --filter "${TARGETS}" \
  --fix-plan-output /tmp/swift-unused-deps.fix_plan.json
bazel run //:swift_unused_deps_apply -- /tmp/swift-unused-deps.fix_plan.json
```

## License

MIT
