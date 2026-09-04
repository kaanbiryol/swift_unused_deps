#!/usr/bin/env bats

load "test_helper.bash"

setup() {
  make_fixture_workspace "consumer_workspace"
}

teardown() {
  cleanup_fixture_workspace
}

@test "external consumer workspace runs clean through local path override" {
  run_swift_unused_deps_in_workspace //App:App --json

  assert_status 0
  assert_output_contains '"status" : "clean"'
  assert_output_contains '"target" : "\/\/App:App"'
}

@test "external consumer workspace can run the standalone fix-plan applier" {
  run_in_workspace bazel run \
    @swift_unused_deps//tools/swift_unused_deps:apply -- \
    --help

  assert_status 0
  assert_combined_output_contains "Apply swift_unused_deps fixes to the workspace."
}
