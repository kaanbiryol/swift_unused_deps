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

@test "cases workspace reports expected results across fixture targets" {
  run_swift_unused_deps_in_workspace //cases/Targets/... --json

  assert_status 1

  REPORT_JSON="${output}" python3 - <<'PY'
import json
import os
import sys

report = json.loads(os.environ["REPORT_JSON"])
results = {result["target"]: result for result in report["results"]}

expected_reported_targets = {
    "//cases/Targets/CandidatePrivateDep:CandidatePrivateDep",
    "//cases/Targets/CleanLibraryGroupDep:CleanLibraryGroupDep",
    "//cases/Targets/CleanTarget:CleanTarget",
    "//cases/Targets/MissingDirectDep:MissingDirectDep",
    "//cases/Targets/MultipleUnusedDeps:MultipleUnusedDeps",
    "//cases/Targets/StdlibOnly:StdlibOnly",
    "//cases/Targets/UnresolvedSystemModule:UnresolvedSystemModule",
    "//cases/Targets/UnusedAttributedImport:UnusedAttributedImport",
    "//cases/Targets/UnusedDepCustomModuleName:UnusedDepCustomModuleName",
    "//cases/Targets/UnusedImport:UnusedImport",
    "//cases/Targets/UnusedLibraryGroupDep:UnusedLibraryGroupDep",
}

expected_incompatible_targets = {
    "//cases/Targets/CleanIOSTarget:CleanIOSTarget",
    "//cases/Targets/UnusedDepIOSTarget:UnusedDepIOSTarget",
}

def fail(message):
    print(message, file=sys.stderr)
    sys.exit(1)

def require(condition, message):
    if not condition:
        fail(message)

def describe(items):
    return ", ".join(sorted(items)) or "<none>"

def require_target_set():
    actual_targets = set(results)
    unexpected_targets = actual_targets - expected_reported_targets - expected_incompatible_targets
    reported_incompatible_targets = actual_targets & expected_incompatible_targets
    require(
        not expected_reported_targets - actual_targets,
        "reported targets mismatch\n"
        f"missing: {describe(expected_reported_targets - actual_targets)}",
    )
    require(
        not unexpected_targets,
        "reported targets mismatch\n"
        f"unexpected: {describe(unexpected_targets)}",
    )
    require(
        not reported_incompatible_targets,
        "iOS-only targets should be skipped on the default host platform, "
        f"but were reported: {describe(reported_incompatible_targets)}",
    )

def require_status(target, expected):
    actual = results[target].get("status")
    require(
        actual == expected,
        f"{target} should have status {expected}, got {actual}",
    )

def issue_keys(target):
    return {
        (issue.get("kind"), issue.get("dep_module"))
        for issue in results[target].get("issues", [])
    }

def require_issues(target, expected):
    actual = issue_keys(target)
    require(
        actual == set(expected),
        f"{target} issues mismatch\n"
        f"expected: {describe(map(str, expected))}\n"
        f"actual: {describe(map(str, actual))}",
    )

def require_clean_modules(target, expected):
    actual = {
        dep.get("module_name")
        for dep in results[target].get("clean_deps", [])
    }
    require(
        actual == set(expected),
        f"{target} clean deps mismatch\n"
        f"expected: {describe(expected)}\n"
        f"actual: {describe(actual)}",
    )

def require_skipped_modules(target, expected):
    actual = {
        (module.get("module_name"), module.get("reason"))
        for module in results[target].get("skipped_modules", [])
    }
    require(
        actual == set(expected),
        f"{target} skipped modules mismatch\n"
        f"expected: {describe(map(str, expected))}\n"
        f"actual: {describe(map(str, actual))}",
    )

def require_source_removal(target, module_name):
    require(
        any(
            removal.get("module_name") == module_name
            for issue in results[target].get("issues", [])
            for removal in issue.get("source_import_removals", [])
        ),
        f"{target} should include a source import removal for {module_name}",
    )

require_target_set()

require_status("//cases/Targets/CleanTarget:CleanTarget", "clean")
require_clean_modules(
    "//cases/Targets/CleanTarget:CleanTarget",
    {"DirectDepWithTransitive", "LibB", "TransitiveDep"},
)
require_issues("//cases/Targets/CleanTarget:CleanTarget", set())
require_skipped_modules("//cases/Targets/CleanTarget:CleanTarget", set())

require_status("//cases/Targets/StdlibOnly:StdlibOnly", "clean")
require_clean_modules("//cases/Targets/StdlibOnly:StdlibOnly", set())
require_issues("//cases/Targets/StdlibOnly:StdlibOnly", set())
require_skipped_modules(
    "//cases/Targets/StdlibOnly:StdlibOnly",
    {("Foundation", "system_module")},
)

require_status("//cases/Targets/UnusedImport:UnusedImport", "issues_found")
require_clean_modules("//cases/Targets/UnusedImport:UnusedImport", {"LibB"})
require_issues(
    "//cases/Targets/UnusedImport:UnusedImport",
    {("unused_import", "LibA")},
)
require_skipped_modules("//cases/Targets/UnusedImport:UnusedImport", set())
require_source_removal("//cases/Targets/UnusedImport:UnusedImport", "LibA")

require_status("//cases/Targets/MultipleUnusedDeps:MultipleUnusedDeps", "issues_found")
require_clean_modules(
    "//cases/Targets/MultipleUnusedDeps:MultipleUnusedDeps",
    {"DirectDepWithTransitive", "TransitiveDep"},
)
require_issues(
    "//cases/Targets/MultipleUnusedDeps:MultipleUnusedDeps",
    {("unused_dep", "LibA"), ("unused_dep", "LibB"), ("unused_dep", "LibC")},
)
require_skipped_modules("//cases/Targets/MultipleUnusedDeps:MultipleUnusedDeps", set())

require_status("//cases/Targets/MissingDirectDep:MissingDirectDep", "issues_found")
require_clean_modules(
    "//cases/Targets/MissingDirectDep:MissingDirectDep",
    {"DirectDepWithTransitive"},
)
require_issues(
    "//cases/Targets/MissingDirectDep:MissingDirectDep",
    {("missing_direct_dep", "TransitiveDep")},
)
require_skipped_modules("//cases/Targets/MissingDirectDep:MissingDirectDep", set())

require_status("//cases/Targets/CandidatePrivateDep:CandidatePrivateDep", "issues_found")
require_clean_modules(
    "//cases/Targets/CandidatePrivateDep:CandidatePrivateDep",
    {"DirectDepWithTransitive", "TransitiveDep"},
)
require_issues(
    "//cases/Targets/CandidatePrivateDep:CandidatePrivateDep",
    {("candidate_private_dep", "TransitiveDep")},
)
require_skipped_modules("//cases/Targets/CandidatePrivateDep:CandidatePrivateDep", set())

require_status("//cases/Targets/UnresolvedSystemModule:UnresolvedSystemModule", "clean")
require_clean_modules("//cases/Targets/UnresolvedSystemModule:UnresolvedSystemModule", set())
require_issues(
    "//cases/Targets/UnresolvedSystemModule:UnresolvedSystemModule",
    set(),
)
require_skipped_modules(
    "//cases/Targets/UnresolvedSystemModule:UnresolvedSystemModule",
    {("Foundation", "system_module"), ("RegexBuilder", "system_module")},
)

require_status("//cases/Targets/UnusedAttributedImport:UnusedAttributedImport", "issues_found")
require_clean_modules("//cases/Targets/UnusedAttributedImport:UnusedAttributedImport", {"LibB"})
require_issues(
    "//cases/Targets/UnusedAttributedImport:UnusedAttributedImport",
    {("unused_import", "LibA")},
)
require_skipped_modules("//cases/Targets/UnusedAttributedImport:UnusedAttributedImport", set())
require_source_removal("//cases/Targets/UnusedAttributedImport:UnusedAttributedImport", "LibA")

require_status("//cases/Targets/UnusedDepCustomModuleName:UnusedDepCustomModuleName", "issues_found")
require_clean_modules(
    "//cases/Targets/UnusedDepCustomModuleName:UnusedDepCustomModuleName",
    {"AppLogger", "DirectDepWithTransitive", "TransitiveDep"},
)
require_issues(
    "//cases/Targets/UnusedDepCustomModuleName:UnusedDepCustomModuleName",
    {("unused_dep", "LibA")},
)
require_skipped_modules("//cases/Targets/UnusedDepCustomModuleName:UnusedDepCustomModuleName", set())

require_status("//cases/Targets/CleanLibraryGroupDep:CleanLibraryGroupDep", "clean")
require_clean_modules("//cases/Targets/CleanLibraryGroupDep:CleanLibraryGroupDep", {"LibraryGroup"})
require_issues("//cases/Targets/CleanLibraryGroupDep:CleanLibraryGroupDep", set())
require_skipped_modules("//cases/Targets/CleanLibraryGroupDep:CleanLibraryGroupDep", set())

require_status("//cases/Targets/UnusedLibraryGroupDep:UnusedLibraryGroupDep", "issues_found")
require_clean_modules("//cases/Targets/UnusedLibraryGroupDep:UnusedLibraryGroupDep", {"TransitiveDep"})
require_issues(
    "//cases/Targets/UnusedLibraryGroupDep:UnusedLibraryGroupDep",
    {("unused_dep", "LibraryGroup")},
)
require_skipped_modules("//cases/Targets/UnusedLibraryGroupDep:UnusedLibraryGroupDep", set())
PY
}

@test "iOS cases report expected results with iOS platform settings" {
  run_swift_unused_deps_in_workspace --platforms=@apple_support//platforms:ios_sim_arm64 //cases/Targets/CleanIOSTarget:CleanIOSTarget --json

  assert_status 0

  REPORT_JSON="${output}" python3 - <<'PY'
import json
import os
import sys

report = json.loads(os.environ["REPORT_JSON"])
results = {result["target"]: result for result in report["results"]}
target = "//cases/Targets/CleanIOSTarget:CleanIOSTarget"

if set(results) != {target}:
    print(f"expected only {target}, got {sorted(results)}", file=sys.stderr)
    sys.exit(1)

result = results[target]
clean_modules = {dep.get("module_name") for dep in result.get("clean_deps", [])}
if result.get("status") != "clean":
    print(f"{target} should be clean, got {result.get('status')}", file=sys.stderr)
    sys.exit(1)
if clean_modules != {"iOSLib"}:
    print(f"{target} clean deps mismatch: {sorted(clean_modules)}", file=sys.stderr)
    sys.exit(1)
if result.get("issues") or result.get("skipped_modules"):
    print(f"{target} should not have issues or skipped modules", file=sys.stderr)
    sys.exit(1)
PY

  run_swift_unused_deps_in_workspace --platforms=@apple_support//platforms:ios_sim_arm64 //cases/Targets/UnusedDepIOSTarget:UnusedDepIOSTarget --json

  assert_status 1

  REPORT_JSON="${output}" python3 - <<'PY'
import json
import os
import sys

report = json.loads(os.environ["REPORT_JSON"])
results = {result["target"]: result for result in report["results"]}
target = "//cases/Targets/UnusedDepIOSTarget:UnusedDepIOSTarget"

if set(results) != {target}:
    print(f"expected only {target}, got {sorted(results)}", file=sys.stderr)
    sys.exit(1)

result = results[target]
clean_modules = {dep.get("module_name") for dep in result.get("clean_deps", [])}
issues = {
    (issue.get("kind"), issue.get("dep_module"))
    for issue in result.get("issues", [])
}
if result.get("status") != "issues_found":
    print(f"{target} should have issues_found, got {result.get('status')}", file=sys.stderr)
    sys.exit(1)
if clean_modules != {"iOSLib"}:
    print(f"{target} clean deps mismatch: {sorted(clean_modules)}", file=sys.stderr)
    sys.exit(1)
if issues != {("unused_dep", "LibA")}:
    print(f"{target} issues mismatch: {sorted(issues)}", file=sys.stderr)
    sys.exit(1)
if result.get("skipped_modules"):
    print(f"{target} should not have skipped modules", file=sys.stderr)
    sys.exit(1)
PY
}
