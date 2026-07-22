#!/bin/bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: fetch_uv.sh [options]

Downloads the pinned official macOS arm64 uv release, compares the release's
official checksum with the checksum pinned in this script, verifies the archive,
and installs only the uv executable. The downloaded binary is never added to the
repository.

Options:
  --output PATH  Installed executable. Defaults to dist/runtime/uv.
  --dry-run      Print the pinned inputs and intended operations only.
  -h, --help     Show this help.
EOF
}

script_directory="$(cd "$(dirname "$0")" && pwd -P)"
repository_root="$(cd "$script_directory/.." && pwd -P)"
# Updating uv is an auditable source change: update all three values from the
# immutable official GitHub release and review the release notes first.
uv_version="0.11.31"
uv_asset="uv-aarch64-apple-darwin.tar.gz"
uv_sha256="b2b93e82a6786f9c7cb89fd4ca0e859a147b292ae8f6f95784f9742f0efec39e"
release_base_url="https://github.com/astral-sh/uv/releases/download/$uv_version"
output_path="$repository_root/dist/runtime/uv"
dry_run=false

# shellcheck source=scripts/release_common.sh
source "$script_directory/release_common.sh"

while (($# > 0)); do
    case "$1" in
        --output)
            (($# >= 2)) || release_fail "--output requires a value"
            output_path="$2"
            shift 2
            ;;
        --dry-run)
            dry_run=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            release_fail "unknown option: $1"
            ;;
    esac
done

case "$output_path" in
    /*) ;;
    *) output_path="$repository_root/$output_path" ;;
esac

archive_url="$release_base_url/$uv_asset"
checksum_url="$archive_url.sha256"

if [[ "$dry_run" == true ]]; then
    echo "Pinned uv acquisition:"
    echo "  version:  $uv_version"
    echo "  asset:    $uv_asset"
    echo "  sha256:   $uv_sha256"
    echo "  output:   $output_path"
    echo "Would download the official archive and checksum, require the official"
    echo "checksum to match the pinned value, verify the archive, and extract uv."
    exit 0
fi

release_require_command curl
release_require_command file
release_require_command shasum
release_require_command tar

temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/magic-voice-uv.XXXXXX")"
cleanup() {
    rm -rf "$temporary_directory"
}
trap cleanup EXIT

archive_path="$temporary_directory/$uv_asset"
checksum_path="$temporary_directory/$uv_asset.sha256"

echo "Downloading official uv $uv_version for macOS arm64..."
curl --fail --location --proto '=https' --tlsv1.2 \
    --output "$archive_path" "$archive_url"
curl --fail --location --proto '=https' --tlsv1.2 \
    --output "$checksum_path" "$checksum_url"

official_sha256="$(awk 'NR == 1 { print $1 }' "$checksum_path" | tr '[:upper:]' '[:lower:]')"
[[ "$official_sha256" =~ ^[0-9a-fA-F]{64}$ ]] || \
    release_fail "official checksum response is malformed: $checksum_url"
[[ "$official_sha256" == "$uv_sha256" ]] || \
    release_fail "official checksum differs from the trusted pinned checksum; review the uv release before updating"

actual_sha256="$(shasum -a 256 "$archive_path" | awk '{ print $1 }')"
[[ "$actual_sha256" == "$uv_sha256" ]] || \
    release_fail "downloaded uv archive checksum mismatch"

tar -xzf "$archive_path" -C "$temporary_directory"
extracted_uv="$temporary_directory/uv-aarch64-apple-darwin/uv"
[[ -f "$extracted_uv" ]] || release_fail "uv archive did not contain the expected executable"
file_type="$(file -b "$extracted_uv")"
[[ "$file_type" == Mach-O* && "$file_type" == *arm64* ]] || \
    release_fail "downloaded uv is not a macOS arm64 Mach-O executable: $file_type"

mkdir -p "$(dirname "$output_path")"
temporary_output="$output_path.tmp.$$"
install -m 0755 "$extracted_uv" "$temporary_output"
mv -f "$temporary_output" "$output_path"
echo "Verified uv $uv_version: $output_path"
