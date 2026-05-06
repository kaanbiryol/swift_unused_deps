#!/usr/bin/env bats

load "test_helper.bash"

setup() {
  make_fixture_workspace "consumer_workspace"
}

teardown() {
  cleanup_fixture_workspace
}

@test "external consumer workspace runs clean through local path override" {
  run_in_workspace bash -c '
    bazel build \
      --features=swift.index_while_building \
      --aspects=@swift_unused_deps//tools/swift_unused_deps:defs.bzl%swift_unused_deps_aspect \
      --output_groups=swift_unused_deps_metadata \
      //App:App >/dev/null

    bazel run @swift_unused_deps//:swift_unused_deps -- analyze //App:App \
      --json
  '

  assert_status 0
  assert_output_contains '"status" : "clean"'
  assert_output_contains '"target" : "\/\/App:App"'
}
