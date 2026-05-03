# Fixture Workspaces

These workspaces are copied to temporary directories by the Bats acceptance
tests. They are input workspaces, not tests by themselves.

Files named `BUILD.fixture` are renamed to `BUILD.bazel` after copying. This keeps
fixture packages from becoming Bazel packages in the repository checkout.

## Case Targets

| Target | Expected behavior | Fix coverage |
|--------|-------------------|--------------|
| `//cases/Targets/CleanTarget:CleanTarget` | Reports clean | Not fixable |
| `//cases/Targets/StdlibOnly:StdlibOnly` | Skips `Foundation` as a system module | Not fixable |
| `//cases/Targets/UnusedImport:UnusedImport` | Reports `unused_import` for `LibA` | Bats verifies `--fix` removes the Swift import and BUILD dep |
| `//cases/Targets/MultipleUnusedDeps:MultipleUnusedDeps` | Reports `unused_dep` for `LibC` | Fixable; no acceptance assertion yet |
| `//cases/Targets/MissingDirectDep:MissingDirectDep` | Reports `missing_direct_dep` for `TransitiveDep` | Bats verifies `--fix` adds the missing BUILD dep |
| `//cases/Targets/CandidatePrivateDep:CandidatePrivateDep` | Reports `candidate_private_dep` for `TransitiveDep` | Not auto-fixed |
| `//cases/Targets/UnresolvedSystemModule:UnresolvedSystemModule` | Reports `unresolved_module` for `RegexBuilder` | Not auto-fixed |
| `//cases/Targets/UnusedDepCustomModuleName:UnusedDepCustomModuleName` | Exercises labels whose Swift module name differs from the Bazel target name | Fixable; no acceptance assertion yet |
| `//cases/Targets/UnusedDepIOSTarget:UnusedDepIOSTarget` | Exercises platform-specific Swift targets | Fixable; no acceptance assertion yet |
| `//cases/Targets/UnusedAttributedImport:UnusedAttributedImport` | Exercises attributed Swift imports | Fixable; no acceptance assertion yet |
| `//cases/Targets/CleanLibraryGroupDep:CleanLibraryGroupDep` | Exercises a used `swift_library_group` dep | Not fixable |
| `//cases/Targets/UnusedLibraryGroupDep:UnusedLibraryGroupDep` | Exercises an unused `swift_library_group` dep | Fixable; no acceptance assertion yet |

Use the materializer helper to inspect a fixture manually:

```sh
tools/swift_unused_deps/tests/helpers/materialize_fixture_workspace.sh cases_workspace /tmp/swift-unused-deps-cases
```
