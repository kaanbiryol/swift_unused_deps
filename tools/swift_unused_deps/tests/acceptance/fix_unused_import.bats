#!/usr/bin/env bats

load "test_helper.bash"

setup_file() {
  make_fixture_workspace "cases_workspace"
  export_fixture_workspace
}

teardown_file() {
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

@test "fix leaves low-confidence candidate private dep unchanged" {
  run_in_workspace bazel run //:swift_unused_deps -- //cases/Targets/CandidatePrivateDep:CandidatePrivateDep --fix --min-confidence high

  assert_status 0
  assert_output_contains "Summary: 1 target analyzed, 0 issues found."
  if [[ "${stderr}" != *"No high-confidence fixes to apply."* ]]; then
    echo "expected stderr to contain: No high-confidence fixes to apply." >&2
    echo "--- stderr ---" >&2
    echo "${stderr}" >&2
    return 1
  fi

  assert_file_contains "cases/Targets/CandidatePrivateDep/BUILD.bazel" "//cases/Deps/TransitiveDep"
  assert_file_not_contains "cases/Targets/CandidatePrivateDep/BUILD.bazel" "private_deps"
}

@test "fix removes multiple unused BUILD deps" {
  run_in_workspace bazel run //:swift_unused_deps -- //cases/Targets/MultipleUnusedDeps:MultipleUnusedDeps --fix --min-confidence high

  assert_status 0
  assert_output_contains "Summary: 1 target analyzed, 0 issues found."

  assert_file_contains "cases/Targets/MultipleUnusedDeps/BUILD.bazel" "//cases/Deps/DirectDepWithTransitive"
  assert_file_contains "cases/Targets/MultipleUnusedDeps/BUILD.bazel" "//cases/Deps/TransitiveDep"
  assert_file_not_contains "cases/Targets/MultipleUnusedDeps/BUILD.bazel" "//cases/Deps/LibA"
  assert_file_not_contains "cases/Targets/MultipleUnusedDeps/BUILD.bazel" "//cases/Deps/LibB"
  assert_file_not_contains "cases/Targets/MultipleUnusedDeps/BUILD.bazel" "//cases/Deps/LibC"
}

@test "fix keeps custom module-name dep and removes unused BUILD dep" {
  run_in_workspace bazel run //:swift_unused_deps -- //cases/Targets/UnusedDepCustomModuleName:UnusedDepCustomModuleName --fix --min-confidence high

  assert_status 0
  assert_output_contains "Summary: 1 target analyzed, 0 issues found."

  assert_file_contains "cases/Targets/UnusedDepCustomModuleName/UnusedDepCustomModuleName.swift" "import AppLogger"
  assert_file_contains "cases/Targets/UnusedDepCustomModuleName/BUILD.bazel" "//cases/Deps/CustomModuleName"
  assert_file_contains "cases/Targets/UnusedDepCustomModuleName/BUILD.bazel" "//cases/Deps/DirectDepWithTransitive"
  assert_file_contains "cases/Targets/UnusedDepCustomModuleName/BUILD.bazel" "//cases/Deps/TransitiveDep"
  assert_file_not_contains "cases/Targets/UnusedDepCustomModuleName/BUILD.bazel" "//cases/Deps/LibA"
}

@test "fix removes attributed unused import and BUILD dep" {
  run_in_workspace bazel run //:swift_unused_deps -- //cases/Targets/UnusedAttributedImport:UnusedAttributedImport --fix --min-confidence high

  assert_status 0
  assert_output_contains "Summary: 1 target analyzed, 0 issues found."

  assert_file_contains "cases/Targets/UnusedAttributedImport/UnusedAttributedImport.swift" "import LibB"
  assert_file_not_contains "cases/Targets/UnusedAttributedImport/UnusedAttributedImport.swift" "@preconcurrency import LibA"
  assert_file_not_contains "cases/Targets/UnusedAttributedImport/UnusedAttributedImport.swift" "import LibA"
  assert_file_not_contains "cases/Targets/UnusedAttributedImport/BUILD.bazel" "//cases/Deps/LibA"
}

@test "fix removes unused swift_library_group BUILD dep" {
  run_in_workspace bazel run //:swift_unused_deps -- //cases/Targets/UnusedLibraryGroupDep:UnusedLibraryGroupDep --fix --min-confidence high

  assert_status 0
  assert_output_contains "Summary: 1 target analyzed, 0 issues found."

  assert_file_contains "cases/Targets/UnusedLibraryGroupDep/BUILD.bazel" "//cases/Deps/TransitiveDep"
  assert_file_not_contains "cases/Targets/UnusedLibraryGroupDep/BUILD.bazel" "//cases/Deps/LibraryGroup"
}

@test "fix removes unused BUILD dep for iOS target" {
  run_in_workspace bazel run //:swift_unused_deps -- --build-config unused-deps-ios //cases/Targets/UnusedDepIOSTarget:UnusedDepIOSTarget --fix --min-confidence high

  assert_status 0
  assert_output_contains "Summary: 1 target analyzed, 0 issues found."

  assert_file_contains "cases/Targets/UnusedDepIOSTarget/BUILD.bazel" "//cases/Deps/iOSLib"
  assert_file_not_contains "cases/Targets/UnusedDepIOSTarget/BUILD.bazel" "//cases/Deps/LibA"
}
