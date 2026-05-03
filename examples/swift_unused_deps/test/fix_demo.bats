#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../../.." && pwd)"
  EXAMPLE_TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/swift-unused-deps-example-bats.XXXXXX")"
}

teardown() {
  rm -rf "${EXAMPLE_TEMP_DIR}"
}

assert_status() {
  local expected="$1"
  if [[ "${status}" -ne "${expected}" ]]; then
    echo "expected status ${expected}, got ${status}" >&2
    echo "--- output ---" >&2
    echo "${output}" >&2
    return 1
  fi
}

assert_output_contains() {
  local expected="$1"
  if [[ "${output}" != *"${expected}"* ]]; then
    echo "expected output to contain: ${expected}" >&2
    echo "--- output ---" >&2
    echo "${output}" >&2
    return 1
  fi
}

assert_file_contains() {
  local file="$1"
  local expected="$2"
  if ! grep -Fq "${expected}" "${file}"; then
    echo "expected ${file} to contain: ${expected}" >&2
    echo "--- ${file} ---" >&2
    cat "${file}" >&2
    return 1
  fi
}

assert_file_not_contains() {
  local file="$1"
  local unexpected="$2"
  if grep -Fq "${unexpected}" "${file}"; then
    echo "expected ${file} not to contain: ${unexpected}" >&2
    echo "--- ${file} ---" >&2
    cat "${file}" >&2
    return 1
  fi
}

@test "fix demo materializes a workspace and leaves an inspectable diff" {
  destination="${EXAMPLE_TEMP_DIR}/unused-import"

  run "${REPO_ROOT}/examples/swift_unused_deps/run_fix_demo.sh" unused-import "${destination}"

  assert_status 0
  assert_output_contains "Example workspace: ${destination}"
  assert_output_contains "Changed files:"
  assert_output_contains "cases/Targets/UnusedImport/UnusedImport.swift"
  assert_output_contains "cases/Targets/UnusedImport/BUILD.bazel"

  assert_file_contains "${destination}/cases/Targets/UnusedImport/UnusedImport.swift" "import LibB"
  assert_file_not_contains "${destination}/cases/Targets/UnusedImport/UnusedImport.swift" "import LibA"
  assert_file_not_contains "${destination}/cases/Targets/UnusedImport/BUILD.bazel" "//cases/Deps/LibA"

  diff="$(git -C "${destination}" diff -- cases/Targets/UnusedImport)"
  [[ "${diff}" == *"-import LibA"* ]]
  [[ "${diff}" == *"-        \"//cases/Deps/LibA\""* ]]
}
