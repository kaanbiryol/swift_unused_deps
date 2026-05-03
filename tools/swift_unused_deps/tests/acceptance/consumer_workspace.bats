#!/usr/bin/env bats

load "test_helper.bash"

setup() {
  make_fixture_workspace "consumer_workspace"
}

teardown() {
  cleanup_fixture_workspace
}

@test "external consumer workspace runs clean through local path override" {
  run_in_workspace bazel run @swift_unused_deps//:swift_unused_deps -- //App:App --json

  assert_status 0
  assert_output_contains '"status" : "clean"'
  assert_output_contains '"target" : "\/\/App:App"'
}
