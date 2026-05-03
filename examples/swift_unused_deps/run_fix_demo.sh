#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: run_fix_demo.sh [unused-import|missing-direct-dep] [destination]

Materializes an example workspace, runs swift_unused_deps --fix, and prints the
git diff from the temporary workspace.

If destination is omitted, a fresh directory is created under ${TMPDIR:-/tmp}.
If destination is provided, it must be empty or not exist.
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

scenario="${1:-unused-import}"
destination="${2:-}"

case "${scenario}" in
  unused-import)
    target="//cases/Targets/UnusedImport:UnusedImport"
    ;;
  missing-direct-dep)
    target="//cases/Targets/MissingDirectDep:MissingDirectDep"
    ;;
  *)
    usage
    echo "unknown scenario: ${scenario}" >&2
    exit 2
    ;;
esac

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(git -C "${script_dir}" rev-parse --show-toplevel)"
materialize="${repo_root}/tools/swift_unused_deps/tests/helpers/materialize_fixture_workspace.sh"

if [[ -z "${destination}" ]]; then
  destination="$(mktemp -d "${TMPDIR:-/tmp}/swift-unused-deps-${scenario}.XXXXXX")"
else
  mkdir -p "${destination}"
  if [[ -n "$(find "${destination}" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
    echo "destination must be empty: ${destination}" >&2
    exit 2
  fi
fi

shutdown_bazel() {
  if [[ -f "${destination}/MODULE.bazel" ]]; then
    (cd "${destination}" && bazel shutdown >/dev/null 2>&1) || true
  fi
}
trap shutdown_bazel EXIT

"${materialize}" cases_workspace "${destination}" "${repo_root}"

git -C "${destination}" init --quiet
{
  echo "/bazel-*"
  echo "/bazel-bin"
  echo "/bazel-out"
  echo "/bazel-testlogs"
  echo ".DS_Store"
} >>"${destination}/.git/info/exclude"
git -C "${destination}" config user.email "swift-unused-deps@example.invalid"
git -C "${destination}" config user.name "swift unused deps example"
git -C "${destination}" add -A
git -C "${destination}" commit --quiet --message "initial example workspace"

echo "Example workspace: ${destination}"
echo "Scenario: ${scenario}"
echo "Target: ${target}"
echo

(
  cd "${destination}"
  bazel run //:swift_unused_deps -- "${target}" --fix --min-confidence high
)

echo
echo "Changed files:"
git -C "${destination}" status --short

echo
echo "Diff:"
git -C "${destination}" --no-pager diff -- \
  "cases/Targets/UnusedImport" \
  "cases/Targets/MissingDirectDep"
