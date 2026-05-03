#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "usage: $0 <fixture-name-or-path> <destination> [swift-unused-deps-repo-root]" >&2
  exit 2
fi

fixture_name_or_path="$1"
destination="$2"
repo_root="${3:-}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tests_dir="$(cd "${script_dir}/.." && pwd)"
default_fixtures_dir="${tests_dir}/fixtures"

if [[ -z "${repo_root}" ]]; then
  repo_root="$(git -C "${script_dir}" rev-parse --show-toplevel)"
fi

if [[ "${fixture_name_or_path}" == */* ]]; then
  fixture_dir="${fixture_name_or_path}"
else
  fixture_dir="${default_fixtures_dir}/${fixture_name_or_path}"
fi

if [[ ! -d "${fixture_dir}" ]]; then
  echo "fixture workspace not found: ${fixture_dir}" >&2
  exit 1
fi

mkdir -p "${destination}"
cp -R -L "${fixture_dir}/." "${destination}/"

find "${destination}" -name BUILD.fixture -type f -exec sh -c '
  for path do
    mv "$path" "${path%BUILD.fixture}BUILD.bazel"
  done
' sh {} +

module_file="${destination}/MODULE.bazel"
if [[ -f "${module_file}" ]]; then
  python3 - "${module_file}" "${repo_root}" <<'PY'
import pathlib
import sys

module_file = pathlib.Path(sys.argv[1])
repo_root = sys.argv[2]
contents = module_file.read_text()
replacement = repo_root.replace("\\", "\\\\").replace('"', '\\"')
if "__SWIFT_UNUSED_DEPS_PATH__" in contents:
    contents = contents.replace("__SWIFT_UNUSED_DEPS_PATH__", replacement)
module_file.write_text(contents)
PY
fi
