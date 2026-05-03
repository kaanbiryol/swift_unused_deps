bats_require_minimum_version 1.5.0

repo_root() {
  cd "${BATS_TEST_DIRNAME}/../../../.." && pwd
}

make_fixture_workspace() {
  local fixture_name="$1"
  local root

  root="$(repo_root)"
  FIXTURE_TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/swift-unused-deps-bats.XXXXXX")"
  FIXTURE_WORKSPACE="${FIXTURE_TEMP_DIR}/workspace"

  "${root}/tools/swift_unused_deps/tests/helpers/materialize_fixture_workspace.sh" \
    "${fixture_name}" \
    "${FIXTURE_WORKSPACE}" \
    "${root}"
}

build_swift_unused_deps_cli() {
  local root
  local bazel_bin

  if [[ -n "${SWIFT_UNUSED_DEPS_BINARY:-}" ]]; then
    if [[ -x "${SWIFT_UNUSED_DEPS_BINARY}" ]]; then
      return 0
    fi
    echo "swift_unused_deps binary not found: ${SWIFT_UNUSED_DEPS_BINARY}" >&2
    return 1
  fi

  root="$(repo_root)"
  SWIFT_UNUSED_DEPS_BINARY="${root}/bazel-bin/tools/swift_unused_deps/analyzer/swift_unused_deps"
  if [[ -x "${SWIFT_UNUSED_DEPS_BINARY}" ]]; then
    return 0
  fi

  (cd "${root}" && bazel build //:swift_unused_deps >/dev/null)

  bazel_bin="$(cd "${root}" && bazel info bazel-bin 2>/dev/null)"
  SWIFT_UNUSED_DEPS_BINARY="${bazel_bin}/tools/swift_unused_deps/analyzer/swift_unused_deps"
  if [[ ! -x "${SWIFT_UNUSED_DEPS_BINARY}" ]]; then
    echo "swift_unused_deps binary not found: ${SWIFT_UNUSED_DEPS_BINARY}" >&2
    return 1
  fi
}

export_fixture_workspace() {
  export FIXTURE_TEMP_DIR
  export FIXTURE_WORKSPACE
  export SWIFT_UNUSED_DEPS_BINARY
}

cleanup_fixture_workspace() {
  if [[ -n "${FIXTURE_WORKSPACE:-}" && -d "${FIXTURE_WORKSPACE}" ]]; then
    (cd "${FIXTURE_WORKSPACE}" && bazel shutdown >/dev/null 2>&1) || true
  fi

  if [[ -n "${FIXTURE_TEMP_DIR:-}" ]]; then
    rm -rf "${FIXTURE_TEMP_DIR}"
  fi
}

run_in_workspace() {
  run --separate-stderr bash -c 'cd "$1" && shift && "$@"' bash "${FIXTURE_WORKSPACE}" "$@"
}

run_swift_unused_deps_in_workspace() {
  run --separate-stderr bash -c '
    cd "$1"
    shift
    unset BUILD_WORKING_DIRECTORY
    export BUILD_WORKSPACE_DIRECTORY="$PWD"
    "$@"
  ' bash "${FIXTURE_WORKSPACE}" "${SWIFT_UNUSED_DEPS_BINARY}" "$@"
}

assert_status() {
  local expected="$1"
  if [[ "${status}" -ne "${expected}" ]]; then
    echo "expected status ${expected}, got ${status}" >&2
    echo "--- stdout ---" >&2
    echo "${output}" >&2
    echo "--- stderr ---" >&2
    echo "${stderr}" >&2
    return 1
  fi
}

assert_output_contains() {
  local expected="$1"
  if [[ "${output}" != *"${expected}"* ]]; then
    echo "expected stdout to contain: ${expected}" >&2
    echo "--- stdout ---" >&2
    echo "${output}" >&2
    return 1
  fi
}

assert_output_not_contains() {
  local unexpected="$1"
  if [[ "${output}" == *"${unexpected}"* ]]; then
    echo "expected stdout not to contain: ${unexpected}" >&2
    echo "--- stdout ---" >&2
    echo "${output}" >&2
    return 1
  fi
}

assert_file_contains() {
  local file="$1"
  local expected="$2"
  if ! grep -Fq "${expected}" "${FIXTURE_WORKSPACE}/${file}"; then
    echo "expected ${file} to contain: ${expected}" >&2
    echo "--- ${file} ---" >&2
    cat "${FIXTURE_WORKSPACE}/${file}" >&2
    return 1
  fi
}

assert_file_not_contains() {
  local file="$1"
  local unexpected="$2"
  if grep -Fq "${unexpected}" "${FIXTURE_WORKSPACE}/${file}"; then
    echo "expected ${file} not to contain: ${unexpected}" >&2
    echo "--- ${file} ---" >&2
    cat "${FIXTURE_WORKSPACE}/${file}" >&2
    return 1
  fi
}
