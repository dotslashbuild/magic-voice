#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 /path/to/Magic Voice.app" >&2
}

fail() {
  echo "error: $*" >&2
  exit 1
}

if [[ $# -ne 1 ]]; then
  usage
  exit 2
fi

APP_PATH="${1%/}"
RESOURCES_DIR="${APP_PATH}/Contents/Resources"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

[[ -d "${APP_PATH}" ]] || fail "app bundle not found: ${APP_PATH}"
[[ -d "${RESOURCES_DIR}" ]] || fail "resources directory not found: ${RESOURCES_DIR}"

missing=0
require_file() {
  local path="$1"
  local label="$2"

  if [[ ! -f "${path}" ]]; then
    echo "error: missing required resource: ${label}" >&2
    missing=1
  else
    echo "ok: found ${label}"
  fi
}

require_file "${RESOURCES_DIR}/sidecar.py" "Contents/Resources/sidecar.py"
require_file "${RESOURCES_DIR}/pyproject.toml" "Contents/Resources/pyproject.toml"
require_file "${RESOURCES_DIR}/uv.lock" "Contents/Resources/uv.lock"
require_file "${RESOURCES_DIR}/uv" "Contents/Resources/uv"

if [[ "${missing}" -ne 0 ]]; then
  exit 1
fi

UV_PATH="${RESOURCES_DIR}/uv"
[[ -x "${UV_PATH}" ]] || fail "Contents/Resources/uv is not executable"
echo "ok: Contents/Resources/uv is executable"

file_output="$(file "${UV_PATH}")"
echo "uv file: ${file_output}"
case "${file_output}" in
  *"Mach-O"*"arm64"*) ;;
  *) fail "Contents/Resources/uv is not an arm64 Mach-O binary" ;;
esac

host_arch="$(uname -m)"
if [[ "${host_arch}" == "arm64" ]]; then
  uv_version_output="$("${UV_PATH}" --version)"
  echo "uv version: ${uv_version_output}"
else
  echo "warning: host architecture is ${host_arch}; skipped executing bundled arm64 uv" >&2
fi

SOURCE_LOCK="${ROOT_DIR}/sidecar/uv.lock"
APP_LOCK="${RESOURCES_DIR}/uv.lock"
if [[ -f "${SOURCE_LOCK}" ]]; then
  if ! cmp -s "${SOURCE_LOCK}" "${APP_LOCK}"; then
    echo "source uv.lock: $(shasum -a 256 "${SOURCE_LOCK}" | awk '{print $1}')" >&2
    echo "bundled uv.lock: $(shasum -a 256 "${APP_LOCK}" | awk '{print $1}')" >&2
    fail "bundled uv.lock does not match sidecar/uv.lock"
  fi
  echo "ok: bundled uv.lock matches sidecar/uv.lock"
else
  echo "warning: source sidecar/uv.lock not found; skipped lockfile comparison" >&2
fi

echo "App resource verification passed: ${APP_PATH}"
