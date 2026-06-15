#!/usr/bin/env bash
set -euo pipefail

UV_VERSION="0.10.10"
UV_TARGET="aarch64-apple-darwin"
UV_ARCHIVE="uv-${UV_TARGET}.tar.gz"
UV_SHA256="8a09f0ef51ee7f7170731b4cb8bde5bf9ba6da5304f49a7df6cdab42a1f37b5d"
UV_BASE_URL="https://releases.astral.sh/github/uv/releases/download/${UV_VERSION}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAGE_DIR="${UV_STAGE_DIR:-${ROOT_DIR}/build/uv-runtime}"
CACHE_DIR="${UV_CACHE_DIR:-${ROOT_DIR}/build/uv-cache}"
ARCHIVE_PATH="${CACHE_DIR}/${UV_ARCHIVE}"
EXTRACT_DIR="${CACHE_DIR}/extract-${UV_VERSION}-${UV_TARGET}"
STAGED_UV="${STAGE_DIR}/uv"

if [[ -z "${UV_SHA256}" ]]; then
  echo "error: UV_SHA256 must be set before staging uv" >&2
  exit 1
fi

mkdir -p "${STAGE_DIR}" "${CACHE_DIR}"

if [[ ! -f "${ARCHIVE_PATH}" ]]; then
  echo "Downloading uv ${UV_VERSION} for ${UV_TARGET}..."
  download_path="${ARCHIVE_PATH}.download"
  rm -f "${download_path}"
  curl --fail --location --proto '=https' --tlsv1.2 \
    --output "${download_path}" \
    "${UV_BASE_URL}/${UV_ARCHIVE}"
  mv "${download_path}" "${ARCHIVE_PATH}"
else
  echo "Using cached ${ARCHIVE_PATH}"
fi

actual_sha256="$(shasum -a 256 "${ARCHIVE_PATH}" | awk '{print $1}')"
if [[ "${actual_sha256}" != "${UV_SHA256}" ]]; then
  echo "error: checksum mismatch for ${ARCHIVE_PATH}" >&2
  echo "expected: ${UV_SHA256}" >&2
  echo "actual:   ${actual_sha256}" >&2
  exit 1
fi

rm -rf "${EXTRACT_DIR}"
mkdir -p "${EXTRACT_DIR}"
tar -xzf "${ARCHIVE_PATH}" -C "${EXTRACT_DIR}"

uv_binary=""
while IFS= read -r candidate; do
  uv_binary="${candidate}"
  break
done < <(find "${EXTRACT_DIR}" -type f -name uv -print | LC_ALL=C sort)

if [[ -z "${uv_binary}" ]]; then
  echo "error: extracted archive did not contain a uv binary" >&2
  exit 1
fi

install -m 755 "${uv_binary}" "${STAGED_UV}"

file_output="$(file "${STAGED_UV}")"
echo "staged uv file: ${file_output}"
case "${file_output}" in
  *"Mach-O"*"arm64"*) ;;
  *)
    echo "error: staged uv is not an arm64 Mach-O binary" >&2
    echo "${file_output}" >&2
    exit 1
    ;;
esac

host_arch="$(uname -m)"
if [[ "${host_arch}" == "arm64" ]]; then
  "${STAGED_UV}" --version
else
  echo "warning: host architecture is ${host_arch}; skipped executing staged arm64 uv" >&2
fi
echo "Staged uv runtime: ${STAGED_UV}"
