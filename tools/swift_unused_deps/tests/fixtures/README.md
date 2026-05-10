# Fixture Workspaces

These workspaces are copied to temporary directories by the Bats acceptance
tests. They are input workspaces, not tests by themselves.

Files named `BUILD.fixture` are renamed to `BUILD.bazel` after copying. This keeps
fixture packages from becoming Bazel packages in the repository checkout.

## Case Targets

| Target | Expected behavior | Acceptance coverage |
|--------|-------------------|---------------------|
| `//cases/Targets/CleanTarget:CleanTarget` | Reports clean | Bats asserts clean status, clean deps, and no skipped modules |
| `//cases/Targets/StdlibOnly:StdlibOnly` | Skips `Foundation` as a system module | Bats asserts clean status and skipped system module |
| `//cases/Targets/UnusedImport:UnusedImport` | Reports `unused_import` for `LibA` | Bats asserts report metadata and verifies fix/apply removes the Swift import and BUILD dep |
| `//cases/Targets/MultipleUnusedDeps:MultipleUnusedDeps` | Reports `unused_dep` for `LibA`, `LibB`, and `LibC` | Bats asserts all three issues and verifies fix/apply removes all three BUILD deps |
| `//cases/Targets/MissingDirectDep:MissingDirectDep` | Reports `missing_direct_dep` for `TransitiveDep` | Bats asserts report metadata and verifies fix/apply adds the missing BUILD dep |
| `//cases/Targets/CandidatePrivateDep:CandidatePrivateDep` | Reports `candidate_private_dep` for `TransitiveDep` | Bats asserts report metadata and verifies fix/apply leaves the low-confidence suggestion unchanged |
| `//cases/Targets/UnresolvedSystemModule:UnresolvedSystemModule` | Skips directly imported `RegexBuilder` as a system module | Bats asserts clean status and skipped system modules |
| `//cases/Targets/UnusedDepCustomModuleName:UnusedDepCustomModuleName` | Reports `unused_dep` for `LibA` while keeping the used `AppLogger` module clean | Bats asserts report metadata and verifies fix/apply removes only the unused BUILD dep |
| `//cases/Targets/UnusedTransitiveImport:UnusedTransitiveImport` | Reports `unused_import` for directly imported transitive `TransitiveDep` and `unused_dep` for its wrapper dep | Bats asserts the report and direct fix remove the import and wrapper BUILD dep without adding the transitive dep |
| `//cases/Targets/CleanIOSTarget:CleanIOSTarget` | Reports clean under an iOS platform | Bats asserts it is skipped by the default host report and clean with the iOS simulator platform |
| `//cases/Targets/UnusedDepIOSTarget:UnusedDepIOSTarget` | Reports `unused_dep` for `LibA` under an iOS platform | Bats asserts iOS report metadata and verifies fix/apply removes the unused BUILD dep with the iOS simulator platform |
| `//cases/Targets/UnusedAttributedImport:UnusedAttributedImport` | Reports `unused_import` for attributed `LibA` import | Bats asserts source-removal metadata and verifies fix/apply removes the attributed import and BUILD dep |
| `//cases/Targets/CleanLibraryGroupDep:CleanLibraryGroupDep` | Reports clean for a used `swift_library_group` dep | Bats asserts clean `LibraryGroup` dep resolution |
| `//cases/Targets/UnusedLibraryGroupDep:UnusedLibraryGroupDep` | Reports `unused_dep` for an unused `swift_library_group` dep | Bats asserts report metadata and verifies fix/apply removes the group BUILD dep |

Use the materializer helper to inspect a fixture manually:

```sh
tools/swift_unused_deps/tests/helpers/materialize_fixture_workspace.sh cases_workspace /tmp/swift-unused-deps-cases
```
