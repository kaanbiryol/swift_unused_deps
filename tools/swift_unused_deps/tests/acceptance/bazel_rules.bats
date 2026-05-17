#!/usr/bin/env bats

load "test_helper.bash"

setup_file() {
  make_fixture_workspace "cases_workspace"
  export_fixture_workspace
}

teardown_file() {
  cleanup_fixture_workspace
}

@test "bazel-native test passes when report confidence is high" {
  run_in_workspace bazel test \
    --features=swift.index_while_building \
    //:candidate_private_dep_unused_deps

  assert_status 0
}

@test "bazel-native test fails when high-confidence issues are present" {
  run_in_workspace bazel test \
    --features=swift.index_while_building \
    //:unused_import_unused_deps

  assert_status 3
}

@test "bazel-native report emits merged report and fix artifacts" {
  run_in_workspace bash -c '
    bazel build --features=swift.index_while_building //:candidate_private_dep_unused_deps_report
    test -f bazel-bin/candidate_private_dep_unused_deps_report.swift_unused_deps.report.json
    test -f bazel-bin/candidate_private_dep_unused_deps_report.swift_unused_deps.report.txt
    test -f bazel-bin/candidate_private_dep_unused_deps_report.swift_unused_deps.fix.json
    grep -Fq "Summary: 3 targets analyzed, 0 issues found." \
      bazel-bin/candidate_private_dep_unused_deps_report.swift_unused_deps.report.txt
  '

  assert_status 0
}

@test "bazel-native fix target applies generated fix plan" {
  assert_file_contains "cases/Targets/UnusedImport/UnusedImport.swift" "import LibA"
  assert_file_contains "cases/Targets/UnusedImport/BUILD.bazel" "//cases/Deps/LibA"

  run_in_workspace bazel run \
    --features=swift.index_while_building \
    //:unused_import_unused_deps_fix

  assert_status 0
  assert_stderr_contains "remove //cases/Deps/LibA:LibA from deps of //cases/Targets/UnusedImport:UnusedImport"
  assert_file_not_contains "cases/Targets/UnusedImport/UnusedImport.swift" "import LibA"
  assert_file_not_contains "cases/Targets/UnusedImport/BUILD.bazel" "//cases/Deps/LibA"
}

@test "bazel-native fix target can use low fix confidence" {
  assert_file_contains "cases/Targets/CandidatePrivateDep/BUILD.bazel" "//cases/Deps/TransitiveDep"
  assert_file_not_contains "cases/Targets/CandidatePrivateDep/BUILD.bazel" "private_deps"

  run_in_workspace bazel run \
    --features=swift.index_while_building \
    //:candidate_private_dep_low_fix_unused_deps_fix

  assert_status 0
  assert_stderr_contains "move //cases/Deps/TransitiveDep:TransitiveDep from deps to private_deps of //cases/Targets/CandidatePrivateDep:CandidatePrivateDep"
  assert_file_contains "cases/Targets/CandidatePrivateDep/BUILD.bazel" "private_deps"
  assert_file_contains "cases/Targets/CandidatePrivateDep/BUILD.bazel" "//cases/Deps/TransitiveDep"
}
