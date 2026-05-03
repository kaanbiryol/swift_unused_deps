# swift_unused_deps Example

This example demonstrates `swift_unused_deps --fix` against a small Swift Bazel
workspace.

The workspace is materialized from
`tools/swift_unused_deps/tests/fixtures/cases_workspace` into a temporary
directory. The script initializes a git repo in that temporary workspace, runs
the CLI, then prints the diff so you can inspect exactly which Swift and Bazel
files changed.

```sh
./examples/swift_unused_deps/run_fix_demo.sh unused-import
./examples/swift_unused_deps/run_fix_demo.sh missing-direct-dep
```

To choose the destination yourself, pass an empty or non-existent directory:

```sh
./examples/swift_unused_deps/run_fix_demo.sh unused-import /tmp/swift-unused-deps-demo
cd /tmp/swift-unused-deps-demo
git diff
```

Run the example smoke test:

```sh
bats examples/swift_unused_deps/test
```
