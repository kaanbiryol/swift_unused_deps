#!/usr/bin/env bats

load "test_helper.bash"

setup_file() {
  make_fixture_workspace "cases_workspace"
  build_swift_unused_deps_cli
  export_fixture_workspace
}

teardown_file() {
  cleanup_fixture_workspace
}

@test "fix removes unused import and BUILD dep" {
  assert_file_contains "cases/Targets/UnusedImport/UnusedImport.swift" "import LibA"
  assert_file_contains "cases/Targets/UnusedImport/UnusedImport.swift" "import LibB"
  assert_file_contains "cases/Targets/UnusedImport/BUILD.bazel" "//cases/Deps/LibA"
  assert_file_contains "cases/Targets/UnusedImport/BUILD.bazel" "//cases/Deps/LibB"

  run_swift_unused_deps_in_workspace //cases/Targets/UnusedImport:UnusedImport --apply-fix-plan --min-report-confidence high

  assert_status 0
  assert_output_contains "Summary: 1 target analyzed, 0 issues found."

  assert_file_contains "cases/Targets/UnusedImport/UnusedImport.swift" "import LibB"
  assert_file_not_contains "cases/Targets/UnusedImport/UnusedImport.swift" "import LibA"
  assert_file_not_contains "cases/Targets/UnusedImport/BUILD.bazel" "//cases/Deps/LibA"
}

@test "fix adds missing direct BUILD dep" {
  assert_file_contains "cases/Targets/MissingDirectDep/BUILD.bazel" "//cases/Deps/DirectDepWithTransitive"
  assert_file_not_contains "cases/Targets/MissingDirectDep/BUILD.bazel" "//cases/Deps/TransitiveDep"

  run_swift_unused_deps_in_workspace //cases/Targets/MissingDirectDep:MissingDirectDep --apply-fix-plan --min-report-confidence high

  assert_status 0
  assert_output_contains "Summary: 1 target analyzed, 0 issues found."

  assert_file_contains "cases/Targets/MissingDirectDep/BUILD.bazel" "//cases/Deps/DirectDepWithTransitive"
  assert_file_contains "cases/Targets/MissingDirectDep/BUILD.bazel" "//cases/Deps/TransitiveDep"
}

@test "fix leaves low-confidence candidate private dep unchanged" {
  run_swift_unused_deps_in_workspace //cases/Targets/CandidatePrivateDep:CandidatePrivateDep --apply-fix-plan --min-report-confidence high

  assert_status 0
  assert_output_contains "Summary: 1 target analyzed, 0 issues found."
  if [[ "${stderr}" != *"No fixes to apply."* ]]; then
    echo "expected stderr to contain: No fixes to apply." >&2
    echo "--- stderr ---" >&2
    echo "${stderr}" >&2
    return 1
  fi

  assert_file_contains "cases/Targets/CandidatePrivateDep/BUILD.bazel" "//cases/Deps/TransitiveDep"
  assert_file_not_contains "cases/Targets/CandidatePrivateDep/BUILD.bazel" "private_deps"
}

@test "fix can apply low-confidence candidate private dep when requested" {
  run_swift_unused_deps_in_workspace //cases/Targets/CandidatePrivateDep:CandidatePrivateDep --apply-fix-plan --min-fix-confidence low

  assert_status 0
  assert_output_contains "Summary: 1 target analyzed, 0 issues found."

  assert_file_contains "cases/Targets/CandidatePrivateDep/BUILD.bazel" "private_deps"
  assert_file_contains "cases/Targets/CandidatePrivateDep/BUILD.bazel" "//cases/Deps/TransitiveDep"
}

@test "fix removes multiple unused BUILD deps" {
  run_swift_unused_deps_in_workspace //cases/Targets/MultipleUnusedDeps:MultipleUnusedDeps --apply-fix-plan --min-report-confidence high

  assert_status 0
  assert_output_contains "Summary: 1 target analyzed, 0 issues found."

  assert_file_contains "cases/Targets/MultipleUnusedDeps/BUILD.bazel" "//cases/Deps/DirectDepWithTransitive"
  assert_file_contains "cases/Targets/MultipleUnusedDeps/BUILD.bazel" "//cases/Deps/TransitiveDep"
  assert_file_not_contains "cases/Targets/MultipleUnusedDeps/BUILD.bazel" "//cases/Deps/LibA"
  assert_file_not_contains "cases/Targets/MultipleUnusedDeps/BUILD.bazel" "//cases/Deps/LibB"
  assert_file_not_contains "cases/Targets/MultipleUnusedDeps/BUILD.bazel" "//cases/Deps/LibC"
}

@test "fix keeps custom module-name dep and removes unused BUILD dep" {
  run_swift_unused_deps_in_workspace //cases/Targets/UnusedDepCustomModuleName:UnusedDepCustomModuleName --apply-fix-plan --min-report-confidence high

  assert_status 0
  assert_output_contains "Summary: 1 target analyzed, 0 issues found."

  assert_file_contains "cases/Targets/UnusedDepCustomModuleName/UnusedDepCustomModuleName.swift" "import AppLogger"
  assert_file_contains "cases/Targets/UnusedDepCustomModuleName/BUILD.bazel" "//cases/Deps/CustomModuleName"
  assert_file_contains "cases/Targets/UnusedDepCustomModuleName/BUILD.bazel" "//cases/Deps/DirectDepWithTransitive"
  assert_file_contains "cases/Targets/UnusedDepCustomModuleName/BUILD.bazel" "//cases/Deps/TransitiveDep"
  assert_file_not_contains "cases/Targets/UnusedDepCustomModuleName/BUILD.bazel" "//cases/Deps/LibA"
}

@test "fix removes attributed unused import and BUILD dep" {
  run_swift_unused_deps_in_workspace //cases/Targets/UnusedAttributedImport:UnusedAttributedImport --apply-fix-plan --min-report-confidence high

  assert_status 0
  assert_output_contains "Summary: 1 target analyzed, 0 issues found."

  assert_file_contains "cases/Targets/UnusedAttributedImport/UnusedAttributedImport.swift" "import LibB"
  assert_file_not_contains "cases/Targets/UnusedAttributedImport/UnusedAttributedImport.swift" "@preconcurrency import LibA"
  assert_file_not_contains "cases/Targets/UnusedAttributedImport/UnusedAttributedImport.swift" "import LibA"
  assert_file_not_contains "cases/Targets/UnusedAttributedImport/BUILD.bazel" "//cases/Deps/LibA"
}

@test "fix removes unused swift_library_group BUILD dep" {
  run_swift_unused_deps_in_workspace //cases/Targets/UnusedLibraryGroupDep:UnusedLibraryGroupDep --apply-fix-plan --min-report-confidence high

  assert_status 0
  assert_output_contains "Summary: 1 target analyzed, 0 issues found."

  assert_file_contains "cases/Targets/UnusedLibraryGroupDep/BUILD.bazel" "//cases/Deps/TransitiveDep"
  assert_file_not_contains "cases/Targets/UnusedLibraryGroupDep/BUILD.bazel" "//cases/Deps/LibraryGroup"
}

@test "fix removes unused BUILD dep for iOS target" {
  run_swift_unused_deps_in_workspace --build-config swift-unused-deps-ios //cases/Targets/UnusedDepIOSTarget:UnusedDepIOSTarget --apply-fix-plan --min-report-confidence high

  assert_status 0
  assert_output_contains "Summary: 1 target analyzed, 0 issues found."

  assert_file_contains "cases/Targets/UnusedDepIOSTarget/BUILD.bazel" "//cases/Deps/iOSLib"
  assert_file_not_contains "cases/Targets/UnusedDepIOSTarget/BUILD.bazel" "//cases/Deps/LibA"
}
