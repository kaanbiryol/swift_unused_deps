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

export_fixture_workspace() {
  export FIXTURE_TEMP_DIR
  export FIXTURE_WORKSPACE
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

    target=""
    apply_fix="false"
    json="false"
    build_config=""
    build_flags=("--features=swift.index_while_building")
    has_platform="false"
    report_confidence="low"
    fix_confidence="high"

    while [[ $# -gt 0 ]]; do
      case "$1" in
        --build-config)
          build_config="$2"
          shift 2
          ;;
        --build-config=*)
          build_config="${1#*=}"
          shift
          ;;
        --platforms)
          build_flags+=("--platforms=$2")
          has_platform="true"
          shift 2
          ;;
        --platforms=*)
          build_flags+=("$1")
          has_platform="true"
          shift
          ;;
        --apply-fix-plan)
          apply_fix="true"
          shift
          ;;
        --min-report-confidence)
          report_confidence="$2"
          shift 2
          ;;
        --min-report-confidence=*)
          report_confidence="${1#*=}"
          shift
          ;;
        --min-fix-confidence)
          fix_confidence="$2"
          shift 2
          ;;
        --min-fix-confidence=*)
          fix_confidence="${1#*=}"
          shift
          ;;
        --json)
          json="true"
          shift
          ;;
        --extra-system-modules|--index-store-path|--report-output|--fix-output)
          echo "$1 is not supported by the Bazel-native acceptance helper" >&2
          exit 2
          ;;
        --extra-system-modules=*|--index-store-path=*|--report-output=*|--fix-output=*)
          echo "${1%%=*} is not supported by the Bazel-native acceptance helper" >&2
          exit 2
          ;;
        --*)
          echo "unknown option: $1" >&2
          exit 2
          shift
          ;;
        *)
          target="$1"
          shift
          ;;
      esac
    done

    if [[ -z "${target}" ]]; then
      echo "missing target pattern" >&2
      exit 2
    fi

    if [[ -n "${build_config}" ]]; then
      build_flags=("--config=${build_config}" "${build_flags[@]}")
    fi

    analysis_pkg="swift_unused_deps_acceptance"
    if [[ "${target}" == //cases/* ]]; then
      analysis_pkg="cases/swift_unused_deps_acceptance"
    fi
    analysis_name="analysis"
    mkdir -p "${analysis_pkg}"

    query_expr="kind(\".* rule\", ${target})"
    if [[ "${has_platform}" != "true" ]]; then
      query_expr="${query_expr} except attr(\"target_compatible_with\", \".*@platforms//.*\", ${target})"
    fi

    target_labels=()
    while IFS= read -r label; do
      target_labels+=("${label}")
    done < <(bazel query "${query_expr}" --output=label 2>/dev/null)
    if [[ "${#target_labels[@]}" -eq 0 ]]; then
      echo "no rule targets matched ${target}" >&2
      exit 2
    fi

    {
      printf "%s\n" "load(\"@swift_unused_deps//tools/swift_unused_deps:defs.bzl\", \"swift_unused_deps\")"
      printf "\n"
      printf "%s\n" "swift_unused_deps("
      printf "    name = \"%s\",\n" "${analysis_name}"
      printf "    report_confidence = \"%s\",\n" "${report_confidence}"
      printf "    fix_confidence = \"%s\",\n" "${fix_confidence}"
      printf "    targets = [\n"
      for label in "${target_labels[@]}"; do
        printf "        \"%s\",\n" "${label}"
      done
      printf "    ],\n"
      printf "%s\n" ")"
    } > "${analysis_pkg}/BUILD.bazel"

    analysis_target="//${analysis_pkg}:${analysis_name}"
    report_target="${analysis_target}_report"
    fix_target="${analysis_target}_fix"

    if [[ "${apply_fix}" == "true" ]]; then
      bazel run "${build_flags[@]}" "${fix_target}" || exit $?
    fi

    bazel build "${build_flags[@]}" "${report_target}" >/dev/null || exit $?
    bazel_bin="$(bazel info bazel-bin 2>/dev/null)"
    report_prefix="${bazel_bin}/${analysis_pkg}/${analysis_name}_report.swift_unused_deps"

    if [[ "${json}" == "true" ]]; then
      cat "${report_prefix}.report.json"
    else
      cat "${report_prefix}.report.txt"
    fi

    exit "$(cat "${report_prefix}.exit_code")"
  ' bash "${FIXTURE_WORKSPACE}" "$@"
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

assert_stderr_contains() {
  local expected="$1"
  if [[ "${stderr}" != *"${expected}"* ]]; then
    echo "expected stderr to contain: ${expected}" >&2
    echo "--- stderr ---" >&2
    echo "${stderr}" >&2
    return 1
  fi
}

assert_stderr_not_contains() {
  local unexpected="$1"
  if [[ "${stderr}" == *"${unexpected}"* ]]; then
    echo "expected stderr not to contain: ${unexpected}" >&2
    echo "--- stderr ---" >&2
    echo "${stderr}" >&2
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
