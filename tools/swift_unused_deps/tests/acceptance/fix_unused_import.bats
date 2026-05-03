#!/usr/bin/env bats

load "test_helper.bash"

setup() {
  make_fixture_workspace "cases_workspace"
}

teardown() {
  cleanup_fixture_workspace
}

@test "fix removes unused import and BUILD dep" {
  run_in_workspace bazel run //:swift_unused_deps -- //cases/Targets/UnusedImport:UnusedImport --json

  assert_status 1
  assert_output_contains '"kind" : "unused_import"'
  assert_output_contains '"module_name" : "LibA"'
  assert_output_contains '"module_name" : "LibB"'
  assert_output_contains '"classification" : "correctly_declared_dep"'
  assert_output_not_contains '"dep_module" : "LibB"'
  assert_output_contains '"source_import_removals"'

  unused_import_count="$(grep -o '"kind" : "unused_import"' <<<"${output}" | wc -l | tr -d ' ')"
  [[ "${unused_import_count}" == "1" ]]

  run_in_workspace bazel run //:swift_unused_deps -- //cases/Targets/UnusedImport:UnusedImport --fix --min-confidence high

  assert_status 0
  assert_output_contains "Summary: 1 target analyzed, 0 issues found."

  assert_file_contains "cases/Targets/UnusedImport/UnusedImport.swift" "import LibB"
  assert_file_not_contains "cases/Targets/UnusedImport/UnusedImport.swift" "import LibA"
  assert_file_not_contains "cases/Targets/UnusedImport/BUILD.bazel" "//cases/Deps/LibA"
}

@test "fix adds missing direct BUILD dep" {
  run_in_workspace bazel run //:swift_unused_deps -- //cases/Targets/MissingDirectDep:MissingDirectDep --json

  assert_status 1
  assert_output_contains '"kind" : "missing_direct_dep"'
  assert_output_contains '"dep_module" : "TransitiveDep"'
  assert_file_not_contains "cases/Targets/MissingDirectDep/BUILD.bazel" "//cases/Deps/TransitiveDep"

  run_in_workspace bazel run //:swift_unused_deps -- //cases/Targets/MissingDirectDep:MissingDirectDep --fix --min-confidence high

  assert_status 0
  assert_output_contains "Summary: 1 target analyzed, 0 issues found."

  assert_file_contains "cases/Targets/MissingDirectDep/BUILD.bazel" "//cases/Deps/DirectDepWithTransitive"
  assert_file_contains "cases/Targets/MissingDirectDep/BUILD.bazel" "//cases/Deps/TransitiveDep"
}
