# Examples

Runnable examples live here. They are intentionally thin wrappers around the
same fixture workspaces used by acceptance tests, so examples and tests do not
drift apart.

Each example materializes a temporary Bazel workspace outside this checkout,
runs the public CLI, and leaves changed files behind for inspection.

```sh
./examples/swift_unused_deps/run_fix_demo.sh unused-import
./examples/swift_unused_deps/run_fix_demo.sh missing-direct-dep
```

Run example smoke tests with Bats:

```sh
bats examples/swift_unused_deps/test
```
